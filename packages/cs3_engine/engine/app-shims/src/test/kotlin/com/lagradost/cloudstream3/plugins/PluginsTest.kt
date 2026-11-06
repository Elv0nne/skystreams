package com.lagradost.cloudstream3.plugins

import com.lagradost.cloudstream3.actions.VideoClickAction
import com.lagradost.cloudstream3.extractors.Chillx
import com.lagradost.cloudstream3.utils.ExtractorApi
import com.lagradost.cloudstream3.utils.ExtractorLink
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PluginsTest {
    private class TestPlugin : Plugin()

    @Test
    fun `a plugin finds the address it was installed from`() {
        // ViStream registers nothing unless it was installed from its own repository.
        val file = File("/plugins/installed-${System.nanoTime()}.cs3")
        val url = "https://gitlab.com/tearrs/cloudstream-vietnamese/-/raw/builds/ViStreamProvider.cs3"
        PluginManager.onLoaded(file, "ViStreamProvider", 35, TestPlugin(), url)
        try {
            val data = PluginManager.getPluginsOnline().single { it.filePath == file.absolutePath }
            assertEquals(url, data.url)
            assertTrue(data.isOnline)
            assertTrue(PluginManager.getPluginsLocal().none { it.filePath == file.absolutePath })
        } finally {
            PluginManager.onUnloaded(file)
        }
    }

    @Test
    fun `a plugin loaded from a file of unknown origin is a local one`() {
        val file = File("/plugins/local-${System.nanoTime()}.cs3")
        PluginManager.onLoaded(file, "Local", 1, TestPlugin(), null)
        try {
            val data = PluginManager.getPluginsLocal().single { it.filePath == file.absolutePath }
            assertNull(data.url)
            assertTrue(PluginManager.getPluginsOnline().none { it.filePath == file.absolutePath })
        } finally {
            PluginManager.onUnloaded(file)
        }
    }

    @Test
    fun `a video click action a plugin registers is marked as the plugin's`() {
        val plugin = TestPlugin().apply { filename = "/plugins/streamcenter.cs3" }
        val action = object : VideoClickAction() {}
        plugin.registerVideoClickAction(action)
        assertEquals("/plugins/streamcenter.cs3", action.sourcePlugin)
    }

    @Test
    fun `Chillx, gone from CloudStream's library, is still an extractor to register and extend`() = runBlocking {
        val chillx: ExtractorApi = Chillx()
        assertEquals("Chillx", chillx.name)
        assertEquals("https://chillx.top", chillx.mainUrl)
        assertTrue(chillx.requiresReferer)
        // FStream's Mela keeps Chillx's code and changes only the site.
        val mela = object : Chillx() {
            override val name = "Mela"
            override val mainUrl = "https://player.example"
        }
        assertEquals("https://player.example", mela.mainUrl)
        val links = mutableListOf<ExtractorLink>()
        chillx.getUrl("https://chillx.top/v/1", null, {}, { links += it })
        assertTrue(links.isEmpty())
    }
}
