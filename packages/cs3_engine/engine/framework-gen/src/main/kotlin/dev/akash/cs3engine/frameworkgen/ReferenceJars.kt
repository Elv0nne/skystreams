package dev.akash.cs3engine.frameworkgen

import org.objectweb.asm.ClassReader
import org.objectweb.asm.Opcodes
import org.objectweb.asm.tree.ClassNode
import java.io.File
import java.io.InputStream
import java.util.zip.ZipFile
import java.util.zip.ZipInputStream

/** Android's and the libraries' classes: android.jar, plain jars, and AARs (their `classes.jar` and `R.txt`). */
object ReferenceJars {
    private val FRAMEWORK = listOf("android/", "androidx/", "com/google/android/material/")
    private val ANONYMOUS = Regex("\\$[0-9]")

    /** Whether [internalName] is one of the framework's: the names extensions' code may mention. */
    fun isFramework(internalName: String): Boolean = FRAMEWORK.any(internalName::startsWith)

    /** The framework's public classes in [files], by internal name; the first file to have a class wins. */
    fun read(files: List<File>): Map<String, ClassSig> {
        val classes = LinkedHashMap<String, ClassSig>()
        val ids = RIds()
        for (file in files) {
            ZipFile(file).use { zip ->
                if (file.name.endsWith(".aar")) {
                    zip.getEntry("classes.jar")?.let { entry -> zip.getInputStream(entry).use { readJar(it, classes) } }
                    val rTxt = zip.getEntry("R.txt")?.let { entry -> zip.getInputStream(entry).use { it.reader().readText() } }
                    val pkg = zip.getEntry("AndroidManifest.xml")
                        ?.let { entry -> zip.getInputStream(entry).use { it.reader().readText() } }
                        ?.let { Regex("package=\"([^\"]+)\"").find(it)?.groupValues?.get(1) }
                    if (rTxt != null && pkg != null) Signatures.rClasses(rTxt, pkg, ids).forEach { classes.putIfAbsent(it.name, it) }
                } else {
                    for (entry in zip.entries()) {
                        if (entry.name.endsWith(".class")) zip.getInputStream(entry).use { add(it.readBytes(), classes) }
                    }
                }
            }
        }
        return classes
    }

    private fun readJar(jar: InputStream, classes: MutableMap<String, ClassSig>) {
        val zip = ZipInputStream(jar)
        while (true) {
            val entry = zip.nextEntry ?: break
            if (entry.name.endsWith(".class")) add(zip.readBytes(), classes)
        }
    }

    private fun add(bytes: ByteArray, classes: MutableMap<String, ClassSig>) {
        val node = ClassNode()
        ClassReader(bytes).accept(node, ClassReader.SKIP_CODE or ClassReader.SKIP_DEBUG or ClassReader.SKIP_FRAMES)
        if (!isFramework(node.name) || node.access and Opcodes.ACC_PUBLIC == 0 || ANONYMOUS.containsMatchIn(node.name)) return
        classes.putIfAbsent(node.name, ClassSig.of(node))
    }
}
