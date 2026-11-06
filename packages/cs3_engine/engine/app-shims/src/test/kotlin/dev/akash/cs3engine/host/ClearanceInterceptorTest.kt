package dev.akash.cs3engine.host

import com.lagradost.cloudstream3.network.CloudflareKiller
import com.sun.net.httpserver.HttpServer
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.net.InetSocketAddress
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ClearanceInterceptorTest {
    private data class Answer(
        val status: Int,
        val body: String,
        val server: String? = "cloudflare",
        val headers: Map<String, String> = emptyMap(),
    )

    private val challenge = Answer(
        403,
        "<html><head><title>Just a moment...</title></head><body><script>window._cf_chl_opt={cRay:'1'}</script></body></html>",
    )
    private val block = Answer(
        403,
        "<html><head><title>Attention Required! | Cloudflare</title></head>" +
            "<body><div id=\"cf-error-details\">Sorry, you have been blocked</div></body></html>",
    )

    private lateinit var server: HttpServer

    /** How the site answers a request carrying [cookie]. */
    private var site: (cookie: String?) -> Answer = { Answer(200, "ok", null) }
    private val browser = FakeBrowser()
    private val shared = OkHttpClient.Builder().addInterceptor(ClearanceInterceptor).build()

    /** Where the server sends a request for a host and path instead, and with which status; null answers it. */
    private var redirect: (host: String, path: String) -> Pair<Int, String>? = { _, _ -> null }
    private val hosts = mutableListOf<String>()

    /** The method of every request the server got, in order. */
    private val methods = mutableListOf<String>()
    private val events = mutableListOf<String>()

    /** Every name is this machine, so `old.test` and `new.test` are two sites on the one server. */
    private val anyHost = OkHttpClient.Builder()
        .dns { listOf(java.net.InetAddress.getByName("127.0.0.1")) }
        .addInterceptor(ClearanceInterceptor)
        .build()

    private fun at(host: String, path: String) = "http://$host:${server.address.port}$path"

    @BeforeTest
    fun start() {
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            val host = exchange.requestHeaders.getFirst("Host") ?: ""
            hosts += host
            methods += exchange.requestMethod
            redirect(host, exchange.requestURI.toString())?.let { (code, location) ->
                exchange.responseHeaders.set("Location", location)
                exchange.sendResponseHeaders(code, -1)
                exchange.close()
                return@createContext
            }
            val answer = site(exchange.requestHeaders.getFirst("Cookie"))
            val bytes = answer.body.toByteArray()
            answer.server?.let { exchange.responseHeaders.set("Server", it) }
            answer.headers.forEach { (name, value) -> exchange.responseHeaders.set(name, value) }
            exchange.responseHeaders.set("Content-Type", "text/html")
            exchange.sendResponseHeaders(answer.status, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        WebClearanceStore.clear()
        HostHooks.webView = browser
        HostHooks.event = { events += it }
    }

    @AfterTest
    fun stop() {
        server.stop(0)
        HostHooks.webView = null
        HostHooks.event = {}
        WebClearanceStore.clear()
    }

    private fun url(path: String) = "http://127.0.0.1:${server.address.port}$path"

    private fun get(path: String, client: OkHttpClient = shared): Response =
        client.newCall(Request.Builder().url(url(path)).build()).execute()

    /** The site takes the cookie the browser's solve brings back. */
    private fun clearanceWorks() {
        site = { cookie -> if (cookie?.contains("cf_clearance=ok") == true) Answer(200, "the page", null) else challenge }
        browser.clearance = WebClearance(mapOf("cf_clearance" to "ok"), "Browser/1.0")
    }

    /** The site refuses even a fresh clearance; its own pages get through. */
    private fun onlyTheBrowserGetsThrough() {
        site = { challenge }
        browser.clearance = WebClearance(mapOf("cf_clearance" to "ok"), "Browser/1.0")
        browser.page = { request -> PageResponse(200, request.url, mapOf("Content-Type" to "text/plain"), "from the page") }
    }

    @Test
    fun `a challenge is cleared in the browser and the request sent again with its cookie`() {
        clearanceWorks()
        get("/a").use {
            assertEquals(200, it.code)
            assertEquals("the page", it.body.string())
        }
        assertEquals(listOf(url("/a")), browser.solves)
        assertEquals(listOf<WebClearance?>(null), browser.failed, "it carried none")
        assertEquals(0, browser.fetches.size)
    }

    @Test
    fun `a challenge marked in its headers is cleared and sent again, its body never read`() {
        // Moflix's API: Cloudflare says so in `cf-mitigated`, and the body stays unread. A second
        // request on the call while that response is open is refused by OkHttp.
        site = { cookie ->
            if (cookie?.contains("cf_clearance=ok") == true) {
                Answer(200, "the results", null)
            } else {
                Answer(403, "<html>${"x".repeat(200_000)}</html>", headers = mapOf("cf-mitigated" to "challenge"))
            }
        }
        browser.clearance = WebClearance(mapOf("cf_clearance" to "ok"), "Browser/1.0")
        get("/api/v1/search/batman").use {
            assertEquals(200, it.code)
            assertEquals("the results", it.body.string())
        }
        assertEquals(1, browser.solves.size)
    }

    /** Kinoger's: the site's own refusal of clients, through Cloudflare, with none of its marks. */
    private val accessDenied = Answer(403, "<html><head><title>Access Denied</title></head><body>Access Denied</body></html>")

    @Test
    fun `CloudflareKiller asks the browser about a Cloudflare refusal it can't read, as CloudStream's does`() {
        site = { cookie -> if (cookie?.contains("session=ok") == true) Answer(200, "the results", null) else accessDenied }
        browser.clearance = WebClearance(mapOf("session" to "ok"), "Browser/1.0")
        val killer = shared.newBuilder().addInterceptor(CloudflareKiller()).build()
        get("/?do=search&story=batman", killer).use { assertEquals("the results", it.body.string()) }
        assertEquals(1, browser.solves.size)
    }

    @Test
    fun `behind CloudflareKiller, a refusal its page meets too is the site's own - it comes back, and the host stays as it was`() {
        // The browser-requests review: a fresh clearance that didn't lift a Cloudflare 403 marked the host browser-only
        // for good, though its page fared no better: a site's own refusal (a title it won't serve) then sent every later
        // request of the host through its page, slower and as text only.
        site = { accessDenied }
        browser.clearance = WebClearance(mapOf("session" to "ok"), "Browser/1.0")
        browser.page = { request -> PageResponse(403, request.url, mapOf("Content-Type" to "text/html"), "the page was refused too") }
        val killer = shared.newBuilder().addInterceptor(CloudflareKiller()).build()
        get("/title/9", killer).use {
            assertEquals(403, it.code)
            // The site's own answer, as it came: not the page's.
            assertEquals("cloudflare", it.header("Server"))
            assertTrue(it.body.string().contains("<title>Access Denied</title>"))
        }
        assertEquals(1, browser.fetches.size, "its page was asked")
        assertFalse(WebClearanceStore.isBrowserOnly("127.0.0.1"))
        assertTrue(events.none { it.contains("siteBrowserOnly") })
    }

    @Test
    fun `behind CloudflareKiller, an origin's own 503 is its answer - no solve, no page, nothing marked`() {
        // The streaming follow-ups' reviews: a 503 with none of a check's marks is the origin's own (overload,
        // maintenance). One that cleared in the seconds a page probe takes marked the site browser-only for good; and
        // each one cost a hidden solve. A 503 that is a check carries its marks.
        site = { Answer(503, "<html><head><title>Service Unavailable</title></head><body>Try again later</body></html>") }
        browser.clearance = WebClearance(mapOf("session" to "ok"), "Browser/1.0")
        browser.page = { request -> PageResponse(200, request.url, mapOf("Content-Type" to "text/html"), "from the page") }
        val killer = shared.newBuilder().addInterceptor(CloudflareKiller()).build()
        get("/title/9", killer).use {
            assertEquals(503, it.code)
            assertTrue(it.body.string().contains("Try again later"))
        }
        assertEquals(0, browser.solves.size, "no solve")
        assertEquals(0, browser.fetches.size, "no page asked")
        assertFalse(WebClearanceStore.isBrowserOnly("127.0.0.1"))
    }

    @Test
    fun `behind CloudflareKiller, a refusal its page gets through lets only the browser through, and the app hears it`() {
        // Kinoger: an "Access Denied" with none of Cloudflare's marks, which its pages get past.
        site = { accessDenied }
        browser.clearance = WebClearance(mapOf("session" to "ok"), "Browser/1.0")
        browser.page = { request -> PageResponse(200, request.url, mapOf("Content-Type" to "text/html"), "the results") }
        val killer = shared.newBuilder().addInterceptor(CloudflareKiller()).build()
        get("/?do=search&story=batman", killer).use { assertEquals("the results", it.body.string()) }
        assertTrue(WebClearanceStore.isBrowserOnly("127.0.0.1"))
        assertTrue(events.any { it.contains("siteBrowserOnly") && it.contains(url("/")) }, events.toString())
        // Known now: the next request goes to the page first.
        get("/?do=search&story=robin", killer).use { assertEquals("the results", it.body.string()) }
        assertEquals(1, browser.solves.size)
    }

    @Test
    fun `the shared interceptor alone leaves a refusal it can't read alone, as the app does`() {
        site = { accessDenied }
        browser.clearance = WebClearance(mapOf("session" to "ok"), "Browser/1.0")
        get("/a").use { assertEquals(403, it.code) }
        assertEquals(0, browser.solves.size)
    }

    @Test
    fun `block pages, and the site's own errors, never ask the browser`() {
        site = { block }
        get("/a").use { assertEquals(403, it.code) }
        site = { Answer(503, "<html><title>Down for maintenance</title></html>") }
        get("/b").use { assertEquals(503, it.code) }
        assertEquals(0, browser.solves.size)
    }

    @Test
    fun `AWS WAF's and Vercel's challenge headers go to the browser, whatever the server`() {
        site = { cookie ->
            if (cookie?.contains("aws-waf-token") == true) {
                Answer(200, "the page", null)
            } else {
                Answer(202, "<html><script>window.gokuProps={}</script></html>", "Server", mapOf("x-amzn-waf-action" to "challenge"))
            }
        }
        browser.clearance = WebClearance(mapOf("aws-waf-token" to "ok"), "Browser/1.0")
        get("/a").use { assertEquals("the page", it.body!!.string()) }
        site = { cookie ->
            if (cookie?.contains("_vcrcs") == true) {
                Answer(200, "the page", null)
            } else {
                Answer(429, "<html><title>Vercel Security Checkpoint</title></html>", "Vercel", mapOf("x-vercel-mitigated" to "challenge"))
            }
        }
        browser.clearance = WebClearance(mapOf("_vcrcs" to "ok"), "Browser/1.0")
        get("/b").use { assertEquals("the page", it.body!!.string()) }
        assertEquals(2, browser.solves.size)
    }

    @Test
    fun `an Anubis or HostAdmin check comes as a 200 page, and goes to the browser`() {
        val anubis = "<!doctype html><html><head><title>Making sure you&#39;re not a bot!</title>" +
            "<link rel=\"stylesheet\" href=\"/.within.website/x/xess/xess.min.css\"></head></html>"
        site = { cookie -> if (cookie != null) Answer(200, "the page", null) else Answer(200, anubis, "nginx") }
        browser.clearance = WebClearance(mapOf("techaro.lol-anubis-auth" to "ok"), "Browser/1.0")
        get("/a").use { assertEquals("the page", it.body!!.string()) }
        val hostAdmin = "<!DOCTYPE html><html><head><title>Verification...</title></head><body>Checking your browser</body></html>"
        site = { cookie ->
            if (cookie?.contains("ha-waf-ticket=ok") == true) {
                Answer(200, "the page", null)
            } else {
                Answer(200, hostAdmin, "cloudflare", mapOf("Set-Cookie" to "ha-waf-ticket=abc; Path=/; HttpOnly"))
            }
        }
        browser.clearance = WebClearance(mapOf("ha-waf-ticket" to "ok"), "Browser/1.0")
        get("/b").use { assertEquals("the page", it.body!!.string()) }
        assertEquals(2, browser.solves.size)
    }

    @Test
    fun `an ordinary 200 page is never a check`() {
        site = { Answer(200, "<html><title>Verification...</title><p>HostAdmin docs</p></html>", "nginx") }
        get("/a").use { assertEquals(200, it.code) }
        assertEquals(0, browser.solves.size)
    }

    @Test
    fun `DDoS-Guard's check goes to the browser too, as in the app`() {
        site = { cookie ->
            if (cookie != null) {
                Answer(200, "the page", null)
            } else {
                Answer(403, "<html><title>DDoS-Guard</title><script src=\"https://check.ddos-guard.net/check.js\"></script></html>", "ddos-guard")
            }
        }
        browser.clearance = WebClearance(mapOf("__ddg1_" to "ok"), "Browser/1.0")
        get("/a").use { assertEquals(200, it.code) }
        assertEquals(1, browser.solves.size)
    }

    @Test
    fun `a site that refuses its fresh clearance gets the request from one of its pages`() {
        onlyTheBrowserGetsThrough()
        browser.page = { request ->
            PageResponse(
                200,
                "${request.url}?from=page",
                mapOf("Content-Type" to "application/json; charset=utf-8", "Content-Encoding" to "gzip", "Content-Length" to "999"),
                """{"from":"page"}""",
            )
        }
        get("/api").use {
            assertEquals(200, it.code)
            assertEquals("""{"from":"page"}""", it.body.string())
            assertEquals("application/json; charset=utf-8", it.header("Content-Type"))
            assertNull(it.header("Content-Encoding"))
            assertNull(it.header("Content-Length"))
            assertEquals("from=page", it.request.url.query)
        }
        assertEquals(listOf(url("/api")), browser.fetches.map { it.url })
        // The app hears it, to keep it for the engine's later runs.
        assertTrue(events.any { it.contains("siteBrowserOnly") && it.contains(url("/api")) }, events.toString())
        // Known now: the next request goes to the page first, with no solve.
        get("/api").use { assertEquals(200, it.code) }
        assertEquals(1, browser.solves.size)
        assertEquals(2, browser.fetches.size)
    }

    @Test
    fun `the clearance a check refused is named when the browser is asked, so the app solves again`() {
        // The streaming follow-ups' review: a clearance that lapsed sooner than the app expected was still fresh to it,
        // came back as it was, met the check again, and marked the site browser-only for good.
        WebClearanceStore.setSites(mapOf("127.0.0.1" to WebClearance(mapOf("cf_clearance" to "lapsed"), "Browser/1.0")))
        clearanceWorks()
        get("/a").use { assertEquals("the page", it.body.string()) }
        assertEquals(listOf<Map<String, String>?>(mapOf("cf_clearance" to "lapsed")), browser.failed.map { it?.cookies })
    }

    @Test
    fun `a refusal names no clearance as refused - it may be the site's own answer`() {
        WebClearanceStore.setSites(mapOf("127.0.0.1" to WebClearance(mapOf("session" to "held"), "Browser/1.0")))
        site = { cookie -> if (cookie?.contains("session=ok") == true) Answer(200, "the results", null) else accessDenied }
        browser.clearance = WebClearance(mapOf("session" to "ok"), "Browser/1.0")
        val killer = shared.newBuilder().addInterceptor(CloudflareKiller()).build()
        get("/?do=search&story=batman", killer).use { assertEquals("the results", it.body.string()) }
        assertEquals(listOf<WebClearance?>(null), browser.failed)
    }

    @Test
    fun `a clearance its host holds but the request never carried isn't named - a redirect brought the request there`() {
        WebClearanceStore.setSites(mapOf("new.test" to WebClearance(mapOf("cf_clearance" to "lapsed"), "Browser/1.0")))
        redirect = { host, path -> if (host.startsWith("old.test")) 302 to at("new.test", path) else null }
        clearanceWorks()
        anyHost.newCall(Request.Builder().url(at("old.test", "/a")).build()).execute().use {
            assertEquals("the page", it.body.string())
        }
        assertEquals(listOf<WebClearance?>(null), browser.failed)
    }

    @Test
    fun `a clearance the app held, not one its browser earned in the solve, proves nothing when the check comes back`() {
        // Fresh by the app's clock, it may have lapsed sooner. Named in a second ask, the app hands back one it holds
        // again (another came meanwhile): still nothing is marked.
        onlyTheBrowserGetsThrough()
        browser.clearance = WebClearance(mapOf("cf_clearance" to "held"), "Browser/1.0", earned = false)
        get("/a").use {
            assertEquals(403, it.code)
            assertTrue(it.body.string().contains("_cf_chl_opt"))
        }
        assertEquals(2, browser.solves.size, "asked again, naming it")
        assertFalse(WebClearanceStore.isBrowserOnly("127.0.0.1"))
        assertTrue(events.none { it.contains("siteBrowserOnly") }, events.toString())
        assertEquals(0, browser.fetches.size)
    }

    @Test
    fun `a host found browser-only while its request waited on the app gets that request from its page`() {
        // Requests sent together: another one's solve found the site lets only the browser through.
        onlyTheBrowserGetsThrough()
        browser.clearance = WebClearance(mapOf("cf_clearance" to "held"), "Browser/1.0", earned = false)
        browser.onSolve = { WebClearanceStore.markBrowserOnly("127.0.0.1") }
        get("/a").use { assertEquals("from the page", it.body.string()) }
        assertEquals(1, browser.fetches.size)
    }

    /** A clearance the app held from before: handed back until it's named as refused, when the browser earns [earned]. */
    private fun heldUntilNamed(earned: WebClearance?): WebClearance {
        val held = WebClearance(mapOf("cf_clearance" to "held"), "Browser/1.0", earned = false)
        browser.answer = { failed -> if (failed?.cookies == held.cookies) earned else held }
        return held
    }

    @Test
    fun `a held clearance that meets the check again is named in a second ask, and the one the browser earns gets through`() {
        // The engine had none for the host, so the first ask named none: the app handed back one it held, which had
        // lapsed. The streaming follow-ups' second review: that request came back failed, and so did the next.
        site = { cookie -> if (cookie?.contains("cf_clearance=new") == true) Answer(200, "the page", null) else challenge }
        val held = heldUntilNamed(WebClearance(mapOf("cf_clearance" to "new"), "Browser/1.0"))
        get("/a").use { assertEquals("the page", it.body.string()) }
        assertEquals(listOf(null, held.cookies), browser.failed.map { it?.cookies })
        assertFalse(WebClearanceStore.isBrowserOnly("127.0.0.1"))
    }

    @Test
    fun `a lapsed clearance on a host a redirect brought the request to is named in the second ask - the request isn't left failing`() {
        // The redirect carried the asked host's cookies: the reached host's own clearance was never on it, so the first
        // ask named none, and every request through the redirect failed until the app's clock let it lapse.
        WebClearanceStore.setSites(mapOf("new.test" to WebClearance(mapOf("cf_clearance" to "held"), "Browser/1.0")))
        redirect = { host, path -> if (host.startsWith("old.test")) 302 to at("new.test", path) else null }
        site = { cookie -> if (cookie?.contains("cf_clearance=new") == true) Answer(200, "the page", null) else challenge }
        val held = heldUntilNamed(WebClearance(mapOf("cf_clearance" to "new"), "Browser/1.0"))
        anyHost.newCall(Request.Builder().url(at("old.test", "/a")).build()).execute().use {
            assertEquals("the page", it.body.string())
        }
        assertEquals(listOf(null, held.cookies), browser.failed.map { it?.cookies })
    }

    @Test
    fun `on a host that lets only the browser through, a check names no clearance - it says nothing of its age`() {
        // A request a page couldn't send goes direct, and meets the check as always: naming its clearance had the app
        // drop it, learn a 5-minute lifetime and solve again, for nothing.
        onlyTheBrowserGetsThrough()
        browser.page = { null }
        WebClearanceStore.setSites(
            mapOf("127.0.0.1" to WebClearance(mapOf("cf_clearance" to "ok"), "Browser/1.0", browserOnly = true)),
        )
        get("/a").use { assertEquals(403, it.code) }
        assertEquals(listOf<WebClearance?>(null), browser.failed)
    }

    @Test
    fun `behind CloudflareKiller, a refusal past a held clearance its page gets through is solved again - nothing marked when that gets through`() {
        // Kinoger's ticket lapsed sooner than the app expected: the site wanted a new one, not only the browser.
        site = { cookie -> if (cookie?.contains("cf_clearance=new") == true) Answer(200, "the results", null) else accessDenied }
        val held = heldUntilNamed(WebClearance(mapOf("cf_clearance" to "new"), "Browser/1.0"))
        browser.page = { request -> PageResponse(200, request.url, mapOf("Content-Type" to "text/html"), "from the page") }
        val killer = shared.newBuilder().addInterceptor(CloudflareKiller()).build()
        get("/?do=search&story=batman", killer).use { assertEquals("the results", it.body.string()) }
        assertEquals(listOf(null, held.cookies), browser.failed.map { it?.cookies })
        assertFalse(WebClearanceStore.isBrowserOnly("127.0.0.1"))
        assertTrue(events.none { it.contains("siteBrowserOnly") }, events.toString())
    }

    @Test
    fun `behind CloudflareKiller, a refusal that the clearance the browser earns meets too, while its page gets through, lets only the browser through`() {
        site = { accessDenied }
        heldUntilNamed(WebClearance(mapOf("cf_clearance" to "new"), "Browser/1.0"))
        browser.page = { request -> PageResponse(200, request.url, mapOf("Content-Type" to "text/html"), "from the page") }
        val killer = shared.newBuilder().addInterceptor(CloudflareKiller()).build()
        get("/?do=search&story=batman", killer).use { assertEquals("from the page", it.body.string()) }
        assertEquals(2, browser.solves.size)
        assertTrue(WebClearanceStore.isBrowserOnly("127.0.0.1"))
    }

    @Test
    fun `behind CloudflareKiller, a refusal past a held clearance its page gets through, with no new one to be had, comes from the page unmarked`() {
        site = { accessDenied }
        heldUntilNamed(null)
        browser.page = { request -> PageResponse(200, request.url, mapOf("Content-Type" to "text/html"), "from the page") }
        val killer = shared.newBuilder().addInterceptor(CloudflareKiller()).build()
        get("/?do=search&story=batman", killer).use { assertEquals("from the page", it.body.string()) }
        assertFalse(WebClearanceStore.isBrowserOnly("127.0.0.1"))
    }

    @Test
    fun `behind CloudflareKiller, a refusal its page gets past on a host found browser-only meanwhile costs no second solve`() {
        // Requests sent together: another one's found the site lets only the browser through while this one waited.
        site = { accessDenied }
        heldUntilNamed(WebClearance(mapOf("cf_clearance" to "new"), "Browser/1.0"))
        browser.onSolve = { WebClearanceStore.markBrowserOnly("127.0.0.1") }
        browser.page = { request -> PageResponse(200, request.url, mapOf("Content-Type" to "text/html"), "from the page") }
        val killer = shared.newBuilder().addInterceptor(CloudflareKiller()).build()
        get("/?do=search&story=batman", killer).use { assertEquals("from the page", it.body.string()) }
        assertEquals(1, browser.solves.size)
    }

    @Test
    fun `behind CloudflareKiller, a refusal its page meets too costs no second solve, even past a held clearance`() {
        site = { accessDenied }
        heldUntilNamed(WebClearance(mapOf("cf_clearance" to "new"), "Browser/1.0"))
        browser.page = { request -> PageResponse(403, request.url, mapOf("Content-Type" to "text/html"), "the page was refused too") }
        val killer = shared.newBuilder().addInterceptor(CloudflareKiller()).build()
        get("/title/9", killer).use { assertEquals(403, it.code) }
        assertEquals(1, browser.solves.size)
        assertFalse(WebClearanceStore.isBrowserOnly("127.0.0.1"))
    }

    @Test
    fun `a site the app says lets only the browser through goes to the page first`() {
        onlyTheBrowserGetsThrough()
        WebClearanceStore.setSites(
            mapOf("127.0.0.1" to WebClearance(mapOf("cf_clearance" to "ok"), "Browser/1.0", browserOnly = true)),
        )
        get("/a").use { assertEquals("from the page", it.body.string()) }
        assertEquals(0, browser.solves.size)
        assertEquals(1, browser.fetches.size)
    }

    @Test
    fun `when the page can't send it either, the challenge comes back, and the page is asked once`() {
        onlyTheBrowserGetsThrough()
        browser.page = { null }
        get("/a").use {
            assertEquals(403, it.code)
            assertTrue(it.body.string().contains("_cf_chl_opt"))
        }
        assertEquals(1, browser.fetches.size)
        // Marked now: the page first, then the usual way, and no second ask for this request.
        get("/a").use { assertEquals(403, it.code) }
        assertEquals(2, browser.fetches.size)
    }

    @Test
    fun `a body that isn't text is never sent from a page`() {
        onlyTheBrowserGetsThrough()
        val upload = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("file", "a.bin", byteArrayOf(1, 2, 3).toRequestBody("application/octet-stream".toMediaType()))
            .build()
        shared.newCall(Request.Builder().url(url("/upload")).post(upload).build()).execute().use {
            assertEquals(403, it.code)
        }
        assertEquals(0, browser.fetches.size)
    }

    @Test
    fun `a form is sent from the page as text`() {
        onlyTheBrowserGetsThrough()
        val form = "q=naruto".toRequestBody("application/x-www-form-urlencoded".toMediaType())
        shared.newCall(Request.Builder().url(url("/search")).post(form).build()).execute().use {
            assertEquals("from the page", it.body.string())
        }
        assertEquals("POST", browser.fetches.single().method)
        assertEquals("q=naruto", browser.fetches.single().body)
    }

    @Test
    fun `CloudflareKiller behind the shared interceptor makes one solve and one page request`() {
        onlyTheBrowserGetsThrough()
        val both = shared.newBuilder().addInterceptor(CloudflareKiller()).build()
        get("/a", both).use { assertEquals("from the page", it.body.string()) }
        assertEquals(1, browser.solves.size)
        assertEquals(1, browser.fetches.size)
    }

    @Test
    fun `CloudflareKiller on its own leaves block pages alone`() {
        site = { block }
        val killer = OkHttpClient.Builder().addInterceptor(CloudflareKiller()).build()
        get("/a", killer).use { assertEquals(403, it.code) }
        assertEquals(0, browser.solves.size)
    }

    private class FakeBrowser : WebViewHost {
        var clearance: WebClearance? = null
        var page: (PageRequest) -> PageResponse? = { null }
        val solves = mutableListOf<String>()

        /** The clearance each solve was told the check refused. */
        val failed = mutableListOf<WebClearance?>()

        /** What happens elsewhere while a solve runs. */
        var onSolve: () -> Unit = {}

        /** The answer to each solve, by the clearance it names as refused; [clearance] when unset. */
        var answer: ((failed: WebClearance?) -> WebClearance?)? = null
        val fetches = mutableListOf<PageRequest>()

        override fun solveCloudflare(url: String, failed: WebClearance?): WebClearance? {
            solves += url
            this.failed += failed
            onSolve()
            val answer = answer
            return if (answer != null) answer(failed) else clearance
        }

        override fun fetchInPage(request: PageRequest): PageResponse? {
            fetches += request
            return page(request)
        }
    }

    @Test
    fun `a site that moved for good is reported, and its check solved where it ended`() {
        clearanceWorks()
        redirect = { host, path -> if (host.startsWith("old.test")) 301 to at("new.test", path) else null }
        anyHost.newCall(Request.Builder().url(at("old.test", "/s?q=1")).build()).execute().use {
            assertEquals(200, it.code)
        }
        assertEquals(listOf(at("new.test", "/s?q=1")), browser.solves)
        val moved = events.single { it.contains("siteMoved") }
        assertTrue(moved.contains(at("old.test", "/s?q=1")))
        assertTrue(moved.contains(at("new.test", "/s?q=1")))
    }

    @Test
    fun `a permanent redirect to an answer that is no check is not reported as a move`() {
        // GitHub's raw host sends a repository's address to github.com, path kept, for good.
        redirect = { host, path -> if (host.startsWith("old.test")) 301 to at("new.test", path) else null }
        anyHost.newCall(Request.Builder().url(at("old.test", "/a")).build()).execute().use {
            assertEquals(200, it.code)
        }
        assertTrue(events.none { it.contains("siteMoved") })
    }

    @Test
    fun `a temporary redirect is not reported as a move`() {
        redirect = { host, path -> if (host.startsWith("old.test")) 302 to at("new.test", path) else null }
        anyHost.newCall(Request.Builder().url(at("old.test", "/a")).build()).execute().close()
        assertTrue(events.none { it.contains("siteMoved") })
    }

    @Test
    fun `a request to a site that moved goes straight to where it went`() {
        WebClearanceStore.setMoves(mapOf("old.test" to "http://new.test:${server.address.port}"))
        anyHost.newCall(Request.Builder().url(at("old.test", "/a")).build()).execute().use {
            assertEquals(200, it.code)
        }
        assertEquals(listOf("new.test:${server.address.port}"), hosts)
    }

    @Test
    fun `a POST a redirect turned into a GET is retried as that GET`() {
        clearanceWorks()
        redirect = { host, path -> if (host.startsWith("old.test")) 302 to at("new.test", path) else null }
        val form = "q=1".toRequestBody("application/x-www-form-urlencoded".toMediaType())
        anyHost.newCall(Request.Builder().url(at("old.test", "/s")).post(form).build()).execute().use {
            assertEquals(200, it.code)
        }
        assertEquals(listOf("POST", "GET", "GET"), methods)
    }

    @Test
    fun `a move is its host's alone`() {
        WebClearanceStore.setMoves(mapOf("old.test" to "http://new.test:${server.address.port}"))
        anyHost.newCall(Request.Builder().url(at("api.old.test", "/a")).build()).execute().close()
        assertEquals(listOf("api.old.test:${server.address.port}"), hosts)
    }

    @Test
    fun `a site that moves again is reported from the address the extension asked for`() {
        clearanceWorks()
        WebClearanceStore.setMoves(mapOf("old.test" to "http://new.test:${server.address.port}"))
        redirect = { host, path -> if (host.startsWith("new.test")) 301 to at("newer.test", path) else null }
        anyHost.newCall(Request.Builder().url(at("old.test", "/a")).build()).execute().close()
        val moved = events.single { it.contains("siteMoved") }
        assertTrue(moved.contains(at("old.test", "/a")))
        assertTrue(moved.contains(at("newer.test", "/a")))
    }

    @Test
    fun `a move whose new domain doesn't answer is dropped, and the old address asked`() {
        val closed = java.net.ServerSocket(0).use { it.localPort }
        WebClearanceStore.setMoves(mapOf("old.test" to "http://new.test:$closed"))
        anyHost.newCall(Request.Builder().url(at("old.test", "/a")).build()).execute().use {
            assertEquals(200, it.code)
        }
        assertEquals(listOf("old.test:${server.address.port}"), hosts)
        assertTrue(events.any { it.contains("siteMoveDropped") && it.contains(at("old.test", "/a")) })
        anyHost.newCall(Request.Builder().url(at("old.test", "/b")).build()).execute().close()
        assertEquals(2, hosts.count { it.startsWith("old.test") })
    }
}
