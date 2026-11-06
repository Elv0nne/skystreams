package dev.akash.cs3engine.stubs

import java.io.File
import java.util.zip.ZipFile

/** The test extension (tool/build_test_extension.sh) and its parts. */
object Fixtures {
    val cs3: File get() = File(Fixtures::class.java.getResource("/SkyStreamTest.cs3")!!.toURI())

    fun entry(name: String): ByteArray = ZipFile(cs3).use { zip -> zip.getInputStream(zip.getEntry(name)).readBytes() }

    val arsc: ByteArray get() = entry("resources.arsc")

    /** The same resources with sparse entries and compact entries. */
    val compactArsc: ByteArray get() = Fixtures::class.java.getResource("/compact.arsc")!!.readBytes()
}
