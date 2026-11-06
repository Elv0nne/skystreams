package dev.akash.cs3engine.jvm

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import dev.akash.cs3engine.Engine
import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.stubs.FilePreferences
import dev.akash.cs3engine.stubs.MainThread
import dev.akash.cs3engine.stubs.Platform
import dev.akash.cs3engine.stubs.Ui
import kotlinx.coroutines.runBlocking
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The test extension's own windows outside its settings, through the engine's protocol (the spec's pop-up rules). */
class EnginePopupsTest {
    private val mapper = jacksonObjectMapper()
    private val events = CopyOnWriteArrayList<JsonNode>()
    private var nextId = 0

    @AfterTest
    fun restore() {
        HostHooks.event = {}
        Platform.install(null)
        Ui.setListener(null)
        MainThread.setAfterTask(null)
        Ui.windows().forEach { Ui.dismissed(it.owner) }
    }

    private fun Engine.call(method: String, vararg params: Pair<String, Any?>): JsonNode {
        val request = mapper.writeValueAsString(mapOf("id" to ++nextId, "method" to method, "params" to mapOf(*params)))
        val response = mapper.readTree(runBlocking { respond(request) })
        check(response.has("result")) { "$method failed: $response" }
        return response["result"]
    }

    private fun await(test: (JsonNode) -> Boolean): JsonNode {
        val until = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < until) {
            events.lastOrNull(test)?.let { return it }
            Thread.sleep(20)
        }
        error("no such event; the last: ${events.lastOrNull()}")
    }

    private fun windows(session: Int, test: (JsonNode) -> Boolean): JsonNode =
        await { it["event"].asText() == "ui" && it["session"].asInt() == session && test(it["windows"]) }["windows"]

    private fun nodes(node: JsonNode): List<JsonNode> = listOf(node) + (node["children"]?.flatMap(::nodes) ?: emptyList())

    private fun find(windows: JsonNode, kind: String, text: String): JsonNode =
        windows.flatMap { nodes(it["root"]) }.first { it["kind"].asText() == kind && it["text"]?.asText() == text }

    private fun titles(): List<String> = events.last { it["event"].asText() == "popups" }["titles"].map { it.asText() }

    @Test
    fun `the test extension's own windows - Home's kept for Support, search's page dropped, and the links' choice shown while the person waits`() {
        HostHooks.event = { events.add(mapper.readTree(it)) }
        val dataDir = createTempDirectory("engine-popups").toFile()
        val engine = JvmEngine.create(dataDir, "test")
        // Its second provider on: preferences are kept per name for the whole test run, and EngineScreensTest
        // switches it off.
        FilePreferences.get("skystream_test").edit().putBoolean("second_provider", true).commit()
        val fixture = File(javaClass.getResource("/SkyStreamTest.cs3")!!.toURI())
        val plugin = File(dataDir, "plugins/SkyStreamTest.cs3").apply { parentFile.mkdirs(); fixture.copyTo(this) }
        engine.call("loadPlugin", "path" to plugin.path)

        // Home, from both providers: the same support pop-up, kept once (Review Focus 1); no screen opens.
        engine.call("mainPage", "provider" to "SkyStream Test A", "plugin" to plugin.path)
        engine.call("mainPage", "provider" to "SkyStream Test B", "plugin" to plugin.path)
        await { it["event"].asText() == "popups" && it["titles"].size() == 1 }
        Thread.sleep(300)
        assertEquals(listOf("Support SkyStream Test"), titles())
        assertTrue(events.none { it["event"].asText() == "uiOpened" })

        // Support: the kept pop-up opens live; its button thanks in place; Later closes it.
        val support = engine.call("openPopups", "path" to plugin.path)["session"].asInt()
        val shown = windows(support) { it.size() == 1 && it.toString().contains("Keep the test extension alive.") }
        engine.call("uiAction", "session" to support, "node" to find(shown, "button", "Count me in")["id"].asInt(), "action" to "click")
        val thanked = windows(support) { it.toString().contains("Thanks!") }
        engine.call("uiAction", "session" to support, "node" to find(thanked, "button", "Later")["id"].asInt(), "action" to "click")
        await { it["event"].asText() == "uiClosed" && it["session"].asInt() == support }
        assertEquals(emptyList(), titles())

        // Search: its own bot check holds a page its call waits on: dropped once sorted, 5 s on, so the search doesn't
        // wait it out (20 s).
        val started = System.currentTimeMillis()
        engine.call("search", "provider" to "SkyStream Test A", "query" to "anything", "plugin" to plugin.path)
        assertTrue(System.currentTimeMillis() - started < 10_000, "the search didn't wait out its page")
        await { it["event"].asText() == "popupDropped" && it["reason"].asText() == "page" }

        // Links: the person waits, so the choice opens a screen of its own; their pick reaches the extension.
        var links: JsonNode? = null
        val playing = thread {
            links = engine.call("loadLinks", "provider" to "SkyStream Test A", "data" to "https://skystream.invalid/play/1", "plugin" to plugin.path)
        }
        val waiting = await { it["event"].asText() == "uiOpened" }["session"].asInt()
        val choice = windows(waiting) { it.toString().contains("Server 2") }
        engine.call("uiAction", "session" to waiting, "node" to find(choice, "button", "Server 2")["id"].asInt(), "action" to "click")
        playing.join(30_000)
        assertTrue(links!!["links"][0]["url"].asText().endsWith("server-2.m3u8"), "the pick reached the extension: $links")
        await { it["event"].asText() == "uiClosed" && it["session"].asInt() == waiting }
        engine.call("unloadPlugin", "path" to plugin.path)
    }
}
