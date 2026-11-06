package dev.akash.cs3engine.frameworkgen

import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Opcodes
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempDirectory

/** A class file for tests: members are declared with [members]; methods get no code unless a test adds it. */
fun classBytes(
    name: String,
    superName: String? = "java/lang/Object",
    access: Int = Opcodes.ACC_PUBLIC or Opcodes.ACC_SUPER,
    interfaces: List<String> = emptyList(),
    members: ClassVisitor.() -> Unit = {},
): ByteArray {
    val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
    writer.visit(Opcodes.V11, access, name, null, superName, interfaces.toTypedArray().takeIf { it.isNotEmpty() })
    writer.members()
    writer.visitEnd()
    return writer.toByteArray()
}

/** A declared method without code, as a signature source. */
fun ClassVisitor.declare(access: Int, name: String, desc: String) {
    visitMethod(access, name, desc, null, null).visitEnd()
}

/** A jar of [entries] (path to bytes) in a temporary folder. */
fun jarOf(vararg entries: Pair<String, ByteArray>, fileName: String = "test.jar"): File {
    val jar = File(createTempDirectory("framework-gen").toFile(), fileName)
    jar.writeBytes(zipBytes(*entries))
    return jar
}

fun zipBytes(vararg entries: Pair<String, ByteArray>): ByteArray {
    val bytes = ByteArrayOutputStream()
    ZipOutputStream(bytes).use { zip ->
        for ((path, data) in entries) {
            zip.putNextEntry(ZipEntry(path))
            zip.write(data)
            zip.closeEntry()
        }
    }
    return bytes.toByteArray()
}
