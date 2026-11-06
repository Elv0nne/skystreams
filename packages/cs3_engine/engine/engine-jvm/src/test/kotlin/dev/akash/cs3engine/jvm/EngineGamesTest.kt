package dev.akash.cs3engine.jvm

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import dev.akash.cs3engine.Engine
import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.host.RemoteWebViewHost
import dev.akash.cs3engine.stubs.MainThread
import dev.akash.cs3engine.stubs.Platform
import dev.akash.cs3engine.stubs.Ui
import dev.akash.cs3engine.stubs.WebCookies
import dev.akash.cs3engine.stubs.WebPages
import kotlinx.coroutines.runBlocking
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The test extension's game through the engine's protocol (Phase 7c part 2), the app's browser played by the test:
 * - Play opens its page from the extension's own files, which the app serves;
 * - the page's one-way and answering calls reach its interface in order, with Android's values;
 * - its own dialogs reach its chrome client, or get cancel with none;
 * - its EXIT GAME ends the Play.
 */
class EngineGamesTest {
    private val mapper = jacksonObjectMapper()
    private val events = CopyOnWriteArrayList<JsonNode>()
    private var nextId = 0
    private val playing = Executors.newSingleThreadExecutor()
    private val site = "http://test.invalid/"

    @AfterTest
    fun restore() {
        HostHooks.event = {}
        Platform.install(null)
        Ui.setListener(null)
        MainThread.setAfterTask(null)
        WebPages.install(null)
        RemoteWebViewHost.pageEvents = null
        Ui.windows().forEach { Ui.dismissed(it.owner) }
        WebCookies.clear()
        playing.shutdownNow()
    }

    private fun Engine.call(method: String, vararg params: Pair<String, Any?>): JsonNode {
        val request = mapper.writeValueAsString(mapOf("id" to ++nextId, "method" to method, "params" to mapOf(*params)))
        val response = mapper.readTree(runBlocking { respond(request) })
        check(response.has("result")) { "$method failed: $response" }
        return response["result"]
    }

    private fun await(test: (JsonNode) -> Boolean): JsonNode {
        val until = System.currentTimeMillis() + 30_000
        while (System.currentTimeMillis() < until) {
            events.lastOrNull(test)?.let { return it }
            Thread.sleep(20)
        }
        error("no such event; the last: ${events.lastOrNull()}")
    }

    /** Loads the test extension and Plays its game [title]: the engine, the Play's answer to come, and its page's op. */
    private fun play(title: String): Triple<Engine, Future<JsonNode>, JsonNode> {
        val dataDir = createTempDirectory("engine-games").toFile()
        val engine = JvmEngine.create(dataDir, "test")
        val fixture = File(javaClass.getResource("/SkyStreamTest.cs3")!!.toURI())
        val plugin = File(dataDir, "plugins/SkyStreamTest.cs3").apply {
            parentFile.mkdirs()
            fixture.copyTo(this)
        }
        HostHooks.event = { raw -> events.add(mapper.readTree(raw)) }
        engine.call("loadPlugin", "path" to plugin.path, "url" to "${site}SkyStreamTest.cs3")
        val links = playing.submit<JsonNode> {
            engine.call(
                "loadLinks",
                "provider" to "SkyStream Test A",
                "data" to "https://skystream.invalid/game/$title",
                "plugin" to plugin.path,
            )
        }
        val page = await { it["event"].asText() == "webRequest" && it["op"].asText() == "page" }
        return Triple(engine, links, page)
    }

    @Test
    fun `the game's page opens from its own files, served, and its calls answer in order with Android's values`() {
        val (engine, links, page) = play("1")
        val serve = page["serve"]
        val folder = File(serve["folder"].asText())
        assertEquals("cs3test-game", folder.name)
        assertEquals(1_048_576L, File(folder, "data.bin").length())
        assertEquals("index.html?game=test", serve["path"].asText())
        assertTrue(serve["name"].asText().matches(Regex("[0-9a-f]{20}")), "$serve")
        assertEquals(setOf("closeGame", "saveState", "report"), page["interfaces"]["TestGame"].map { it.asText() }.toSet())
        assertEquals(
            setOf("isReady", "name", "level", "half", "big", "broken", "nothing", "loadState"),
            page["answering"]["TestGame"].map { it.asText() }.toSet(),
        )
        val rid = page["rid"].asLong()
        var calls = 0
        fun post(method: String, vararg args: Any?) = engine.call(
            "webPage",
            "rid" to rid,
            "type" to "message",
            "message" to mapper.writeValueAsString(mapOf("cs3-js" to 1, "name" to "TestGame", "method" to method, "args" to args.toList())),
        )
        fun answer(method: String): JsonNode = engine.call(
            "webPage",
            "rid" to rid,
            "type" to "call",
            "message" to mapper.writeValueAsString(
                mapOf("cs3-js" to 1, "name" to "TestGame", "method" to method, "args" to emptyList<Any>(), "id" to "d.${++calls}"),
            ),
        )
        post("saveState", """{"level":3}""")
        assertEquals("""{"level":3}""", answer("loadState")["value"].asText())
        assertEquals(true, answer("isReady")["value"].asBoolean())
        assertEquals("Test Game ü 🎮\u0000!", answer("name")["value"].asText())
        assertEquals(42, answer("level")["value"].asInt())
        assertEquals(2.5, answer("half")["value"].asDouble())
        assertEquals(1_048_576, answer("big")["value"].asText().length)
        assertEquals("Java exception was raised during method invocation", answer("broken")["error"].asText())
        assertTrue(answer("nothing").isEmpty, "a null String answers undefined, as Android's bridge does")
        // No chrome client: the page's own dialogs get the cancel answer, and nothing shows.
        val alert = engine.call("webPage", "rid" to rid, "type" to "dialog", "kind" to "alert", "message" to "Game ready")
        assertEquals(false, alert["accept"].asBoolean())
        post("closeGame")
        assertEquals(0, links.get(30, TimeUnit.SECONDS)["links"].size())
    }

    @Test
    fun `the second title's chrome client takes the page's dialogs - the prompt answered later, with what it heard`() {
        val (engine, links, page) = play("dialogs")
        val rid = page["rid"].asLong()
        fun dialog(kind: String, message: String, defaultText: String? = null): JsonNode = engine.call(
            "webPage",
            "rid" to rid,
            "type" to "dialog",
            "kind" to kind,
            "message" to message,
            "defaultText" to defaultText,
        )
        assertEquals(true, dialog("alert", "Game ready")["accept"].asBoolean())
        assertEquals(true, dialog("confirm", "Keep playing?")["accept"].asBoolean())
        val prompt = dialog("prompt", "Your name?", "Player")
        assertEquals(true to "heard: Game ready", prompt["accept"].asBoolean() to prompt["text"].asText())
        engine.call(
            "webPage",
            "rid" to rid,
            "type" to "message",
            "message" to """{"cs3-js":1,"name":"TestGame","method":"closeGame","args":[]}""",
        )
        assertEquals(0, links.get(30, TimeUnit.SECONDS)["links"].size())
    }

    @Test
    fun `the third title's plain chrome client leaves the page's dialogs to the app, for SkyStream's own dialog`() {
        // Android's WebView shows its own dialog then; on the JVM the app shows SkyStream's (Phase 7c's §8).
        val (engine, links, page) = play("appdialogs")
        val rid = page["rid"].asLong()
        fun dialog(kind: String, message: String, defaultText: String? = null): JsonNode = engine.call(
            "webPage",
            "rid" to rid,
            "type" to "dialog",
            "kind" to kind,
            "message" to message,
            "defaultText" to defaultText,
        )
        assertEquals(true, dialog("alert", "Game ready").path("show").asBoolean(false))
        assertEquals(true, dialog("confirm", "Keep playing?").path("show").asBoolean(false))
        assertEquals(true, dialog("prompt", "Your name?", "Player").path("show").asBoolean(false))
        engine.call(
            "webPage",
            "rid" to rid,
            "type" to "message",
            "message" to """{"cs3-js":1,"name":"TestGame","method":"closeGame","args":[]}""",
        )
        assertEquals(0, links.get(30, TimeUnit.SECONDS)["links"].size())
    }
}
