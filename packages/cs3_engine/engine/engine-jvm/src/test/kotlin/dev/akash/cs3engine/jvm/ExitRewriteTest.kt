package dev.akash.cs3engine.jvm

import dev.akash.cs3engine.stubs.Platform
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes
import java.io.File
import java.lang.reflect.InvocationTargetException
import java.net.URLClassLoader
import java.security.MessageDigest
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class ExitRewriteTest {
    private val fixture = File(javaClass.getResource("/SkyStreamTest.cs3")!!.toURI())
    private val exits = "dev/akash/cs3engine/stubs/Exits"

    /** Every method call [className] makes, as owner.name+descriptor, in order. */
    private fun calls(jar: File, className: String): List<String> {
        val calls = mutableListOf<String>()
        val bytes = ZipFile(jar).use { zip -> zip.getInputStream(zip.getEntry("$className.class")).use { it.readBytes() } }
        ClassReader(bytes).accept(
            object : ClassVisitor(Opcodes.ASM9) {
                override fun visitMethod(access: Int, name: String?, descriptor: String?, signature: String?, exceptions: Array<out String>?) =
                    object : MethodVisitor(Opcodes.ASM9) {
                        override fun visitMethodInsn(opcode: Int, owner: String, name: String, descriptor: String, isInterface: Boolean) {
                            calls += "$owner.$name$descriptor"
                        }
                    }
            },
            0,
        )
        return calls
    }

    @Test
    fun `the converter sends an extension's exits to the engine's stand-ins`() {
        val result = Dex2Jar.convert(fixture, createTempDirectory("d2j").toFile())
        val calls = calls(result.jar, "dev/akash/cs3test/RestartKt")
        assertEquals(2, calls.count { it == "$exits.exit(Ljava/lang/Runtime;I)V" }, "both restarts' Runtime.exit")
        assertTrue(calls.none { it.startsWith("java/lang/Runtime.exit") })
    }

    @Test
    fun `a conversion the previous version cached is carried over with its exits rewritten, not converted again`() {
        val cacheRoot = createTempDirectory("d2j").toFile()
        val hash = MessageDigest.getInstance("SHA-256").digest(fixture.readBytes()).joinToString("") { "%02x".format(it) }
        val previous = File(cacheRoot, "v${Dex2Jar.CACHE_VERSION - 1}/$hash").apply { mkdirs() }
        ZipOutputStream(File(previous, "classes.jar").outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("test/Quits.class"))
            zip.write(quits())
            zip.closeEntry()
        }
        File(previous, "meta.properties").writeText("dexClasses=1\njvmClasses=1\nfailedMethods=0\nconvertMs=1234\ninterfaces=\n")

        val result = Dex2Jar.convert(fixture, cacheRoot)
        assertTrue(result.cached)
        assertEquals(1234L, result.ms, "the first conversion's notes are kept")
        assertEquals(
            listOf("$exits.exit(I)V", "java/lang/Runtime.getRuntime()Ljava/lang/Runtime;", "$exits.halt(Ljava/lang/Runtime;I)V"),
            calls(result.jar, "test/Quits"),
            "the jar carried over, not the fixture converted again",
        )
        assertFalse(previous.exists())

        // The rewritten class verifies, and its exit stops the code instead of the engine.
        Platform.install(null)
        URLClassLoader(arrayOf(result.jar.toURI().toURL()), javaClass.classLoader).use { loader ->
            val quit = Class.forName("test.Quits", true, loader).getMethod("quit")
            val error = assertFailsWith<InvocationTargetException> { quit.invoke(null) }.targetException
            assertIs<IllegalStateException>(error)
            assertContains(error.message.orEmpty(), "exit(1) blocked")
        }
    }

    /** `class test.Quits { static void quit() { System.exit(1); Runtime.getRuntime().halt(2); } }`, with its frames. */
    private fun quits(): ByteArray {
        val writer = ClassWriter(ClassWriter.COMPUTE_FRAMES or ClassWriter.COMPUTE_MAXS)
        writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC or Opcodes.ACC_SUPER, "test/Quits", null, "java/lang/Object", null)
        writer.visitMethod(Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC, "quit", "()V", null, null).apply {
            visitCode()
            visitInsn(Opcodes.ICONST_1)
            visitMethodInsn(Opcodes.INVOKESTATIC, "java/lang/System", "exit", "(I)V", false)
            visitMethodInsn(Opcodes.INVOKESTATIC, "java/lang/Runtime", "getRuntime", "()Ljava/lang/Runtime;", false)
            visitInsn(Opcodes.ICONST_2)
            visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/Runtime", "halt", "(I)V", false)
            visitInsn(Opcodes.RETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitEnd()
        return writer.toByteArray()
    }
}
