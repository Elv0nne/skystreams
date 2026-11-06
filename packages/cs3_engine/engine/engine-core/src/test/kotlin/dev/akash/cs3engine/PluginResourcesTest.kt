package dev.akash.cs3engine

import android.content.Context
import android.content.res.Resources
import com.lagradost.cloudstream3.plugins.Plugin
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class PluginResourcesTest {
    private fun cs3(requiresResources: Boolean): File {
        val file = File.createTempFile("resources", ".cs3").apply { deleteOnExit() }
        ZipOutputStream(file.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("manifest.json"))
            val manifest = """{"name":"R","pluginClassName":"${ResourcesPlugin::class.java.name}","version":1,"requiresResources":$requiresResources}"""
            zip.write(manifest.toByteArray())
            zip.closeEntry()
        }
        return file
    }

    private class Loader(private val resources: Resources) : PluginLoader {
        val asked = mutableListOf<Pair<File, ClassLoader>>()

        override fun prepare(file: File) = PreparedPlugin(PluginResourcesTest::class.java.classLoader)

        override fun resources(file: File, classLoader: ClassLoader): Resources {
            asked += file to classLoader
            return resources
        }
    }

    @Test
    fun `a plugin that asks for resources has them before it loads, made with its own class loader`() {
        val resources = Resources()
        val loader = Loader(resources)
        val registry = PluginRegistry(loader) { Context() }
        val file = cs3(requiresResources = true)
        val loaded = registry.load(file, null)
        assertSame(resources, ResourcesPlugin.seen)
        assertEquals(listOf(file to PluginResourcesTest::class.java.classLoader), loader.asked)
        registry.unload(loaded)
    }

    @Test
    fun `a plugin that doesn't ask gets none, and its file isn't read for them`() {
        val loader = Loader(Resources())
        val registry = PluginRegistry(loader) { Context() }
        ResourcesPlugin.seen = null
        val loaded = registry.load(cs3(requiresResources = false), null)
        assertNull(ResourcesPlugin.seen)
        assertTrue(loader.asked.isEmpty())
        registry.unload(loaded)
    }
}

/** Notes the resources it has when it loads. */
class ResourcesPlugin : Plugin() {
    override fun load(context: Context) {
        seen = resources
    }

    companion object {
        @JvmStatic
        var seen: Resources? = null
    }
}
