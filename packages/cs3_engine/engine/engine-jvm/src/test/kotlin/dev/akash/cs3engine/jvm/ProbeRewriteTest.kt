package dev.akash.cs3engine.jvm

import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes
import java.io.File
import java.lang.reflect.InvocationTargetException
import java.security.MessageDigest
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertSame

/**
 * An extension asking whether a class exists (WatchParty asks for CloudStream's player, to tell CloudStream
 * from Nuvio) gets Android's answer, though the engine makes placeholders for the app classes it lacks.
 */
class ProbeRewriteTest {
    private val fixture = File(javaClass.getResource("/SkyStreamTest.cs3")!!.toURI())
    private val probes = "dev/akash/cs3engine/stubs/ClassProbes"
    private val missing = "com/lagradost/cloudstream3/ui/player/SkyStreamLacks"

    /** The probes' jar, as the previous cache version kept it, carried over by a conversion. */
    private fun carried(): File {
        val cacheRoot = createTempDirectory("d2j").toFile()
        val hash = MessageDigest.getInstance("SHA-256").digest(fixture.readBytes()).joinToString("") { "%02x".format(it) }
        val previous = File(cacheRoot, "v${Dex2Jar.CACHE_VERSION - 1}/$hash").apply { mkdirs() }
        ZipOutputStream(File(previous, "classes.jar").outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("test/Probe.class"))
            zip.write(probe())
            zip.closeEntry()
        }
        File(previous, "meta.properties").writeText("dexClasses=1\njvmClasses=1\nfailedMethods=0\nconvertMs=1\ninterfaces=\n")
        return Dex2Jar.convert(fixture, cacheRoot).jar
    }

    @Test
    fun `the converter sends an extension's Class forName calls to ClassProbes`() {
        val calls = mutableListOf<String>()
        val bytes = ZipFile(carried()).use { zip -> zip.getInputStream(zip.getEntry("test/Probe.class")).use { it.readBytes() } }
        ClassReader(bytes).accept(
            object : ClassVisitor(Opcodes.ASM9) {
                override fun visitMethod(access: Int, name: String?, descriptor: String?, signature: String?, exceptions: Array<out String>?) =
                    object : MethodVisitor(Opcodes.ASM9) {
                        override fun visitMethodInsn(opcode: Int, owner: String, name: String, descriptor: String, isInterface: Boolean) {
                            if (name == "forName") calls += "$owner.$name$descriptor"
                        }
                    }
            },
            0,
        )
        assertEquals(
            listOf("$probes.forName(Ljava/lang/String;)Ljava/lang/Class;", "$probes.forName(Ljava/lang/String;ZLjava/lang/ClassLoader;)Ljava/lang/Class;"),
            calls,
        )
    }

    @Test
    fun `a probe for an app class SkyStream lacks fails as on Android, while code that uses it still runs`() {
        PluginClassLoader(carried(), fixture, javaClass.classLoader, emptySet()).use { loader ->
            val probe = loader.loadClass("test.Probe")
            fun call(method: String, vararg args: Any?): Any? = try {
                probe.methods.single { it.name == method }.invoke(null, *args)
            } catch (e: InvocationTargetException) {
                throw e.targetException
            }
            // Its placeholder is made for the code that uses the class...
            assertEquals(missing.replace('/', '.'), call("use")!!.javaClass.name)
            // ...yet a probe for it fails, in both forms.
            assertIs<ClassNotFoundException>(assertFailsWith<ClassNotFoundException> { call("one", missing.replace('/', '.')) })
            assertFailsWith<ClassNotFoundException> { call("three", missing.replace('/', '.')) }
            // A probe from the extension's code looks in the extension's class loader, as Class.forName does.
            assertSame(probe, call("one", "test.Probe"))
            assertSame(com.lagradost.cloudstream3.MainAPI::class.java, call("three", "com.lagradost.cloudstream3.MainAPI"))
        }
    }

    /**
     * `class test.Probe { static Class one(String n) { return Class.forName(n); } static Class three(String n)
     * { return Class.forName(n, false, Probe.class.getClassLoader()); } static Object use() { return new SkyStreamLacks(); } }`
     */
    private fun probe(): ByteArray {
        val writer = ClassWriter(ClassWriter.COMPUTE_FRAMES or ClassWriter.COMPUTE_MAXS)
        writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC or Opcodes.ACC_SUPER, "test/Probe", null, "java/lang/Object", null)
        writer.visitMethod(Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC, "one", "(Ljava/lang/String;)Ljava/lang/Class;", null, null).apply {
            visitCode()
            visitVarInsn(Opcodes.ALOAD, 0)
            visitMethodInsn(Opcodes.INVOKESTATIC, "java/lang/Class", "forName", "(Ljava/lang/String;)Ljava/lang/Class;", false)
            visitInsn(Opcodes.ARETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitMethod(Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC, "three", "(Ljava/lang/String;)Ljava/lang/Class;", null, null).apply {
            visitCode()
            visitVarInsn(Opcodes.ALOAD, 0)
            visitInsn(Opcodes.ICONST_0)
            visitLdcInsn(org.objectweb.asm.Type.getObjectType("test/Probe"))
            visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/Class", "getClassLoader", "()Ljava/lang/ClassLoader;", false)
            visitMethodInsn(Opcodes.INVOKESTATIC, "java/lang/Class", "forName", "(Ljava/lang/String;ZLjava/lang/ClassLoader;)Ljava/lang/Class;", false)
            visitInsn(Opcodes.ARETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitMethod(Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC, "use", "()Ljava/lang/Object;", null, null).apply {
            visitCode()
            visitTypeInsn(Opcodes.NEW, missing)
            visitInsn(Opcodes.DUP)
            visitMethodInsn(Opcodes.INVOKESPECIAL, missing, "<init>", "()V", false)
            visitInsn(Opcodes.ARETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitEnd()
        return writer.toByteArray()
    }
}
