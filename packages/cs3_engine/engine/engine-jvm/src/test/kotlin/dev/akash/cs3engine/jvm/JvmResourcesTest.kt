package dev.akash.cs3engine.jvm

import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals

class JvmResourcesTest {
    private val fixture = File(javaClass.getResource("/SkyStreamTest.cs3")!!.toURI())

    @Test
    fun `the JVM gives an extension its own resources, made with its class loader`() {
        val loader = JvmPluginLoader(createTempDirectory("converted").toFile())
        val resources = loader.resources(fixture, javaClass.classLoader)
        val title = resources.getIdentifier("title", "string", "dev.akash.cs3test")
        assertEquals("SkyStream test settings", resources.getString(title))
    }
}
