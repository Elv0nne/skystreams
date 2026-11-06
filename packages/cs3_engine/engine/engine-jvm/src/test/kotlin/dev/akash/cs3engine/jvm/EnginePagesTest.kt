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
import kotlin.concurrent.thread
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The test extension's pages through the engine's protocol, the app's browser played by the test: its sign-in in its
 * settings (cookie, header, interface, title, agent, redirect), a page while the person waits, and a page promotion
 * kept for Support.
 */
class EnginePagesTest {
    private val mapper = jacksonObjectMapper()
    private val events = CopyOnWriteArrayList<JsonNode>()
    private var nextId = 0
    private val app = Executors.newSingleThreadExecutor()
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
        app.shutdownNow()
    }

    private fun Engine.call(method: String, vararg params: Pair<String, Any?>): JsonNode {
        val request = mapper.writeValueAsString(mapOf("id" to ++nextId, "method" to method, "params" to mapOf(*params)))
        val response = mapper.readTree(runBlocking { respond(request) })
        check(response.has("result")) { "$method failed: $response" }
        return response["result"]
    }

    private fun await(test: (JsonNode) -> Boolean): JsonNode {
        val until = System.currentTimeMillis() + 15_000
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

    /** Waits until screen [session] shows a page: what the sheet draws before the page loads. */
    private fun shown(session: Int) {
        windows(session) { it.toString().contains("\"kind\":\"page\"") }
    }

    /** The app's browser, played: each page the engine opens loads as the site's would, by what [script] says. */
    private fun browse(engine: Engine, script: (rid: Long, url: String) -> List<Map<String, Any?>>) {
        HostHooks.event = { raw ->
            val event = mapper.readTree(raw)
            events.add(event)
            if (event["event"].asText() == "webRequest") {
                val rid = event["rid"].asLong()
                when (event["op"].asText()) {
                    "page", "navigate" -> app.execute {
                        // The app shows the page where its node is, then it loads: a real page takes longer than a read.
                        if (event["op"].asText() == "page") shown(event["session"].asInt())
                        for (step in script(rid, event["url"].asText())) engine.call("webPage", *(step + ("rid" to rid)).toList().toTypedArray())
                    }
                    "eval" -> app.execute {
                        val answer = if (event["script"].asText() == "document.title") "\"SkyStream Test sign-in\"" else "null"
                        engine.call("webReply", "rid" to rid, "result" to answer)
                    }
                }
            }
        }
    }

    private fun start(name: String): Pair<Engine, File> {
        val dataDir = createTempDirectory(name).toFile()
        val engine = JvmEngine.create(dataDir, "test")
        val fixture = File(javaClass.getResource("/SkyStreamTest.cs3")!!.toURI())
        val plugin = File(dataDir, "plugins/SkyStreamTest.cs3").apply { parentFile.mkdirs(); fixture.copyTo(this) }
        return engine to plugin
    }

    @Test
    fun `the sign-in page in its settings - its cookie, header, interface call, title, agent and redirect reach the extension`() {
        val (engine, plugin) = start("engine-pages-signin")
        browse(engine) { _, url ->
            if (url.endsWith("signin.html")) {
                listOf(
                    mapOf("type" to "started", "url" to url),
                    mapOf("type" to "request", "url" to "${site}api/me", "method" to "GET", "headers" to mapOf("Authorization" to "Bearer cs3test-token")),
                    mapOf("type" to "message", "message" to """{"cs3-js": 1, "name": "SkyStreamTest", "method": "signedIn", "args": ["Test Person", "SkyStreamTest/1.0 (sign-in)"]}"""),
                    mapOf("type" to "finished", "url" to url, "title" to "SkyStream Test sign-in", "cookies" to listOf(mapOf("name" to "cs3test_session", "value" to "signed-in", "domain" to "test.invalid"))),
                    mapOf("type" to "started", "url" to "${site}signed-in.html?code=cs3test-code"),
                )
            } else {
                emptyList()
            }
        }
        engine.call("loadPlugin", "path" to plugin.path, "url" to "${site}SkyStreamTest.cs3")
        val session = engine.call("openSettings", "path" to plugin.path)["session"].asInt()
        val settings = windows(session) { it.toString().contains("Sign in to the test site") }
        engine.call("uiAction", "session" to session, "node" to find(settings, "button", "Sign in to the test site")["id"].asInt(), "action" to "click")
        val page = await { it["event"].asText() == "webRequest" && it["op"].asText() == "page" }
        assertEquals(session, page["session"].asInt())
        assertEquals("${site}signin.html", page["url"].asText())
        assertEquals("SkyStreamTest/1.0 (sign-in)", page["userAgent"].asText())
        assertEquals("signedIn", page["interfaces"]["SkyStreamTest"][0].asText())
        assertTrue(windows(session) { it.toString().contains("\"page\"") }.size() >= 1, "the page node is in the screen")
        val signedIn = windows(session) { it.toString().contains("Signed in:") }
        assertTrue(
            signedIn.toString().contains(
                "Signed in: cookie ok, token cs3test-token, name Test Person, title SkyStream Test sign-in, code cs3test-code, agent ok",
            ),
            "$signedIn",
        )
        await { it["event"].asText() == "webRequest" && it["op"].asText() == "closePage" && it["rid"].asLong() == page["rid"].asLong() }
        engine.call("closeUi", "session" to session, "force" to true)
        await { it["event"].asText() == "uiClosed" && it["session"].asInt() == session }
        engine.call("unloadPlugin", "path" to plugin.path)
    }

    @Test
    fun `a page while the person waits opens a screen with the page in it, and a page promotion is kept for Support`() {
        val (engine, plugin) = start("engine-pages-popups")
        browse(engine) { _, url -> listOf(mapOf("type" to "started", "url" to url), mapOf("type" to "finished", "url" to url)) }
        engine.call("loadPlugin", "path" to plugin.path, "url" to "${site}SkyStreamTest.cs3")

        // Home's second page shows a page no call waits on: kept, 5 s on, and Support opens it with its page. First:
        // within 5 s after a title opens, the extension's windows are the person's, not the background's.
        engine.call("mainPage", "provider" to "SkyStream Test A", "page" to 2, "plugin" to plugin.path)
        await { it["event"].asText() == "popups" && it["titles"].map { t -> t.asText() }.contains("Test promotion") }
        assertTrue(events.none { it["event"].asText() == "popupDropped" })
        val support = engine.call("openPopups", "path" to plugin.path)["session"].asInt()
        val promo = await { it["event"].asText() == "webRequest" && it["op"].asText() == "page" && it["session"].asInt() == support }
        assertEquals("${site}promo.html", promo["url"].asText())
        engine.call("closeUi", "session" to support, "force" to true)
        await { it["event"].asText() == "uiClosed" && it["session"].asInt() == support }

        // Opening a title waits on a page: it opens in a screen of its own, page and all; closing it ends the wait.
        var loaded: JsonNode? = null
        val opening = thread {
            loaded = engine.call("load", "provider" to "SkyStream Test A", "url" to "https://skystream.invalid/movie/1#verify", "plugin" to plugin.path)
        }
        val waiting = await { it["event"].asText() == "uiOpened" }["session"].asInt()
        val page = await { it["event"].asText() == "webRequest" && it["op"].asText() == "page" && it["session"].asInt() == waiting }
        assertEquals("${site}verify.html", page["url"].asText())
        engine.call("closeUi", "session" to waiting)
        opening.join(30_000)
        assertEquals("Test Movie", loaded!!["name"].asText())
        await { it["event"].asText() == "uiClosed" && it["session"].asInt() == waiting }
        engine.call("unloadPlugin", "path" to plugin.path)
    }
}
