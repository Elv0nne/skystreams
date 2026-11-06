package dev.akash.cs3engine.jvm

import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Label
import org.objectweb.asm.Opcodes
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals

class PluginClassLoaderTest {
    @Test
    fun `a plugin catching an Android exception the desktop lacks still loads`() {
        // StreamCenter catches ActivityNotFoundException. DEX 035 plugins convert to Java 6 classes
        // without stack map frames, and the JVM's older verifier then wants every catch type to be
        // a Throwable.
        val jar = jarOf("test/Catcher" to catcher("android/content/ActivityNotFoundException"))
        PluginClassLoader(jar, jar, javaClass.classLoader, emptySet()).use { loader ->
            val catcher = Class.forName("test.Catcher", true, loader)
            assertEquals(1, catcher.getMethod("run").invoke(null))
        }
    }

    @Test
    fun `placeholders for missing exceptions, errors and app classes are what the code needs`() {
        val jar = jarOf()
        PluginClassLoader(jar, jar, javaClass.classLoader, emptySet()).use { loader ->
            assertEquals(RuntimeException::class.java, loader.loadClass("android.os.NetworkOnMainThreadException").superclass)
            assertEquals(Error::class.java, loader.loadClass("android.opengl.GLError").superclass)
            assertEquals(Any::class.java, loader.loadClass("com.lagradost.cloudstream3.ui.SomeScreen").superclass)
        }
    }

    /** `public static int run() { try { return 1; } catch ([type] e) { return 2; } }`, as a Java 6 class. */
    private fun catcher(type: String): ByteArray {
        val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
        writer.visit(Opcodes.V1_6, Opcodes.ACC_PUBLIC or Opcodes.ACC_SUPER, "test/Catcher", null, "java/lang/Object", null)
        writer.visitMethod(Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC, "run", "()I", null, null).apply {
            val start = Label()
            val end = Label()
            val handler = Label()
            visitCode()
            visitTryCatchBlock(start, end, handler, type)
            visitLabel(start)
            visitInsn(Opcodes.ICONST_1)
            visitLabel(end)
            visitInsn(Opcodes.IRETURN)
            visitLabel(handler)
            visitInsn(Opcodes.POP)
            visitInsn(Opcodes.ICONST_2)
            visitInsn(Opcodes.IRETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitEnd()
        return writer.toByteArray()
    }

    private fun jarOf(vararg classes: Pair<String, ByteArray>): File {
        val jar = File(createTempDirectory("plugin-loader").toFile(), "classes.jar")
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
