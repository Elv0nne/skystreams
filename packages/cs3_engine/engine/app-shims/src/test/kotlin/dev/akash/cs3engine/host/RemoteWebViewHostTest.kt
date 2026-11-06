package dev.akash.cs3engine.host

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.util.concurrent.CompletableFuture
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RemoteWebViewHostTest {
    private val mapper = ObjectMapper()
    private val sent = LinkedBlockingQueue<JsonNode>()

    @BeforeTest
    fun listen() {
        HostHooks.event = { sent.put(mapper.readTree(it)) }
        RemoteWebViewHost.answerTimeoutMs = 2_000
    }

    @AfterTest
    fun reset() {
        HostHooks.event = {}
        RemoteWebViewHost.answerTimeoutMs = 90_000
    }

    /** The next `webRequest` the engine sent. */
    private fun next(): JsonNode = sent.poll(2, TimeUnit.SECONDS) ?: error("no webRequest was sent")

    private fun json(text: String): JsonNode = mapper.readTree(text)

    @Test
    fun `a solve goes out as one and comes back as the site's clearance`() {
        val solving = CompletableFuture.supplyAsync { RemoteWebViewHost.solveCloudflare("https://example.com/a") }
        val event = next()
        assertEquals("webRequest", event.path("event").asText())
        assertEquals("solve", event.path("op").asText())
        assertEquals("https://example.com/a", event.path("url").asText())
        assertFalse(event.has("failed"), "no clearance was refused")
        RemoteWebViewHost.reply(
            event.path("rid").asLong(),
            json("""{"cookies":{"cf_clearance":"ok"},"userAgent":"Browser/1.0"}"""),
        )
        // Earned unless the app says otherwise.
        assertEquals(WebClearance(mapOf("cf_clearance" to "ok"), "Browser/1.0"), solving.get(2, TimeUnit.SECONDS))
    }

    @Test
    fun `a solve names the clearance a check refused, and hears whether the browser earned the one that comes back`() {
        val solving = CompletableFuture.supplyAsync {
            RemoteWebViewHost.solveCloudflare(
                "https://example.com/a",
                WebClearance(mapOf("cf_clearance" to "lapsed"), "Browser/1.0"),
            )
        }
        val event = next()
        assertEquals("lapsed", event.path("failed").path("cf_clearance").asText())
        RemoteWebViewHost.reply(
            event.path("rid").asLong(),
            json("""{"cookies":{"cf_clearance":"held"},"userAgent":"Browser/1.0","earned":false}"""),
        )
        assertEquals(
            WebClearance(mapOf("cf_clearance" to "held"), "Browser/1.0", earned = false),
            solving.get(2, TimeUnit.SECONDS),
        )
    }

    @Test
    fun `a request from inside a page goes out as a fetch and comes back as the page's response`() {
        val fetching = CompletableFuture.supplyAsync {
            RemoteWebViewHost.fetchInPage(
                PageRequest("https://example.com/api", "POST", mapOf("Accept" to "application/json"), "q=1"),
            )
        }
        val event = next()
        assertEquals("fetch", event.path("op").asText())
        assertEquals("https://example.com/api", event.path("url").asText())
        assertEquals("POST", event.path("method").asText())
        assertEquals("application/json", event.path("headers").path("Accept").asText())
        assertEquals("q=1", event.path("body").asText())
        RemoteWebViewHost.reply(
            event.path("rid").asLong(),
            json("""{"status":200,"url":"https://example.com/api/","headers":{"content-type":"application/json"},"body":"[]"}"""),
        )
        assertEquals(
            PageResponse(200, "https://example.com/api/", mapOf("content-type" to "application/json"), "[]"),
            fetching.get(2, TimeUnit.SECONDS),
        )
    }

    @Test
    fun `a fetch the app couldn't send, or never answered, is null`() {
        val refused = CompletableFuture.supplyAsync {
            RemoteWebViewHost.fetchInPage(PageRequest("https://example.com/", "GET", emptyMap(), null))
        }
        RemoteWebViewHost.reply(next().path("rid").asLong(), json("{}"))
        assertNull(refused.get(2, TimeUnit.SECONDS))
        RemoteWebViewHost.answerTimeoutMs = 200
        assertNull(RemoteWebViewHost.fetchInPage(PageRequest("https://example.com/", "GET", emptyMap(), null)))
        next()
    }

    @Test
    fun `a resolve hands the page's requests over until one is the answer`(): Unit = runBlocking {
        val seen = mutableListOf<String>()
        val resolving = async(Dispatchers.Default) {
            RemoteWebViewHost.resolvePage(
                "https://host.example/embed/1",
                mapOf("Referer" to "https://site.example/"),
                "document.title",
                5_000,
                onScript = { synchronized(seen) { seen += "script $it" } },
            ) { url, _ ->
                synchronized(seen) { seen += url }
                url.endsWith(".m3u8")
            }
        }
        val event = next()
        assertEquals("resolve", event.path("op").asText())
        assertEquals("https://host.example/embed/1", event.path("url").asText())
        assertEquals("https://site.example/", event.path("headers").path("Referer").asText())
        assertEquals("document.title", event.path("script").asText())
        assertEquals(5_000L, event.path("timeoutMs").asLong())
        val rid = event.path("rid").asLong()
        assertFalse(RemoteWebViewHost.captured(rid, "https://host.example/player.js", "GET"))
        RemoteWebViewHost.scriptResult(rid, "\"Player\"")
        assertTrue(RemoteWebViewHost.captured(rid, "https://cdn.example/master.m3u8", "GET"))
        withTimeout(2_000) { resolving.await() }
        assertEquals(
            listOf("https://host.example/player.js", "script \"Player\"", "https://cdn.example/master.m3u8"),
            seen,
        )
        // Over: a request reported late tells the app to close the page.
        assertTrue(RemoteWebViewHost.captured(rid, "https://cdn.example/seg-1.ts", "GET"))
    }

    @Test
    fun `the app ending a resolve ends it`(): Unit = runBlocking {
        val resolving = async(Dispatchers.Default) {
            RemoteWebViewHost.resolvePage("https://a.example/", emptyMap(), null, 5_000, {}) { _, _ -> false }
        }
        RemoteWebViewHost.reply(next().path("rid").asLong(), json("{}"))
        withTimeout(2_000) { resolving.await() }
    }

    @Test
    fun `a resolve that finds nothing ends at its timeout, and its wait isn't the call's running time`(): Unit =
        runBlocking {
            val before = BrokerClock.shared.running()
            val started = System.nanoTime()
            RemoteWebViewHost.resolvePage("https://b.example/", emptyMap(), null, 300, {}) { _, _ -> false }
            val took = (System.nanoTime() - started) / 1_000_000
            assertTrue(took in 250..2_000, "took $took ms")
            assertTrue(BrokerClock.shared.running() - before < 150)
            next()
        }

    @Test
    fun `an extension that fails on a request doesn't end the resolve`(): Unit = runBlocking {
        val resolving = async(Dispatchers.Default) {
            RemoteWebViewHost.resolvePage("https://c.example/", emptyMap(), null, 5_000, {}) { url, _ ->
                if (url.endsWith("bad")) error("the extension's own bug")
                url.endsWith("good")
            }
        }
        val rid = next().path("rid").asLong()
        assertFalse(RemoteWebViewHost.captured(rid, "https://c.example/bad", null))
        assertTrue(RemoteWebViewHost.captured(rid, "https://c.example/good", null))
        withTimeout(2_000) { resolving.await() }
    }

    @Test
    fun `a page opens, loads again and goes through webRequest, with nothing waiting`() {
        val rid = RemoteWebViewHost.openPage(3, 7, "https://site.test/login", mapOf("Referer" to "x"), "Agent/1", mapOf("Bridge" to listOf("signedIn")))
        val opened = next()
        assertEquals("page", opened.path("op").asText())
        assertEquals(rid, opened.path("rid").asLong())
        assertEquals(3, opened.path("session").asInt())
        assertEquals(7, opened.path("node").asInt())
        assertEquals("Agent/1", opened.path("userAgent").asText())
        assertEquals("signedIn", opened.path("interfaces").path("Bridge").path(0).asText())
        RemoteWebViewHost.navigatePage(rid, "https://site.test/next", emptyMap())
        assertEquals("navigate" to rid, next().let { it.path("op").asText() to it.path("rid").asLong() })
        RemoteWebViewHost.closePage(rid)
        assertEquals("closePage" to rid, next().let { it.path("op").asText() to it.path("rid").asLong() })
    }

    @Test
    fun `an eval's answer reaches its callback, and page events reach the pages`() {
        var result: String? = null
        RemoteWebViewHost.evalPage(5, "document.title") { result = it }
        val asked = next()
        assertEquals("eval" to 5L, asked.path("op").asText() to asked.path("page").asLong())
        RemoteWebViewHost.reply(asked.path("rid").asLong(), json("""{"result": "\"Title\""}"""))
        assertEquals("\"Title\"", result)
        val seen = mutableListOf<Pair<Long, String>>()
        RemoteWebViewHost.pageEvents = object : RemoteWebViewHost.PageEvents {
            override fun event(rid: Long, event: JsonNode) {
                seen += rid to event.path("type").asText()
            }

            override suspend fun answer(rid: Long, event: JsonNode): Map<String, Any?> = emptyMap()
        }
        try {
            runBlocking { RemoteWebViewHost.pageEvent(9, json("""{"rid": 9, "type": "finished"}""")) }
        } finally {
            RemoteWebViewHost.pageEvents = null
        }
        assertEquals(listOf(9L to "finished"), seen)
    }

    @Test
    fun `a page in a full-screen window says so as it opens, and no other does`() {
        // Phase 7c's §2.
        RemoteWebViewHost.openPage(3, 7, "https://game.test/", emptyMap(), null, emptyMap(), fullScreen = true)
        assertEquals(true, next().path("fullScreen").asBoolean())
        RemoteWebViewHost.openPage(3, 8, "https://site.test/", emptyMap(), null, emptyMap())
        assertTrue(next().path("fullScreen").isMissingNode)
    }

    @Test
    fun `a page of the extension's own files says what the app serves, as it opens and as it loads again`() {
        // Phase 7c's §6.
        val serve = mapOf("name" to "a1", "folder" to "/data/files/game", "path" to "index.html", "file" to "file:///data/files/game/")
        val rid = RemoteWebViewHost.openPage(3, 7, "file:///data/files/game/index.html", emptyMap(), null, emptyMap(), serve = serve)
        assertEquals("a1", next().path("serve").path("name").asText())
        RemoteWebViewHost.navigatePage(rid, "file:///data/files/game/index.html", emptyMap(), serve)
        assertEquals("/data/files/game", next().path("serve").path("folder").asText())
        RemoteWebViewHost.openPage(3, 8, "https://site.test/", emptyMap(), null, emptyMap())
        assertTrue(next().path("serve").isMissingNode)
    }

    @Test
    fun `a page's call waits for its answer, which the app's webPage request gets back - with no pages, undefined or cancel`() = runBlocking {
        // Phase 7c's §7 and §8.
        val asked = mutableListOf<String>()
        RemoteWebViewHost.pageEvents = object : RemoteWebViewHost.PageEvents {
            override fun event(rid: Long, event: JsonNode) {
                asked += "event ${event.path("type").asText()}"
            }

            override suspend fun answer(rid: Long, event: JsonNode): Map<String, Any?> {
                asked += "answer ${event.path("type").asText()}"
                return mapOf("value" to 3)
            }
        }
        try {
            assertEquals(mapOf("value" to 3), RemoteWebViewHost.pageEvent(9, json("""{"type": "call"}""")))
            assertEquals(true, RemoteWebViewHost.pageEvent(9, json("""{"type": "finished"}""")))
            assertEquals(listOf("answer call", "event finished"), asked)
        } finally {
            RemoteWebViewHost.pageEvents = null
        }
        assertEquals(emptyMap<String, Any?>(), RemoteWebViewHost.pageEvent(9, json("""{"type": "call"}""")))
        assertEquals(mapOf("accept" to false), RemoteWebViewHost.pageEvent(9, json("""{"type": "dialog"}""")))
    }

    @Test
    fun `a page whose interfaces answer says which methods do, as it opens`() {
        RemoteWebViewHost.openPage(3, 7, "https://game.test/", emptyMap(), null, mapOf("Game" to listOf("saveState")), answering = mapOf("Game" to listOf("loadState")))
        assertEquals("loadState", next().path("answering").path("Game").path(0).asText())
        RemoteWebViewHost.openPage(3, 8, "https://site.test/", emptyMap(), null, emptyMap())
        assertTrue(next().path("answering").isMissingNode)
    }
}
