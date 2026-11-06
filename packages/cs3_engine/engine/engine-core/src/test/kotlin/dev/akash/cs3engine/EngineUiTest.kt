package dev.akash.cs3engine

import android.content.Context
import com.fasterxml.jackson.databind.JsonNode
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.plugins.Plugin
import com.lagradost.cloudstream3.utils.ExtractorLink
import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.ui.ExtensionUiHost
import dev.akash.cs3engine.ui.Popups
import dev.akash.cs3engine.ui.Sorting
import dev.akash.cs3engine.ui.UiSession
import kotlinx.coroutines.runBlocking
import java.io.File
import java.util.Collections
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertSame

class EngineUiTest {
    private fun cs3(className: String): File {
        val file = File.createTempFile("engine-ui", ".cs3").apply { deleteOnExit() }
        ZipOutputStream(file.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("manifest.json"))
            zip.write("""{"name":"Test","pluginClassName":"$className","version":1}""".toByteArray())
            zip.closeEntry()
        }
        return file
    }

    /** Plugin classes come from the test's own class path. */
    private object TestLoader : PluginLoader {
        override fun prepare(file: File) = PreparedPlugin(EngineUiTest::class.java.classLoader)
    }

    /** A platform whose extension shows one window; [order] hears when its windows close. */
    private class Host(private val order: MutableList<String>? = null) : ExtensionUiHost {
        /** The pop-up rules, as a platform asks them. */
        var popups: Popups? = null

        override fun attach(popups: Popups) {
            this.popups = popups
        }

        override suspend fun open(session: UiSession, plugin: File, open: () -> Unit) {
            open()
            session.publish(listOf(mapOf("id" to "w1")))
        }

        override suspend fun act(session: UiSession, node: Int, action: String, value: Any?) {}

        override suspend fun close(session: UiSession, force: Boolean) {
            order?.add("windows closed")
            session.end("closed")
        }

        override suspend fun openKept(session: UiSession, plugin: File): Boolean {
            session.publish(listOf(mapOf("id" to "w1", "kind" to "dialog")))
            return true
        }
    }

    private val context = Context()

    private fun engine() = Engine(TestLoader, { context }, "test", Host())

    private fun params(vararg pairs: Pair<String, Any?>): JsonNode = Json.mapper.valueToTree(mapOf(*pairs))

    @Suppress("UNCHECKED_CAST")
    private suspend fun Engine.answer(method: String, vararg pairs: Pair<String, Any?>) =
        execute(method, params(*pairs)) as Map<String, Any?>

    @Test
    fun `a loaded plugin says whether it has a settings screen, which opens with the app's context`() = runBlocking {
        val engine = engine()
        val file = cs3(SettingsPlugin::class.java.name)
        assertEquals(true, engine.answer("loadPlugin", "path" to file.path)["hasSettings"])
        assertEquals(mapOf("session" to 1), engine.answer("openSettings", "path" to file.path))
        assertSame(context, SettingsPlugin.openedWith)
        engine.answer("unloadPlugin", "path" to file.path)
        Unit
    }

    @Test
    fun `reloadPlugin runs the plugin's load again, where loadPlugin keeps it`() = runBlocking {
        val engine = engine()
        val file = cs3(SettingsPlugin::class.java.name)
        engine.answer("loadPlugin", "path" to file.path)
        val before = SettingsPlugin.loads
        engine.answer("loadPlugin", "path" to file.path)
        assertEquals(before, SettingsPlugin.loads)
        assertEquals(true, engine.answer("reloadPlugin", "path" to file.path)["hasSettings"])
        assertEquals(before + 1, SettingsPlugin.loads)
        engine.answer("unloadPlugin", "path" to file.path)
        Unit
    }

    @Test
    fun `a plugin without settings says so, and its screen can't open`() = runBlocking {
        val engine = engine()
        val file = cs3(PlainPlugin::class.java.name)
        assertEquals(false, engine.answer("loadPlugin", "path" to file.path)["hasSettings"])
        assertFailsWith<IllegalStateException> { engine.answer("openSettings", "path" to file.path) }
        engine.answer("unloadPlugin", "path" to file.path)
        Unit
    }

    @Test
    fun `the plugin a class or an error's stack belongs to is found`() = runBlocking {
        val engine = engine()
        val file = cs3(SettingsPlugin::class.java.name)
        engine.answer("loadPlugin", "path" to file.path)
        assertEquals(file.absoluteFile, engine.pluginFileOf(SettingsPlugin::class.java)?.absoluteFile)
        engine.answer("unloadPlugin", "path" to file.path)
        Unit
    }

    @Test
    fun `a plugin unloaded under its open screen ends the screen, whose windows close before the plugin goes`() = runBlocking {
        val sent = mutableListOf<JsonNode>()
        val before = HostHooks.event
        HostHooks.event = { sent.add(Json.mapper.readTree(it)) }
        val order = Collections.synchronizedList(mutableListOf<String>())
        UnloadedPlugin.order = order
        try {
            val engine = Engine(TestLoader, { context }, "test", Host(order))
            val file = cs3(UnloadedPlugin::class.java.name)
            engine.answer("loadPlugin", "path" to file.path)
            engine.answer("openSettings", "path" to file.path)
            // An update installed, or a utility plugin run again, while the person has its settings open.
            engine.answer("unloadPlugin", "path" to file.path)
            assertEquals(listOf("windows closed", "plugin unloaded"), order)
            val closed = sent.single { it["event"].asText() == "uiClosed" }
            assertEquals(1, closed["session"].asInt())
            assertEquals("unloaded", closed["reason"].asText())
        } finally {
            HostHooks.event = before
            UnloadedPlugin.order = null
        }
        Unit
    }

    @Test
    fun `a notice carries its extension, and the session of the screen it has open`() = runBlocking {
        val sent = mutableListOf<JsonNode>()
        val before = HostHooks.event
        HostHooks.event = { sent.add(Json.mapper.readTree(it)) }
        try {
            val engine = engine()
            val file = cs3(SettingsPlugin::class.java.name)
            engine.answer("loadPlugin", "path" to file.path)
            engine.notice("toast", file, mapOf("text" to "Saved"))
            engine.answer("openSettings", "path" to file.path)
            engine.notice("openUrl", file, mapOf("url" to "https://example.com"))
            engine.notice("copy", null, mapOf("text" to "abc"))
            val notices = sent.filter { it["event"].asText() in setOf("toast", "openUrl", "copy") }
            assertEquals(listOf("toast", "openUrl", "copy"), notices.map { it["event"].asText() })
            assertEquals("Saved", notices[0]["text"].asText())
            assertEquals(file.absolutePath, notices[0]["plugin"].asText())
            assertFalse(notices[0].has("session"), "no screen open yet")
            assertEquals(1, notices[1]["session"].asInt())
            assertEquals("https://example.com", notices[1]["url"].asText())
            assertFalse(notices[2].has("plugin"))
            engine.answer("unloadPlugin", "path" to file.path)
        } finally {
            HostHooks.event = before
        }
        Unit
    }

    @Test
    fun `a plugin's own load counts as a call - a background page it waits on is dropped, not kept as a promotion`() = runBlocking {
        // As before part 5, where every page was dropped (the final review, 2026-10-07): else the load waits 120 s.
        val host = Host()
        val engine = Engine(TestLoader, { context }, "test", host)
        val file = cs3(PageOnLoadPlugin::class.java.name)
        var sorted: Sorting? = null
        // The page's second sort, 5 s on, while the plugin's load still waits on it.
        PageOnLoadPlugin.duringLoad = { sorted = host.popups!!.sortPage(file) }
        try {
            engine.answer("loadPlugin", "path" to file.path)
            assertEquals(Sorting.Drop, sorted)
            assertEquals(Sorting.Keep, host.popups!!.sortPage(file), "loaded: no call of its runs")
            engine.answer("reloadPlugin", "path" to file.path)
            assertEquals(Sorting.Drop, sorted, "a reload runs its load again")
            engine.answer("unloadPlugin", "path" to file.path)
        } finally {
            PageOnLoadPlugin.duringLoad = null
        }
        Unit
    }

    @Test
    fun `openPopups opens an extension's kept windows as a screen`() = runBlocking {
        val engine = engine()
        val file = cs3(PlainPlugin::class.java.name)
        engine.answer("loadPlugin", "path" to file.path)
        assertEquals(mapOf("session" to 1), engine.answer("openPopups", "path" to file.path))
        engine.answer("unloadPlugin", "path" to file.path)
        Unit
    }

    @Test
    fun `a links call doesn't time out while its extension's full-screen window shows, and says it showed`() = runBlocking {
        // Phase 7c's §4: a game left open past its call's time keeps the call; its end, with no links, says so.
        val host = Host()
        // The screen's own hold on the shared clock ends at once here: only the full-screen window holds the call.
        val engine = Engine(TestLoader, { context }, "test", host, waitingHoldLimitMs = 50)
        val file = cs3(GamePlugin::class.java.name)
        engine.answer("loadPlugin", "path" to file.path)
        fun showFor(ms: Long, fullScreen: Boolean) {
            GameApi.duringLinks = {
                val shown = host.popups!!.sort(file, holdsPage = true) as Sorting.Show
                shown.session.publish(listOf(if (fullScreen) mapOf("id" to "w1", "fullScreen" to true) else mapOf("id" to "w1")))
                Thread.sleep(ms)
                shown.session.end("closed")
            }
        }
        try {
            showFor(700, fullScreen = true)
            val game = engine.answer("loadLinks", "provider" to "Test game", "data" to "game", "timeoutMs" to 300)
            assertEquals(true, game["completed"], "700 ms of game didn't count against 300")
            assertEquals(true, game["fullScreen"])
            assertEquals(emptyList<Any>(), game["links"])
            showFor(700, fullScreen = false)
            val plain = engine.answer("loadLinks", "provider" to "Test game", "data" to "game", "timeoutMs" to 300)
            assertEquals(false, plain["completed"], "a window that isn't full screen holds only the screen's own 50 ms")
            assertFalse("fullScreen" in plain)
        } finally {
            GameApi.duringLinks = null
            engine.answer("unloadPlugin", "path" to file.path)
        }
        Unit
    }

    @Test
    fun `a links call that went on after its full-screen window, and found none, doesn't end quietly`() = runBlocking {
        // The owner's call (2026-10-09): a check shown before the links isn't the call itself, as a game is; finding no
        // links after it is the person's to hear ("No streams found", with Retry).
        val host = Host()
        val engine = Engine(TestLoader, { context }, "test", host, waitingHoldLimitMs = 50, quietEndMs = 200)
        val file = cs3(GamePlugin::class.java.name)
        engine.answer("loadPlugin", "path" to file.path)
        fun showThen(afterMs: Long) {
            GameApi.duringLinks = {
                val shown = host.popups!!.sort(file, holdsPage = true) as Sorting.Show
                shown.session.publish(listOf(mapOf("id" to "w1", "fullScreen" to true)))
                Thread.sleep(100)
                shown.session.publish(emptyList())
                Thread.sleep(afterMs)
                shown.session.end("closed")
            }
        }
        try {
            showThen(afterMs = 500)
            val check = engine.answer("loadLinks", "provider" to "Test game", "data" to "check", "timeoutMs" to 5_000)
            assertEquals(emptyList<Any>(), check["links"])
            assertFalse("fullScreen" in check, "it went on 500 ms after its window: past the 200 ms a game's end takes")
            showThen(afterMs = 0)
            val game = engine.answer("loadLinks", "provider" to "Test game", "data" to "game", "timeoutMs" to 5_000)
            assertEquals(true, game["fullScreen"], "it ended with its window")
        } finally {
            GameApi.duringLinks = null
            engine.answer("unloadPlugin", "path" to file.path)
        }
        Unit
    }
}

/** A plugin with a settings screen, counting its loads. */
class SettingsPlugin : Plugin() {
    override fun load(context: Context) {
        loads++
        openSettings = { openedWith = it }
    }

    companion object {
        @JvmStatic
        var loads = 0

        @JvmStatic
        var openedWith: Context? = null
    }
}

/** A plugin without one. */
class PlainPlugin : Plugin()

/** A plugin whose load runs [duringLoad]: a page it shows and waits on is sorted meanwhile. */
class PageOnLoadPlugin : Plugin() {
    override fun load(context: Context) {
        duringLoad?.invoke()
    }

    companion object {
        @JvmStatic
        var duringLoad: (() -> Unit)? = null
    }
}

/** A plugin with a settings screen that says when it is unloaded. */
class UnloadedPlugin : Plugin() {
    override fun load(context: Context) {
        openSettings = {}
    }

    override fun beforeUnload() {
        order?.add("plugin unloaded")
    }

    companion object {
        @JvmStatic
        var order: MutableList<String>? = null
    }
}

/** A plugin whose one provider's links run [GameApi.duringLinks], as Ayu's games show their full-screen window there. */
class GamePlugin : Plugin() {
    override fun load(context: Context) {
        registerMainAPI(GameApi())
    }
}

class GameApi : MainAPI() {
    override var name = "Test game"

    override suspend fun loadLinks(
        data: String,
        isCasting: Boolean,
        subtitleCallback: (SubtitleFile) -> Unit,
        callback: (ExtractorLink) -> Unit,
    ): Boolean {
        duringLinks?.invoke()
        return false
    }

    companion object {
        @JvmStatic
        var duringLinks: (() -> Unit)? = null
    }
}
