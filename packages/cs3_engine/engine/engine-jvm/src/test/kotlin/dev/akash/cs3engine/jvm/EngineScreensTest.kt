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
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The test extension's own screen, through the engine's protocol, as SkyStream's sheet drives it. */
class EngineScreensTest {
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

    /** [session]'s windows, from its latest ui event, once [test] accepts them. */
    private fun windows(session: Int, test: (JsonNode) -> Boolean): JsonNode =
        await { it["event"].asText() == "ui" && it["session"].asInt() == session && test(it["windows"]) }["windows"]

    private fun nodes(node: JsonNode): List<JsonNode> = listOf(node) + (node["children"]?.flatMap(::nodes) ?: emptyList())

    /** The first node of [kind] (with [text]) in [windows]. */
    private fun find(windows: JsonNode, kind: String, text: String? = null): JsonNode =
        windows.flatMap { nodes(it["root"]) }.first { it["kind"].asText() == kind && (text == null || it["text"]?.asText() == text) }

    @Test
    fun `the test extension's screen opens, takes the person's changes, saves them, and its restart reloads it`() {
        HostHooks.event = { events.add(mapper.readTree(it)) }
        val dataDir = createTempDirectory("engine-screens").toFile()
        val engine = JvmEngine.create(dataDir, "test")
        val fixture = File(javaClass.getResource("/SkyStreamTest.cs3")!!.toURI())
        val plugin = File(dataDir, "plugins/SkyStreamTest.cs3").apply { parentFile.mkdirs(); fixture.copyTo(this) }
        assertTrue(engine.call("loadPlugin", "path" to plugin.path)["hasSettings"].asBoolean())

        val session = engine.call("openSettings", "path" to plugin.path)["session"].asInt()
        val sheet = windows(session) { it.size() == 1 }
        assertEquals("sheet", sheet[0]["kind"].asText())
        find(sheet, "text", "SkyStream test settings")
        assertEquals(40, find(sheet, "list")["items"].asInt())
        val second = find(sheet, "checkbox")
        assertTrue(second["checked"].asBoolean())

        engine.call("uiAction", "session" to session, "node" to second["id"].asInt(), "action" to "check", "value" to false)
        windows(session) { !find(it, "checkbox")["checked"].asBoolean() }
        engine.call("uiAction", "session" to session, "node" to find(sheet, "field")["id"].asInt(), "action" to "text", "value" to "abc")
        engine.call("uiAction", "session" to session, "node" to find(sheet, "button", "Save")["id"].asInt(), "action" to "click")
        val withAlert = windows(session) { it.size() == 2 }
        assertEquals("alert", withAlert[1]["kind"].asText())
        find(withAlert, "text", "Restart required")

        val yes = find(withAlert, "button", "Yes")["id"].asInt()
        assertTrue(engine.call("uiAction", "session" to session, "node" to yes, "action" to "click")["restarted"].asBoolean())
        assertEquals(plugin.absolutePath, await { it["event"].asText() == "restartRequested" }["plugin"].asText())
        await { it["event"].asText() == "uiClosed" && it["session"].asInt() == session && it["reason"].asText() == "restart" }

        val saved = FilePreferences.get("skystream_test")
        assertFalse(saved.getBoolean("second_provider", true))
        assertEquals("abc", saved.getString("token", null))
        assertEquals("test", engine.call("hello")["platform"].asText(), "SkyStream runs on: no exit reached the engine")
    }
}
