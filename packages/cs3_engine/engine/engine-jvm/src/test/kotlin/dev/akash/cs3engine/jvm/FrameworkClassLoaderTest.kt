package dev.akash.cs3engine.jvm

import dev.akash.cs3engine.frameworkgen.ClassSig
import dev.akash.cs3engine.frameworkgen.MethodSig
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Opcodes.ACC_BRIDGE
import org.objectweb.asm.Opcodes.ACC_PROTECTED
import org.objectweb.asm.Opcodes.ACC_PUBLIC
import org.objectweb.asm.Opcodes.ACC_STATIC
import org.objectweb.asm.Opcodes.ACC_SUPER
import org.objectweb.asm.Opcodes.ACC_SYNTHETIC
import org.objectweb.asm.Opcodes.ALOAD
import org.objectweb.asm.Opcodes.DUP
import org.objectweb.asm.Opcodes.ICONST_1
import org.objectweb.asm.Opcodes.INVOKESPECIAL
import org.objectweb.asm.Opcodes.INVOKESTATIC
import org.objectweb.asm.Opcodes.IRETURN
import org.objectweb.asm.Opcodes.NEW
import org.objectweb.asm.Opcodes.RETURN
import org.objectweb.asm.Opcodes.V1_8
import org.objectweb.asm.Type
import java.io.File
import java.net.URLClassLoader
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** A hand-written stand-in's shape: generated framework classes extend it. */
open class HostView(val context: Any?) {
    open fun title(): String = "host"
}

/** A hand-written generic stand-in's shape (ActivityResultContract's): an index class narrows its result. */
abstract class HostContract {
    abstract fun parse(code: Int): Any?
}

class FrameworkClassLoaderTest {
    private val host = Type.getInternalName(HostView::class.java)
    private val pub = ACC_PUBLIC

    private fun sig(name: String, superName: String, vararg methods: MethodSig, interfaces: List<String> = emptyList()) =
        ClassSig(name, pub or ACC_SUPER, superName, interfaces, emptyList(), methods.toList())

    @Test
    fun `a framework class is made from the index, with its real superclass and interfaces`() {
        val index = mapOf(
            "android/test/Card" to sig(
                "android/test/Card", host,
                MethodSig(pub, "<init>", "(Ljava/lang/Object;)V"), MethodSig(pub, "count", "()I"), MethodSig(pub, "run", "()V"),
                interfaces = listOf("java/lang/Runnable"),
            ),
        )
        val loader = FrameworkClassLoader(javaClass.classLoader, index::get)
        val card = loader.loadClass("android.test.Card")
        assertSame(loader, card.classLoader)
        assertEquals(HostView::class.java, card.superclass)
        assertEquals(listOf(Runnable::class.java), card.interfaces.toList())
        val made = card.getConstructor(Any::class.java).newInstance("context") as HostView
        assertEquals("context", made.context, "the constructor chains to the hand-written one")
        assertEquals(0, card.getMethod("count").invoke(made))
        assertEquals("host", made.title(), "what it doesn't declare stays the stand-in's")
        (made as Runnable).run()
    }

    @Test
    fun `generated classes chain through each other to the hand-written one`() {
        val index = mapOf(
            "android/test/Base" to sig("android/test/Base", host, MethodSig(pub, "<init>", "(Ljava/lang/Object;)V")),
            "android/test/Fancy" to sig("android/test/Fancy", "android/test/Base", MethodSig(pub, "<init>", "(Ljava/lang/Object;I)V")),
        )
        val loader = FrameworkClassLoader(javaClass.classLoader, index::get)
        val fancy = loader.loadClass("android.test.Fancy")
            .getConstructor(Any::class.java, Int::class.javaPrimitiveType).newInstance("context", 2) as HostView
        assertEquals("context", fancy.context)
    }

    @Test
    fun `a class made from the index answers through its hand-written generic superclass's erased signature`() {
        // ActivityResultContracts.OpenDocument narrows ActivityResultContract's parseResult to a Uri. Callers
        // (the engine's launcher, an extension's generic code) call the erased signature, which only its bridge has.
        val index = mapOf(
            "android/test/UriContract" to sig(
                "android/test/UriContract", Type.getInternalName(HostContract::class.java),
                MethodSig(pub, "<init>", "()V"),
                MethodSig(pub, "parse", "(I)Ljava/lang/String;"),
                MethodSig(pub or ACC_BRIDGE or ACC_SYNTHETIC, "parse", "(I)Ljava/lang/Object;"),
            ),
        )
        val loader = FrameworkClassLoader(javaClass.classLoader, index::get)
        val contract = loader.loadClass("android.test.UriContract").getConstructor().newInstance() as HostContract
        assertNull(contract.parse(0), "no AbstractMethodError: the bridge is there, a no-op like the rest")
    }

    @Test
    fun `names outside the index are left to the extension's loader`() {
        val loader = FrameworkClassLoader(javaClass.classLoader) { null }
        assertFailsWith<ClassNotFoundException> { loader.loadClass("android.test.Missing") }
    }

    @Test
    fun `a class whose supertype nothing has is left to the extension's loader too`() {
        val index = mapOf("android/test/Orphan" to sig("android/test/Orphan", "org/nowhere/Parent"))
        val loader = FrameworkClassLoader(javaClass.classLoader, index::get)
        assertFailsWith<ClassNotFoundException> { loader.loadClass("android.test.Orphan") }
    }

    @Test
    fun `extensions share the framework classes made for them, so both can hand one to the host`() {
        // The host has `static int take(android.test.Thing)` but not Thing. Were each extension's loader to make
        // its own Thing, the JVM would refuse the second extension's call (a loader constraint).
        URLClassLoader(arrayOf(jarOf("test/Host" to hostClass()).toURI().toURL()), javaClass.classLoader).use { hostLoader ->
            val index = mapOf("android/test/Thing" to sig("android/test/Thing", "java/lang/Object", MethodSig(pub, "<init>", "()V")))
            val framework = FrameworkClassLoader(hostLoader, index::get)
            val one = jarOf("test/One" to caller("test/One"))
            val two = jarOf("test/Two" to caller("test/Two"))
            PluginClassLoader(one, one, framework, emptySet()).use { first ->
                PluginClassLoader(two, two, framework, emptySet()).use { second ->
                    assertEquals(1, Class.forName("test.One", true, first).getMethod("run").invoke(null))
                    assertEquals(1, Class.forName("test.Two", true, second).getMethod("run").invoke(null))
                    assertSame(first.loadClass("android.test.Thing"), second.loadClass("android.test.Thing"))
                }
            }
        }
    }

    @Test
    fun `the engine's own index makes Material's button a Button, with enum constants and R ids`() {
        val loader = FrameworkClassLoader(javaClass.classLoader)
        val button = loader.loadClass("com.google.android.material.button.MaterialButton")
        assertEquals("android.widget.Button", button.superclass.superclass.name)
        val scaleTypes = loader.loadClass("android.widget.ImageView\$ScaleType").enumConstants.map { (it as Enum<*>).name }
        assertTrue("CENTER_CROP" in scaleTypes)
        assertNotEquals(0, loader.loadClass("com.google.android.material.R\$id").getField("design_bottom_sheet").getInt(null))
    }

    @Test
    fun `a superclass whose constructors name a class the host lacks still has its subclasses made`() {
        // android.text.Layout(…, Layout.Alignment, …): the host has Layout (a stand-in names it) but not Alignment,
        // which only extensions' loaders make. Reading Layout's constructors by reflection fails on it; StaticLayout,
        // made from the index, chains to the no-argument constructor every generated class has.
        URLClassLoader(arrayOf(jarOf("android/test/Shaped" to shapedClass()).toURI().toURL()), javaClass.classLoader).use { hostLoader ->
            val index = mapOf("android/test/Fancy" to sig("android/test/Fancy", "android/test/Shaped", MethodSig(pub, "<init>", "()V")))
            val fancy = FrameworkClassLoader(hostLoader, index::get).loadClass("android.test.Fancy")
            assertEquals("android.test.Shaped", fancy.superclass.name)
            fancy.getConstructor().newInstance()
        }
    }

    /** `public class android.test.Shaped { protected Shaped() {} public Shaped(android.test.Missing m) {} }`, Missing nowhere. */
    private fun shapedClass(): ByteArray {
        val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
        writer.visit(V1_8, pub or ACC_SUPER, "android/test/Shaped", null, "java/lang/Object", null)
        for ((access, desc) in listOf(ACC_PROTECTED to "()V", pub to "(Landroid/test/Missing;)V")) {
            writer.visitMethod(access, "<init>", desc, null, null).apply {
                visitCode()
                visitVarInsn(ALOAD, 0)
                visitMethodInsn(INVOKESPECIAL, "java/lang/Object", "<init>", "()V", false)
                visitInsn(RETURN)
                visitMaxs(0, 0)
                visitEnd()
            }
        }
        writer.visitEnd()
        return writer.toByteArray()
    }

    /** `public class test.Host { public static int take(android.test.Thing thing) { return 1; } }` */
    private fun hostClass(): ByteArray {
        val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
        writer.visit(V1_8, pub or ACC_SUPER, "test/Host", null, "java/lang/Object", null)
        writer.visitMethod(pub or ACC_STATIC, "take", "(Landroid/test/Thing;)I", null, null).apply {
            visitCode()
            visitInsn(ICONST_1)
            visitInsn(IRETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitEnd()
        return writer.toByteArray()
    }

    /** `public class <name> { public static int run() { return test.Host.take(new android.test.Thing()); } }` */
    private fun caller(name: String): ByteArray {
        val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
        writer.visit(V1_8, pub or ACC_SUPER, name, null, "java/lang/Object", null)
        writer.visitMethod(pub or ACC_STATIC, "run", "()I", null, null).apply {
            visitCode()
            visitTypeInsn(NEW, "android/test/Thing")
            visitInsn(DUP)
            visitMethodInsn(INVOKESPECIAL, "android/test/Thing", "<init>", "()V", false)
            visitMethodInsn(INVOKESTATIC, "test/Host", "take", "(Landroid/test/Thing;)I", false)
            visitInsn(IRETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitEnd()
        return writer.toByteArray()
    }

    private fun jarOf(vararg classes: Pair<String, ByteArray>): File {
        val jar = File(createTempDirectory("framework-loader").toFile(), "classes.jar")
        ZipOutputStream(jar.outputStream()).use { zip ->
            for ((name, bytes) in classes) {
                zip.putNextEntry(ZipEntry("$name.class"))
                zip.write(bytes)
                zip.closeEntry()
            }
        }
        return jar
    }
}
