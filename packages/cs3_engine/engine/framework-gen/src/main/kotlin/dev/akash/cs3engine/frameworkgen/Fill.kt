package dev.akash.cs3engine.frameworkgen

import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Opcodes.ACC_ABSTRACT
import org.objectweb.asm.Opcodes.ACC_BRIDGE
import org.objectweb.asm.Opcodes.ACC_ENUM
import org.objectweb.asm.Opcodes.ACC_FINAL
import org.objectweb.asm.Opcodes.ACC_INTERFACE
import org.objectweb.asm.Opcodes.ACC_PRIVATE
import org.objectweb.asm.Opcodes.ACC_PROTECTED
import org.objectweb.asm.Opcodes.ACC_PUBLIC
import org.objectweb.asm.Opcodes.ACC_STATIC
import org.objectweb.asm.Opcodes.ACC_TRANSIENT
import org.objectweb.asm.Opcodes.ACC_VOLATILE
import org.objectweb.asm.Type
import org.objectweb.asm.tree.ClassNode
import org.objectweb.asm.tree.MethodNode
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.lang.reflect.Modifier
import java.util.zip.ZipFile

/**
 * The engine build's step for the spec's "Generated API". It reads the hand-written stand-ins (a jar) and
 * Android's and the libraries' classes, checks that the stand-ins agree with Android, and writes to an
 * output folder:
 * - each stand-in with every public or protected method, constructor and field its real class has and it
 *   lacks (the real classes between it and its hand-written superclass included), as no-ops that never
 *   cover what a hand-written superclass implements, nor Object's equals, hashCode and toString;
 * - the framework classes the stand-ins need and nothing else gives them, whole: their supertypes, and the
 *   types their members name, so the host can resolve a stand-in's methods (reflection does);
 * - an index entry for every other framework class: its signature, less what its hand-written ancestors
 *   implement, with covariant overrides of their methods marked to call them.
 */
object Fill {
    class Report(val standIns: Int, val methodsAdded: Int, val supertypes: Int, val indexed: Int)

    fun run(standIns: File, out: File, references: List<File>): Report {
        val classes = LinkedHashMap<String, ClassNode>()
        val files = LinkedHashMap<String, ByteArray>()
        ZipFile(standIns).use { zip ->
            for (entry in zip.entries().toList().sortedBy { it.name }) {
                if (entry.isDirectory || entry.name == "META-INF/MANIFEST.MF") continue
                val bytes = zip.getInputStream(entry).use { it.readBytes() }
                if (entry.name.endsWith(".class")) {
                    val node = ClassNode()
                    ClassReader(bytes).accept(node, 0)
                    classes[node.name] = node
                } else {
                    files[entry.name] = bytes
                }
            }
        }
        val generator = Generator(classes, ReferenceJars.read(references))
        val disagreements = generator.disagreements()
        check(disagreements.isEmpty()) { "the stand-ins disagree with Android:\n" + disagreements.joinToString("\n") }
        val added = classes.values.sumOf(generator::fill)
        val gaps = generator.gaps()
        check(gaps.isEmpty()) { "stand-ins lack what their interfaces and superclasses ask:\n" + gaps.joinToString("\n") }
        out.deleteRecursively()
        out.mkdirs()
        files.forEach { (path, bytes) -> write(out, path, bytes) }
        for (node in classes.values) {
            val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
            node.accept(writer)
            write(out, "${node.name}.class", writer.toByteArray())
        }
        val supertypes = generator.hostTypes()
        for (name in supertypes) write(out, "$name.class", NoOpClass.generate(generator.indexSig(name), generator::constructorsOf))
        var indexed = 0
        for (name in generator.refs.keys) {
            if (name in classes || name in supertypes) continue
            val bytes = ByteArrayOutputStream().also { generator.indexSig(name).write(DataOutputStream(it)) }.toByteArray()
            write(out, FrameworkIndex.path(name), bytes)
            indexed++
        }
        return Report(classes.size, added, supertypes.size, indexed)
    }

    private fun write(out: File, path: String, bytes: ByteArray) {
        val file = File(out, path)
        file.parentFile.mkdirs()
        file.writeBytes(bytes)
    }
}

private class Generator(val hand: Map<String, ClassNode>, val refs: Map<String, ClassSig>) {
    /** What the stand-ins implement themselves, read before the fill adds anything: what no no-op may cover. */
    private val handMethods: Map<String, List<MethodNode>> = hand.mapValues { (_, node) ->
        node.methods.filter { it.access and (ACC_ABSTRACT or ACC_PRIVATE or ACC_STATIC) == 0 && !it.name.startsWith("<") }
    }

    /**
     * Name and descriptor of each method [name] and its hand-written superclasses implement, bridges included,
     * and those of the JDK class they rest on: a JDK superclass is the stand-in's own way of working
     * (android.icu's SimpleDateFormat on java.text's), and some of its methods are final.
     */
    fun implemented(name: String?): Set<String> {
        val out = HashSet<String>()
        handChain(name).forEach { current -> handMethods.getValue(current).forEach { out += it.name + it.desc } }
        jdkMethods(jdkBase(name)).forEach { out += it.name + it.desc }
        return out
    }

    /** The hand-written (or JDK) methods a covariant override can call, by name and parameters, the most derived first. */
    private fun targets(name: String?): Map<String, String> {
        val out = HashMap<String, String>()
        for (current in handChain(name)) {
            for (method in handMethods.getValue(current)) {
                if (method.access and ACC_BRIDGE != 0) continue
                out.putIfAbsent(method.name + method.desc.substring(0, method.desc.indexOf(')') + 1), method.desc)
            }
        }
        for (method in jdkMethods(jdkBase(name))) out.putIfAbsent(method.name + method.desc.substring(0, method.desc.indexOf(')') + 1), method.desc)
        return out
    }

    /** The JDK class [name]'s hand-written chain rests on, if any: neither a stand-in, nor Android's, nor Object. */
    private fun jdkBase(name: String?): String? {
        var current = name
        while (current != null && current in hand) current = hand.getValue(current).superName
        return current?.takeIf { it !in refs && it != "java/lang/Object" && (it.startsWith("java/") || it.startsWith("javax/")) }
    }

    private class JdkMethod(val name: String, val desc: String)

    /** The public and protected instance methods [name] (a JDK class) and its superclasses have, read from this JDK. */
    private fun jdkMethods(name: String?): List<JdkMethod> = jdkCache.getOrPut(name ?: return emptyList()) {
        val out = ArrayList<JdkMethod>()
        var type: Class<*>? = Class.forName(name.replace('/', '.'), false, ClassLoader.getPlatformClassLoader())
        while (type != null && type != Any::class.java) {
            for (method in type.declaredMethods) {
                val modifiers = method.modifiers
                if (Modifier.isStatic(modifiers) || (!Modifier.isPublic(modifiers) && !Modifier.isProtected(modifiers))) continue
                out += JdkMethod(method.name, Type.getMethodDescriptor(method))
            }
            type = type.superclass
        }
        out
    }

    private val jdkCache = HashMap<String, List<JdkMethod>>()

    private fun handChain(name: String?): List<String> {
        val out = ArrayList<String>()
        var current = name
        while (current != null && current in hand) {
            out += current
            current = hand.getValue(current).superName
        }
        return out
    }

    /** The descriptor [method] calls, when it covariantly overrides a hand-written method: both return objects. */
    private fun delegateOf(method: MethodSig, targets: Map<String, String>): String? {
        if (method.isConstructor || method.isStatic || method.isAbstract) return null
        val target = targets[method.parameters]?.takeIf { it != method.desc } ?: return null
        val references = setOf(Type.OBJECT, Type.ARRAY)
        return target.takeIf { Type.getReturnType(it).sort in references && Type.getReturnType(method.desc).sort in references }
    }

    /** [name]'s signature for the index: less what its nearest hand-written ancestor implements. */
    fun indexSig(name: String): ClassSig {
        val sig = refs.getValue(name)
        var ancestor = sig.superName
        while (ancestor != null && ancestor !in hand) ancestor = refs[ancestor]?.superName
        val inherited = implemented(ancestor)
        val targets = targets(ancestor)
        val methods = sig.methods.mapNotNull { method ->
            when {
                method.isConstructor || method.isStatic -> method
                method.name + method.desc in inherited || method.name + method.desc in OBJECT_METHODS -> null
                else -> delegateOf(method, targets)?.let { MethodSig(method.access, method.name, method.desc, it) } ?: method
            }
        }
        return sig.copy(methods = methods)
    }

    /**
     * Adds what [node]'s real class, and the real classes up to its hand-written superclass, have and it
     * lacks; returns how many methods. Abstract ones stay abstract in abstract stand-ins and interfaces.
     */
    fun fill(node: ClassNode): Int {
        val name = node.name
        val own = node.methods.mapTo(HashSet()) { it.name + it.desc }
        val ownFields = node.fields.mapTo(HashSet()) { it.name }
        val inherited = implemented(node.superName)
        val targets = targets(node.superName)
        val isInterface = node.access and ACC_INTERFACE != 0
        val keepAbstract = node.access and (ACC_ABSTRACT or ACC_INTERFACE) != 0
        val handConstructors = node.methods.filter { it.name == "<init>" }.map { it.desc }
        var added = 0
        for (source in realChain(name)) {
            for (method in source.methods) {
                if (method.isConstructor && (isInterface || source.name != name)) continue
                val key = method.name + method.desc
                if (key in own || key in inherited || key in OBJECT_METHODS) continue
                val abstract = method.isAbstract && keepAbstract
                val access = if (abstract) method.access else method.access and ACC_ABSTRACT.inv()
                val shape = MethodSig(access, method.name, method.desc, if (abstract) null else delegateOf(method, targets))
                val returnType = Type.getReturnType(method.desc)
                val returnsSelf = !method.isStatic && returnType.sort == Type.OBJECT && returnType.internalName == name
                // A missing constructor chains to the stand-in's own: this(...).
                val owner = if (method.isConstructor) name else node.superName
                NoOpClass.writeMethod(node, name, owner, shape, returnsSelf, handConstructors)
                own += key
                added++
            }
            for (field in source.fields) {
                if (!ownFields.add(field.name)) continue
                val value = if (field.access and ACC_STATIC != 0 && field.access and ACC_FINAL != 0) field.value else null
                node.visitField(field.access and FIELD_FLAGS, field.name, field.desc, null, value).visitEnd()
            }
        }
        return added
    }

    /** [name]'s real class, then each real superclass up to the first hand-written one. */
    private fun realChain(name: String): List<ClassSig> {
        val out = ArrayList<ClassSig>()
        var current: String? = name
        while (current != null) {
            val sig = refs[current] ?: break
            out += sig
            current = sig.superName
            if (current in hand) break
        }
        return out
    }

    /** Where a stand-in disagrees with Android in a way the fill can't make up for. */
    fun disagreements(): List<String> {
        val problems = ArrayList<String>()
        for ((name, node) in hand) {
            val real = refs[name] ?: continue
            val isInterface = node.access and ACC_INTERFACE != 0
            if (isInterface != real.isInterface) problems += "$name is ${if (real.isInterface) "an interface" else "a class"} in Android"
            if (node.access and ACC_FINAL != 0 && real.access and ACC_FINAL == 0) {
                problems += "$name is final, which Android's isn't: no generated class could extend it"
            }
            // A JDK superclass is the stand-in's own way of working (android.icu's SimpleDateFormat on java.text's).
            val superName = node.superName
            val frameworkSuper = superName != null && (superName in hand || superName in refs)
            if (!isInterface && frameworkSuper && superName !in superclassesOf(real)) {
                problems += "$name extends $superName, which isn't among its superclasses in Android"
            }
            // A library's R ids are the stand-ins' own (package 0x7e's type 0xff, RIds.HAND_TYPE); Android's own
            // (android.R) are checked like any constant.
            if (!name.startsWith("android/") && name.substringAfterLast('/').let { it == "R" || it.startsWith("R$") }) continue
            for (field in real.fields) {
                val value = field.value ?: continue
                val mine = node.fields.firstOrNull { it.name == field.name && it.desc == field.desc }?.value ?: continue
                if (mine != value) problems += "$name.${field.name} is $mine, Android's is $value"
            }
        }
        return problems
    }

    private fun superclassesOf(sig: ClassSig): Set<String> {
        val out = HashSet<String>()
        var current = sig.superName
        while (current != null && out.add(current)) current = refs[current]?.superName
        return out
    }

    /**
     * After the fill: each method a concrete stand-in's interfaces or abstract superclasses require that its
     * classes don't implement. The fill gives abstract stand-ins Android's abstract methods, which a concrete
     * stand-in below one must then implement.
     */
    fun gaps(): List<String> {
        val problems = ArrayList<String>()
        for ((name, node) in hand) {
            if (node.access and (ACC_ABSTRACT or ACC_INTERFACE) != 0) continue
            val concrete = hashSetOf("toString()Ljava/lang/String;", "equals(Ljava/lang/Object;)Z", "hashCode()I")
            // (declaring type, name + descriptor) of each abstract method something above it declares.
            val required = ArrayList<Pair<String, String>>()
            val interfaces = ArrayDeque<String>()
            var current: String? = name
            while (current != null) {
                val owner: String = current
                val handNode = hand[owner]
                val sig = refs[owner]
                current = when {
                    handNode != null -> {
                        for (method in handNode.methods) {
                            if (method.access and ACC_ABSTRACT == 0) concrete += method.name + method.desc
                            else required += owner to method.name + method.desc
                        }
                        interfaces += handNode.interfaces
                        handNode.superName
                    }
                    sig != null -> {
                        // A generated superclass: its methods are no-ops, but abstract ones stay abstract.
                        for (method in sig.methods) {
                            if (!method.isAbstract) concrete += method.name + method.desc
                            else required += owner to method.name + method.desc
                        }
                        interfaces += sig.interfaces
                        sig.superName
                    }
                    // The JDK's: the compiler checked those.
                    else -> null
                }
            }
            val seen = HashSet<String>()
            while (interfaces.isNotEmpty()) {
                val type = interfaces.removeFirst()
                if (!seen.add(type)) continue
                val handIface = hand[type]
                val refIface = refs[type]
                when {
                    handIface != null -> {
                        interfaces += handIface.interfaces
                        for (method in handIface.methods) {
                            if (method.access and ACC_ABSTRACT != 0) required += type to method.name + method.desc
                            else if (method.access and ACC_STATIC == 0) concrete += method.name + method.desc
                        }
                    }
                    refIface != null -> {
                        interfaces += refIface.interfaces
                        for (method in refIface.methods) {
                            if (method.isAbstract) required += type to method.name + method.desc
                            else if (!method.isStatic) concrete += method.name + method.desc
                        }
                    }
                }
            }
            for ((type, key) in required) if (key !in concrete) problems += "$name lacks $type.$key"
        }
        return problems
    }

    /** A class's constructors: a stand-in's own, a generated one's (its real ones and the no-argument one), or the JDK's. */
    fun constructorsOf(name: String): List<String> = when (name) {
        in hand -> hand.getValue(name).methods
            .filter { it.name == "<init>" && it.access and (ACC_PUBLIC or ACC_PROTECTED) != 0 }
            .map { it.desc }
        in refs -> refs.getValue(name).methods.filter { it.isConstructor }.map { it.desc } + "()V"
        else -> runCatching {
            Class.forName(name.replace('/', '.'), false, Generator::class.java.classLoader).declaredConstructors
                .filter { Modifier.isPublic(it.modifiers) || Modifier.isProtected(it.modifiers) }
                .map { Type.getConstructorDescriptor(it) }
        }.getOrDefault(listOf("()V"))
    }

    /**
     * Framework classes the host must have that aren't stand-ins, written whole: the stand-ins' supertypes, and
     * every type their members name once filled (parameters, returns, fields, exceptions), each with its own
     * supertypes. Without them the host can't resolve a stand-in's methods: Java reflection over a filled
     * Fragment (Class.getDeclaredMethods, as JUnit's discovery calls it) would fail on ViewModelProvider.Factory.
     * The extensions' framework loader finds them on the host too, so there's still one class of each.
     */
    fun hostTypes(): List<String> {
        val out = LinkedHashSet<String>()
        val queue = ArrayDeque<String>()
        for (node in hand.values) {
            queue += listOfNotNull(node.superName) + node.interfaces
            for (method in node.methods) {
                queue += typesIn(method.desc)
                method.exceptions?.let { queue += it }
            }
            for (field in node.fields) queue += typesIn(field.desc)
        }
        while (queue.isNotEmpty()) {
            val name = queue.removeFirst()
            if (name in hand || name in out || name !in refs) continue
            out += name
            val sig = refs.getValue(name)
            queue += listOfNotNull(sig.superName) + sig.interfaces
        }
        return out.toList()
    }

    /** The classes a method's or field's descriptor names (an array's element type for arrays). */
    private fun typesIn(desc: String): List<String> {
        val types = if (desc.startsWith("(")) Type.getArgumentTypes(desc).toList() + Type.getReturnType(desc) else listOf(Type.getType(desc))
        return types.map { if (it.sort == Type.ARRAY) it.elementType else it }.filter { it.sort == Type.OBJECT }.map { it.internalName }
    }

    private companion object {
        const val FIELD_FLAGS = ACC_PUBLIC or ACC_PROTECTED or ACC_STATIC or ACC_FINAL or ACC_VOLATILE or ACC_TRANSIENT or ACC_ENUM

        /**
         * Object's own methods, which no no-op replaces: an equals that answers false would break
         * `list.remove(fragment)`, and a toString that answers null breaks string templates. Identity and
         * Object's text are right for stand-ins and generated classes alike.
         */
        val OBJECT_METHODS = setOf("equals(Ljava/lang/Object;)Z", "hashCode()I", "toString()Ljava/lang/String;")
    }
}

fun main(args: Array<String>) {
    require(args.size >= 3) { "usage: <stand-ins jar> <out folder> <reference jars and AARs...>" }
    val report = Fill.run(File(args[0]), File(args[1]), args.drop(2).map(::File))
    println(
        "framework-gen: ${report.standIns} stand-ins, ${report.methodsAdded} no-ops added, " +
            "${report.supertypes} framework classes written whole, ${report.indexed} classes indexed",
    )
}
