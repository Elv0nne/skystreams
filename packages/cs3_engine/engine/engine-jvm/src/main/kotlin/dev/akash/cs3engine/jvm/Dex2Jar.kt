package dev.akash.cs3engine.jvm

import com.googlecode.d2j.Method
import com.googlecode.d2j.converter.IR2JConverter
import com.googlecode.d2j.dex.ClassVisitorFactory
import com.googlecode.d2j.dex.Dex2Asm
import com.googlecode.d2j.dex.DexExceptionHandler
import com.googlecode.d2j.dex.ExDex2Asm
import com.googlecode.d2j.dex.LambadaNameSafeClassAdapter
import com.googlecode.d2j.node.DexClassNode
import com.googlecode.d2j.node.DexFileNode
import com.googlecode.d2j.node.DexMethodNode
import com.googlecode.d2j.reader.BaseDexFileReader
import com.googlecode.d2j.reader.DexFileReader
import com.googlecode.d2j.reader.MultiDexFileReader
import com.googlecode.dex2jar.ir.IrMethod
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes
import org.objectweb.asm.tree.MethodNode
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.Collections
import java.util.IdentityHashMap
import java.util.Properties
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/**
 * Converts a .cs3's DEX code to a jar of JVM classes, cached per file hash.
 *
 * The jar is written with java.util.zip, because the iOS runtime has no zip filesystem. A jar
 * rather than a directory keeps classes whose names differ only in case apart on
 * case-insensitive disks (macOS, Windows, the iOS simulator).
 *
 * Converting is most of a plugin's load time without a JIT (iOS: a median of 2 s, up to
 * minutes). Methods convert independently, so they are spread over a few threads, which every
 * plugin being converted shares; a class is written out once its methods are done.
 */
internal object Dex2Jar {
    /**
     * Bump when conversion settings or the cache layout change, so stale entries are not reused. 5: exits
     * and class probes redirected; version 4's entries are carried over (carryOver).
     */
    internal const val CACHE_VERSION = 5

    /** Entries no load has used for this long are deleted: plugins get updated and removed. */
    private const val UNUSED_DAYS = 60L

    private const val JAR = "classes.jar"
    private const val META = "meta.properties"

    private const val EXITS = "dev/akash/cs3engine/stubs/Exits"
    private const val PROBES = "dev/akash/cs3engine/stubs/ClassProbes"

    /**
     * The calls sent to the engine's stand-ins: those that end the process to Exits, which stops the
     * extension's code instead (the spec's "Exits are blocked twice"; on iOS an exit would end SkyStream,
     * elsewhere the engine), and Class.forName to ClassProbes, which answers a placeholder as missing, as
     * Android does. Keyed by owner, name and descriptor; each value is the stand-in's class, method and
     * descriptor, which takes the same arguments (an instance call's receiver first), so the stack and the
     * class's frames are as they were.
     */
    private val REDIRECTS = mapOf(
        "java/lang/System.exit(I)V" to Triple(EXITS, "exit", "(I)V"),
        "java/lang/Runtime.exit(I)V" to Triple(EXITS, "exit", "(Ljava/lang/Runtime;I)V"),
        "java/lang/Runtime.halt(I)V" to Triple(EXITS, "halt", "(Ljava/lang/Runtime;I)V"),
        "android/os/Process.killProcess(I)V" to Triple(EXITS, "killProcess", "(I)V"),
        "kotlin/system/ProcessKt.exitProcess(I)Ljava/lang/Void;" to Triple(EXITS, "exitProcess", "(I)Ljava/lang/Void;"),
        "java/lang/Class.forName(Ljava/lang/String;)Ljava/lang/Class;" to
            Triple(PROBES, "forName", "(Ljava/lang/String;)Ljava/lang/Class;"),
        "java/lang/Class.forName(Ljava/lang/String;ZLjava/lang/ClassLoader;)Ljava/lang/Class;" to
            Triple(PROBES, "forName", "(Ljava/lang/String;ZLjava/lang/ClassLoader;)Ljava/lang/Class;"),
    )

    /** A few threads, leaving the app a core. */
    private val workers: ExecutorService =
        Executors.newFixedThreadPool((Runtime.getRuntime().availableProcessors() - 1).coerceIn(2, 4)) { task ->
            // iOS's VM keeps Java frames on the native stack, and dex2jar's analyses recurse.
            Thread(null, task, "cs3-dex2jar", 8L shl 20).apply { isDaemon = true }
        }

    /** Each plugin being converted holds all of its DEX code in memory until it is written out. */
    private val converting = Semaphore(2)

    /** One conversion per file at a time: the same file can be loaded from two places at once. */
    private val fileLocks = ConcurrentHashMap<String, Any>()

    class Result(
        val jar: File,
        val dexClasses: Int,
        val jvmClasses: Int,
        val failedMethods: Int,
        val ms: Long,
        val cached: Boolean,
        /** Android types the code uses as interfaces: PluginClassLoader must stub them as such. */
        val interfaces: Set<String>,
        val outOfMemory: Boolean = false,
    ) {
        /** True when some classes or methods did not make it (e.g. out of memory on a huge method). */
        val incomplete: Boolean get() = jvmClasses < dexClasses || failedMethods > 0

        fun notes(): Map<String, Any?> = mapOf(
            "dexClasses" to dexClasses,
            "jvmClasses" to jvmClasses,
            "failedMethods" to failedMethods,
            "incomplete" to incomplete,
            "convertMs" to ms,
            "cached" to cached,
            "outOfMemory" to outOfMemory,
        )
    }

    fun convert(cs3: File, cacheRoot: File): Result {
        val root = File(cacheRoot, "v$CACHE_VERSION")
        prune(cacheRoot, root)
        val hash = sha256(cs3)
        val dir = File(root, hash)
        synchronized(fileLocks.computeIfAbsent(hash) { Any() }) {
            cached(dir)?.let { return it }
            carryOver(File(cacheRoot, "v${CACHE_VERSION - 1}/$hash"), root, dir)?.let { return it }
            converting.acquire()
            try {
                // Built aside and moved into place, so an entry is either complete or absent.
                val building = File(root, "$hash.tmp${System.nanoTime()}")
                try {
                    translate(cs3, building)
                    if (!building.renameTo(dir)) check(dir.isDirectory) { "cannot write the conversion cache at $dir" }
                } finally {
                    building.deleteRecursively()
                }
                return cached(dir, fresh = true) ?: error("the conversion of ${cs3.name} did not save")
            } finally {
                converting.release()
            }
        }
    }

    /** The entry in [dir], if it holds a usable conversion; marks it as used. */
    private fun cached(dir: File, fresh: Boolean = false): Result? {
        val meta = File(dir, META)
        if (!meta.isFile) return null
        val props = Properties()
        try {
            meta.inputStream().use(props::load)
        } catch (e: IOException) {
            dir.deleteRecursively()
            return null
        }
        fun count(key: String) = props.getProperty(key)?.toLongOrNull()
        val dex = count("dexClasses")
        val jvm = count("jvmClasses")
        val failed = count("failedMethods")
        val ms = count("convertMs")
        if (dex == null || jvm == null || failed == null || ms == null) {
            dir.deleteRecursively()
            return null
        }
        // Converted short of memory: worth trying again in a VM given more.
        val outOfMemoryAt = count("outOfMemoryAt")
        if (outOfMemoryAt != null && Runtime.getRuntime().maxMemory() > outOfMemoryAt) {
            dir.deleteRecursively()
            return null
        }
        meta.setLastModified(System.currentTimeMillis())
        val interfaces = props.getProperty("interfaces").orEmpty().split(',').filter { it.isNotBlank() }.toSet()
        return Result(File(dir, JAR), dex.toInt(), jvm.toInt(), failed.toInt(), ms, cached = !fresh, interfaces, outOfMemoryAt != null)
    }

    /** Converts [cs3] into [dir]: the jar, and the metadata [cached] reads. */
    private fun translate(cs3: File, dir: File) {
        dir.deleteRecursively()
        check(dir.mkdirs()) { "cannot create the conversion cache at $dir" }
        val started = System.nanoTime()
        val reader = MultiDexFileReader.open(cs3.readBytes())
        val failedMethods = AtomicInteger()
        val outOfMemory = AtomicBoolean()
        val interfaces = ConcurrentHashMap.newKeySet<String>()
        val handler = object : DexExceptionHandler {
            override fun handleFileException(e: Exception) {
                failedMethods.incrementAndGet()
            }

            override fun handleMethodTranslateException(method: Method, node: DexMethodNode, mv: MethodVisitor, e: Exception) {
                failedMethods.incrementAndGet()
            }
        }
        val classes = try {
            // DEX 037+ becomes Java 8 class files, which only verify with stack map frames.
            convertClasses(reader, dexVersion(cs3) >= 37, handler, failedMethods, outOfMemory, interfaces)
        } catch (e: OutOfMemoryError) {
            // Reading a huge plugin can exhaust the heap too.
            failedMethods.incrementAndGet()
            outOfMemory.set(true)
            emptyList()
        }
        val jvmClasses = writeJar(File(dir, JAR), classes)
        val props = Properties()
        props["dexClasses"] = reader.classNames.size.toString()
        props["jvmClasses"] = jvmClasses.toString()
        props["failedMethods"] = failedMethods.get().toString()
        props["convertMs"] = ((System.nanoTime() - started) / 1_000_000).toString()
        props["interfaces"] = interfaces.sorted().joinToString(",")
        // Whether memory runs out depends on the heap: kept, but retried in a VM given more.
        if (outOfMemory.get()) props["outOfMemoryAt"] = Runtime.getRuntime().maxMemory().toString()
        File(dir, META).outputStream().use { props.store(it, null) }
    }

    /** Converts every class, several methods at a time; returns them in DEX order, apart from any that failed. */
    private fun convertClasses(
        reader: BaseDexFileReader,
        frames: Boolean,
        handler: DexExceptionHandler,
        failedMethods: AtomicInteger,
        outOfMemory: AtomicBoolean,
        interfaces: MutableSet<String>,
    ): List<Pair<String, ByteArray>> {
        // Read as Dex2jar.doTranslate reads it.
        val dex = DexFileNode()
        val config = DexFileReader.SKIP_DEBUG or DexFileReader.DONT_SANITIZE_NAMES or
            (if (frames) DexFileReader.COMPUTE_FRAMES else 0)
        try {
            reader.accept(dex, config or DexFileReader.IGNORE_READ_EXCEPTION)
        } catch (e: Exception) {
            handler.handleFileException(e)
        }
        val nodes: List<DexClassNode> = dex.clzs.orEmpty()
        val localClasses = LocalClasses.of(nodes)
        val parents = HashMap<String, String>()
        for (node in nodes) node.superClass?.let { parents[internalName(node.className)] = internalName(it) }
        val converter = Converter(handler)
        val index = converter.index(dex)

        val output = arrayOfNulls<Pair<String, ByteArray>>(nodes.size)
        val failure = AtomicReference<Throwable>()
        val finished = CountDownLatch(nodes.size)

        fun write(i: Int) {
            try {
                val visitors = classWriters(frames, parents, handler, interfaces) { name, bytes -> output[i] = name to localClasses.fix(name, bytes) }
                converter.convert(dex, nodes[i], visitors, index)
            } catch (e: OutOfMemoryError) {
                // One giant method can exhaust the heap; keep whatever converted and report it.
                failedMethods.incrementAndGet()
                outOfMemory.set(true)
            } catch (t: Throwable) {
                failure.compareAndSet(null, t)
            } finally {
                finished.countDown()
            }
        }

        // Biggest classes first and, in each, biggest methods first, so the work still running at
        // the end is small. The last of a class's methods to be ready writes the class out.
        for (i in nodes.indices.sortedByDescending { nodes[it].codeSize() }) {
            val methods = nodes[i].methods.orEmpty().filter { it.codeNode != null }.sortedByDescending { it.codeSize() }
            if (methods.isEmpty()) {
                workers.execute { write(i) }
                continue
            }
            val context = converter.context(nodes[i])
            val left = AtomicInteger(methods.size)
            for (method in methods) {
                workers.execute {
                    try {
                        converter.prepare(method, context)
                    } finally {
                        // Even if preparing failed outright (out of memory): dex2jar then converts it.
                        if (left.decrementAndGet() == 0) write(i)
                    }
                }
            }
        }
        finished.await()
        // Like dex2jar, a class that fails outright fails the conversion.
        failure.get()?.let { throw it }
        return output.filterNotNull()
    }

    private fun DexClassNode.codeSize(): Int = methods.orEmpty().sumOf { it.codeSize() }

    private fun DexMethodNode.codeSize(): Int = codeNode?.stmts?.size ?: 0

    /**
     * dex2jar's pipeline as Dex2jar.doTranslate sets it up (dex2jar, Apache-2.0), with the slow part
     * of each method (building, optimising and lowering its IR) done ahead by [prepare], on any
     * thread: the converter and its transformers keep no state, and the class index is only read.
     * Converting the class then takes the prepared code where dex2jar would build it, so its own
     * error handling and size checks still apply.
     */
    private class Converter(handler: DexExceptionHandler) : ExDex2Asm(handler) {
        /** A method's code converted ahead, or why it could not be. */
        private class Prepared(val code: MethodNode?, val error: Throwable?) : IrMethod()

        /**
         * dex2jar names a class's hex decoding helpers the first time one of its methods needs
         * them; its methods now convert at once, so they share this and agree on the name.
         */
        class Context(className: String) : Dex2Asm.ClzCtx() {
            init {
                classDescriptor = className
            }

            @Synchronized
            override fun buildHexDecodeMethodName(x: String): String = super.buildHexDecodeMethodName(x)
        }

        private val contexts = ConcurrentHashMap<String, Context>()
        private val prepared = Collections.synchronizedMap(IdentityHashMap<DexMethodNode, Prepared>())

        /** Inner and outer class relations across the whole file; opaque outside this class. */
        fun index(dex: DexFileNode): Any = collectClzInfo(dex)

        fun context(node: DexClassNode): Context = contexts.getOrPut(node.className) { Context(node.className) }

        /** Converts [method]'s code ahead of its class, keeping any failure for dex2jar to report then. */
        fun prepare(method: DexMethodNode, context: Context) {
            prepared[method] = try {
                val ir = super.dex2ir(method)
                optimize(ir)
                val code = MethodNode(Opcodes.ASM9, method.access, method.method.name, method.method.desc, null, null)
                ir2j(ir, code, context)
                Prepared(code, null)
            } catch (t: Throwable) {
                Prepared(null, t)
            }
        }

        @Suppress("UNCHECKED_CAST")
        fun convert(dex: DexFileNode, node: DexClassNode, visitors: ClassVisitorFactory, index: Any) =
            convertClass(dex, node, visitors, index as Map<String, Clz>)

        override fun dex2ir(methodNode: DexMethodNode): IrMethod {
            val ready = prepared.remove(methodNode) ?: return super.dex2ir(methodNode)
            ready.error?.let { throw it }
            return ready
        }

        override fun optimize(irMethod: IrMethod) {
            if (irMethod is Prepared) return
            T_CLEAN_LABEL.transform(irMethod)
            T_DEAD_CODE.transform(irMethod)
            T_REMOVE_LOCAL.transform(irMethod)
            T_REMOVE_CONST.transform(irMethod)
            T_ZERO.transform(irMethod)
            if (T_NPE.transformReportChanged(irMethod)) {
                T_DEAD_CODE.transform(irMethod)
                T_REMOVE_LOCAL.transform(irMethod)
                T_REMOVE_CONST.transform(irMethod)
            }
            T_NEW.transform(irMethod)
            T_FILL_ARRAY.transform(irMethod)
            T_AGG.transform(irMethod)
            T_MULTI_ARRAY.transform(irMethod)
            T_VOID_INVOKE.transform(irMethod)
            // Dead code found in unssa, clean up (pxb1988/dex2jar#477).
            T_DEAD_CODE.transform(irMethod)
            T_REMOVE_LOCAL.transform(irMethod)
            T_REMOVE_CONST.transform(irMethod)
            T_TYPE.transform(irMethod)
            T_UNSSA.transform(irMethod)
            // Dex2jar assigns registers before trimming handlers; Dex2Asm's default does the reverse.
            T_IR_2_J_REG_ASSIGN.transform(irMethod)
            T_TRIM_EX.transform(irMethod)
        }

        override fun ir2j(irMethod: IrMethod, mv: MethodVisitor, clzCtx: Dex2Asm.ClzCtx) {
            val shared = contexts[clzCtx.classDescriptor]
            if (irMethod is Prepared) {
                irMethod.code!!.accept(mv)
            } else {
                IR2JConverter().optimizeSynchronized(false).clzCtx(shared ?: clzCtx).ir(irMethod).asm(mv).convert()
            }
            // The class adds the helpers its context names, once all its methods are converted.
            shared?.hexDecodeMethodNamePrefix?.let { clzCtx.hexDecodeMethodNamePrefix = it }
        }
    }

    /**
     * Writes each class as Dex2jar.doTranslate does and hands its name and bytes to [done]. Notes
     * the Android types it uses as interfaces (implemented, or called through invokeinterface)
     * into [interfaces]: their stubs must be interfaces too, or the JVM rejects the class.
     */
    private fun classWriters(
        frames: Boolean,
        parents: Map<String, String>,
        handler: DexExceptionHandler,
        interfaces: MutableSet<String>,
        done: (String, ByteArray) -> Unit,
    ) = ClassVisitorFactory {
        val writer = if (frames) FramesWriter(parents) else ClassWriter(ClassWriter.COMPUTE_MAXS)
        val names = LambadaNameSafeClassAdapter(writer, true)
        fun note(internalName: String?) {
            val name = internalName?.replace('/', '.') ?: return
            if (PluginClassLoader.isStubbed(name)) interfaces += name
        }
        object : ClassVisitor(Opcodes.ASM9, names) {
            override fun visit(version: Int, access: Int, name: String?, signature: String?, superName: String?, types: Array<out String>?) {
                types?.forEach(::note)
                super.visit(version, access, name, signature, superName, types)
            }

            override fun visitMethod(access: Int, name: String?, descriptor: String?, signature: String?, exceptions: Array<out String>?): MethodVisitor? =
                object : MethodVisitor(Opcodes.ASM9, redirected(super.visitMethod(access, name, descriptor, signature, exceptions))) {
                    override fun visitMethodInsn(opcode: Int, owner: String?, name: String?, descriptor: String?, isInterface: Boolean) {
                        if (isInterface) note(owner)
                        super.visitMethodInsn(opcode, owner, name, descriptor, isInterface)
                    }
                }

            override fun visitEnd() {
                super.visitEnd()
                val bytes = try {
                    writer.toByteArray()
                } catch (e: Exception) {
                    handler.handleFileException(e)
                    return
                }
                done(names.className, bytes)
            }
        }
    }

    /** [next], with each of [REDIRECTS] sent to its stand-in on its way. */
    private fun redirected(next: MethodVisitor?): MethodVisitor = object : MethodVisitor(Opcodes.ASM9, next) {
        override fun visitMethodInsn(opcode: Int, owner: String?, name: String?, descriptor: String?, isInterface: Boolean) {
            val target = REDIRECTS["$owner.$name$descriptor"]
            if (target == null) super.visitMethodInsn(opcode, owner, name, descriptor, isInterface)
            else super.visitMethodInsn(Opcodes.INVOKESTATIC, target.first, target.second, target.third, false)
        }
    }

    /** [bytes], a class, with its calls redirected ([REDIRECTS]); its frames are kept as they are. */
    private fun redirect(bytes: ByteArray): ByteArray {
        val writer = ClassWriter(0)
        ClassReader(bytes).accept(
            object : ClassVisitor(Opcodes.ASM9, writer) {
                override fun visitMethod(access: Int, name: String?, descriptor: String?, signature: String?, exceptions: Array<out String>?): MethodVisitor =
                    redirected(super.visitMethod(access, name, descriptor, signature, exceptions))
            },
            0,
        )
        return writer.toByteArray()
    }

    /**
     * The previous version's entry for the same file ([previous]), carried over into [dir]: its classes with
     * their calls redirected, its notes as they were. Converting again would cost what the first conversion
     * did (on iOS, seconds to minutes an extension); this is one pass over the classes. Null when there's
     * none, or it can't be read (the file is then converted).
     */
    private fun carryOver(previous: File, root: File, dir: File): Result? {
        val jar = File(previous, JAR)
        val meta = File(previous, META)
        if (!jar.isFile || !meta.isFile) return null
        val building = File(root, "${dir.name}.tmp${System.nanoTime()}")
        try {
            check(building.mkdirs()) { "cannot create the conversion cache at $building" }
            ZipFile(jar).use { zip ->
                ZipOutputStream(File(building, JAR).outputStream().buffered()).use { out ->
                    out.setLevel(1)
                    for (entry in zip.entries()) {
                        if (entry.isDirectory) continue
                        val bytes = zip.getInputStream(entry).use { it.readBytes() }
                        out.putNextEntry(ZipEntry(entry.name))
                        out.write(if (entry.name.endsWith(".class")) redirect(bytes) else bytes)
                        out.closeEntry()
                    }
                }
            }
            meta.copyTo(File(building, META))
            if (!building.renameTo(dir)) check(dir.isDirectory) { "cannot write the conversion cache at $dir" }
        } catch (e: Exception) {
            return null
        } finally {
            building.deleteRecursively()
            previous.deleteRecursively()
        }
        return cached(dir)
    }

    /** Stack map frames need common superclasses; the plugin's own classes come from [parents]. */
    private class FramesWriter(private val parents: Map<String, String>) : ClassWriter(COMPUTE_FRAMES) {
        override fun getCommonSuperClass(type1: String, type2: String): String {
            if (type1 == type2) return type1
            var a = type1
            val ancestors = hashSetOf(a)
            while (true) {
                a = parents[a] ?: break
                ancestors += a
            }
            var b = type2
            while (true) {
                b = parents[b] ?: break
                if (b in ancestors) return b
            }
            return try {
                super.getCommonSuperClass(a, b)
            } catch (t: Throwable) {
                // dex2jar answers java/util/Object here, a typo.
                "java/lang/Object"
            }
        }
    }

    /** Returns how many classes were written. */
    private fun writeJar(jar: File, classes: List<Pair<String, ByteArray>>): Int {
        val written = HashSet<String>()
        ZipOutputStream(jar.outputStream().buffered()).use { zip ->
            zip.setLevel(1)
            for ((name, bytes) in classes) {
                val entry = "$name.class"
                if (!written.add(entry)) continue
                zip.putNextEntry(ZipEntry(entry))
                zip.write(bytes)
                zip.closeEntry()
            }
        }
        return written.size
    }

    /**
     * dex2jar writes a named local class (one declared inside a function) as a member of its outer
     * class and drops the method it is declared in, so the JVM sees no local class:
     * Class.getEnclosingMethod() is null and kotlin-reflect looks for a nested class that does not
     * exist. Plugins parse JSON into such classes, and Jackson builds Kotlin classes through
     * kotlin-reflect. This puts back what the DEX records about them.
     */
    private class LocalClasses(private val enclosingMethods: Map<String, Method>) {
        // A local class is only mentioned by the classes under the same outermost class.
        private val outermost = enclosingMethods.keys.mapTo(HashSet()) { it.substringBefore('$') }

        fun fix(className: String, bytes: ByteArray): ByteArray {
            if (className.substringBefore('$') !in outermost) return bytes
            val reader = ClassReader(bytes)
            val writer = ClassWriter(reader, 0)
            reader.accept(object : ClassVisitor(Opcodes.ASM9, writer) {
                override fun visit(
                    version: Int,
                    access: Int,
                    name: String,
                    signature: String?,
                    superName: String?,
                    interfaces: Array<String>?,
                ) {
                    super.visit(version, access, name, signature, superName, interfaces)
                    enclosingMethods[name]?.let { super.visitOuterClass(internalName(it.owner), it.name, it.desc) }
                }

                // A local class has no outer class in the InnerClasses table.
                override fun visitInnerClass(name: String, outerName: String?, innerName: String?, access: Int) =
                    super.visitInnerClass(name, if (name in enclosingMethods) null else outerName, innerName, access)
            }, 0)
            return writer.toByteArray()
        }

        companion object {
            /** Each named local class among [classes], by internal name, with the method it is declared in. */
            fun of(classes: List<DexClassNode>): LocalClasses {
                val found = HashMap<String, Method>()
                for (clz in classes) {
                    val annotations = clz.anns ?: continue
                    fun value(type: String, item: String): Any? =
                        annotations.firstOrNull { it.type == type }?.items?.firstOrNull { it.name == item }?.value
                    val method = value("Ldalvik/annotation/EnclosingMethod;", "value") as? Method ?: continue
                    // Anonymous classes (no name) already come out right.
                    if (value("Ldalvik/annotation/InnerClass;", "name") !is String) continue
                    found[internalName(clz.className)] = method
                }
                return LocalClasses(found)
            }
        }
    }

    private fun internalName(descriptor: String) = descriptor.removePrefix("L").removeSuffix(";")

    /** The highest DEX format version in the plugin, e.g. 35 for "dex\n035". */
    private fun dexVersion(cs3: File): Int = ZipFile(cs3).use { zip ->
        zip.entries().asSequence().filter { it.name.endsWith(".dex") }.maxOfOrNull { entry ->
            val header = zip.getInputStream(entry).use { it.readNBytes(8) }
            String(header, 4, 3, Charsets.US_ASCII).toIntOrNull() ?: 35
        } ?: 35
    }

    private var pruned = false

    /**
     * Once per run: deletes other versions' entries (the previous version's wait to be carried over), unused
     * entries and abandoned conversions.
     */
    @Synchronized
    private fun prune(cacheRoot: File, root: File) {
        if (pruned) return
        pruned = true
        // The previous version's entries wait to be carried over, each when its extension next loads.
        val previous = File(cacheRoot, "v${CACHE_VERSION - 1}")
        cacheRoot.listFiles { file -> file != root && file != previous }?.forEach { it.deleteRecursively() }
        val now = System.currentTimeMillis()
        val unused = now - UNUSED_DAYS * 24 * 60 * 60 * 1000
        val abandoned = now - 24 * 60 * 60 * 1000
        for (folder in listOf(root, previous)) {
            folder.listFiles()?.forEach { entry ->
                val stale = if (entry.name.contains(".tmp")) {
                    entry.lastModified() < abandoned
                } else {
                    File(entry, META).let { !it.isFile || it.lastModified() < unused }
                }
                if (stale) entry.deleteRecursively()
            }
        }
        if (previous.list()?.isEmpty() == true) previous.delete()
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
