package dev.akash.cs3engine.jvm

import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Opcodes
import java.io.File
import java.net.URLClassLoader
import java.security.CodeSigner
import java.security.CodeSource
import java.security.ProtectionDomain
import java.util.zip.ZipFile

/**
 * Loads one converted plugin: classes from [classesJar], resources (manifest.json, assets) from the jar and
 * the .cs3. Framework classes come from [parent]: the engine's stand-ins, or a [FrameworkClassLoader] that
 * makes the others. Names neither has (an app class SkyStream lacks, an API newer than the index) are made
 * here as empty placeholders, so plugin classes that mention them still load; only code that uses them fails.
 * They're marked Placeholder, so a Class.forName probe for one fails as on Android (ClassProbes).
 */
internal class PluginClassLoader(
    classesJar: File,
    cs3: File,
    parent: ClassLoader,
    private val interfaceNames: Set<String>,
) : URLClassLoader(arrayOf(classesJar.toURI().toURL(), cs3.toURI().toURL()), parent) {
    private val classes = ZipFile(classesJar)

    // A thread started while plugin code runs keeps the protection domains on its stack
    // (Thread.inheritedAccessControlContext). URLClassLoader's domains reference their class
    // loader, so such a thread would keep an unloaded plugin in memory; this one does not.
    private val domain = ProtectionDomain(CodeSource(classesJar.toURI().toURL(), null as Array<CodeSigner>?), null)

    override fun findClass(name: String): Class<*> {
        val entry = classes.getEntry(name.replace('.', '/') + ".class")
        val bytes = when {
            entry != null -> classes.getInputStream(entry).use { it.readBytes() }
            isStubbed(name) -> stubClass(name.replace('.', '/'), isInterface = name in interfaceNames)
            else -> throw ClassNotFoundException(name)
        }
        return defineClass(name, bytes, 0, bytes.size, domain)
    }

    override fun close() {
        try {
            super.close()
        } finally {
            classes.close()
        }
    }

    companion object {
        // CloudStream app classes that are not in its library (sync, accounts, home screen...) are
        // stubbed too. Android resolves a missing class only when code uses it; the JVM can need
        // it while verifying a class, which would fail loading plugins that merely mention one.
        private val STUB_PREFIXES = listOf(
            "android.", "androidx.", "com.google.android.", "dalvik.", "org.xmlpull.", "com.lagradost.cloudstream3.",
        )

        /** Classes this loader makes up when the plugin's code mentions them; see [STUB_PREFIXES]. */
        fun isStubbed(className: String): Boolean = STUB_PREFIXES.any { className.startsWith(it) }

        /**
         * Android names its exceptions and errors so. Plugins catch them (ActivityNotFoundException),
         * and the JVM only accepts a Throwable there.
         */
        private fun superclassOf(internalName: String): String = when {
            internalName.endsWith("Exception") -> "java/lang/RuntimeException"
            internalName.endsWith("Error") -> "java/lang/Error"
            else -> "java/lang/Object"
        }

        private val PLACEHOLDER = arrayOf("dev/akash/cs3engine/stubs/Placeholder")

        private fun stubClass(internalName: String, isInterface: Boolean): ByteArray {
            val writer = ClassWriter(0)
            if (isInterface) {
                writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC or Opcodes.ACC_INTERFACE or Opcodes.ACC_ABSTRACT, internalName, null, "java/lang/Object", PLACEHOLDER)
            } else {
                val superclass = superclassOf(internalName)
                writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC or Opcodes.ACC_SUPER, internalName, null, superclass, PLACEHOLDER)
                writer.visitMethod(Opcodes.ACC_PUBLIC, "<init>", "()V", null, null).apply {
                    visitCode()
                    visitVarInsn(Opcodes.ALOAD, 0)
                    visitMethodInsn(Opcodes.INVOKESPECIAL, superclass, "<init>", "()V", false)
                    visitInsn(Opcodes.RETURN)
                    visitMaxs(1, 1)
                    visitEnd()
                }
            }
            writer.visitEnd()
            return writer.toByteArray()
        }
    }
}
