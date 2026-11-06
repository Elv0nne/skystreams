package dev.akash.cs3engine.host

import com.lagradost.cloudstream3.network.WebViewResolver
import com.lagradost.cloudstream3.network.WebViewResolverHost
import com.lagradost.nicehttp.requestCreator
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.InetSocketAddress
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PageResolverTest {
    /** A page that makes [requests] in order, once its script has given [scripts], until the resolver is done. */
    private class FakeBrowser(
        private val requests: List<String>,
        private val scripts: List<String> = emptyList(),
    ) : WebViewHost {
        val loaded = mutableListOf<Pair<String, Map<String, String>>>()
        val offered = mutableListOf<String>()

        override fun solveCloudflare(url: String, failed: WebClearance?): WebClearance? = null

        override suspend fun resolvePage(
            url: String,
            headers: Map<String, String>,
            script: String?,
            timeoutMs: Long,
            onScript: (String) -> Unit,
            onRequest: (url: String, method: String?) -> Boolean,
        ) {
            loaded += url to headers
            scripts.forEach(onScript)
            for (request in requests) {
                offered += request
                if (onRequest(request, "GET")) return
            }
        }
    }

    /** Every argument given: a test can't lean on the expect class's defaults. */
    private fun resolver(
        intercept: String,
        vararg additional: String,
        script: String? = null,
        scriptCallback: ((String) -> Unit)? = null,
    ) = WebViewResolver(Regex(intercept), additional.map { Regex(it) }, null, false, script, scriptCallback, 60_000L)

    private fun page(url: String, referer: String? = null): Request = requestCreator("GET", url, referer = referer)

    @BeforeTest
    fun install() {
        WebViewResolverHost.resolver = PageResolver
    }

    @AfterTest
    fun reset() {
        WebViewResolverHost.resolver = null
        HostHooks.webView = null
        HostHooks.browserAgent = { null }
        WebViewResolver.webViewUserAgent = null
    }

    @Test
    fun `a resolve gives WebViewResolver the browser's own agent, as CloudStream's Android resolver does`(): Unit = runBlocking {
        // The browser-requests review: CloudStream's Android resolver set webViewUserAgent from its WebView as it made
        // it; resolving in the app's browser instead left it null, and extensions reading it fell back to their own.
        HostHooks.webView = FakeBrowser(listOf("https://cdn.example/master.m3u8"))
        HostHooks.browserAgent = { "Mozilla/5.0 (Linux; Android 16; wv) Chrome/133.0 Mobile Safari/537.36" }
        resolver("master\\.m3u8").resolveUsingWebView(page("https://host.example/embed/1")) { false }
        assertEquals("Mozilla/5.0 (Linux; Android 16; wv) Chrome/133.0 Mobile Safari/537.36", WebViewResolver.webViewUserAgent)
    }

    @Test
    fun `with no agent from the host, WebViewResolver's stays as CloudStream leaves it`(): Unit = runBlocking {
        // The JVM hosts: CloudStream's JVM resolver never had a WebView, and its agent stays as it was.
        HostHooks.webView = FakeBrowser(listOf("https://cdn.example/master.m3u8"))
        resolver("master\\.m3u8").resolveUsingWebView(page("https://host.example/embed/1")) { false }
        assertNull(WebViewResolver.webViewUserAgent)
        WebViewResolver.webViewUserAgent = "set by an extension"
        resolver("master\\.m3u8").resolveUsingWebView(page("https://host.example/embed/2")) { false }
        assertEquals("set by an extension", WebViewResolver.webViewUserAgent)
    }

    @Test
    fun `the request it waits for ends the page, with the others it asked for`(): Unit = runBlocking {
        val browser = FakeBrowser(
            listOf(
                "https://host.example/player.js",
                "https://cdn.example/sub.vtt",
                "https://cdn.example/master.m3u8",
                "https://cdn.example/late.vtt",
            ),
        )
        HostHooks.webView = browser
        val (found, extra) = resolver("""master\.m3u8""", """\.vtt""")
            .resolveUsingWebView(page("https://host.example/embed/1", referer = "https://site.example/")) { false }
        assertEquals("https://cdn.example/master.m3u8", found?.url.toString())
        assertEquals(listOf("https://cdn.example/sub.vtt"), extra.map { it.url.toString() })
        assertEquals("https://cdn.example/master.m3u8", browser.offered.last())
        val (url, headers) = browser.loaded.single()
        assertEquals("https://host.example/embed/1", url)
        assertEquals("https://site.example/", headers.entries.single { it.key.equals("referer", ignoreCase = true) }.value)
    }

    @Test
    fun `a callback that answers true ends it early`(): Unit = runBlocking {
        HostHooks.webView = FakeBrowser(listOf("https://cdn.example/a.vtt", "https://cdn.example/b.vtt", "https://cdn.example/c.vtt"))
        val (found, extra) = resolver("never", """\.vtt""")
            .resolveUsingWebView(page("https://host.example/")) { it.url.encodedPath == "/b.vtt" }
        assertNull(found)
        assertEquals(listOf("/a.vtt", "/b.vtt"), extra.map { it.url.encodedPath })
    }

    @Test
    fun `the page's script results go to the extension's callback`(): Unit = runBlocking {
        HostHooks.webView = FakeBrowser(emptyList(), scripts = listOf("null", "\"ready\""))
        val results = mutableListOf<String>()
        resolver("x", script = "document.title", scriptCallback = { results += it })
            .resolveUsingWebView(page("https://host.example/")) { false }
        assertEquals(listOf("null", "\"ready\""), results)
    }

    @Test
    fun `addresses OkHttp can't request are passed over`(): Unit = runBlocking {
        HostHooks.webView = FakeBrowser(listOf("blob:https://host.example/1", "data:video/mp4;base64,AAAA", "https://cdn.example/v.mp4"))
        val (found, _) = resolver("""\.mp4|^blob:|^data:""").resolveUsingWebView(page("https://host.example/")) { false }
        assertEquals("https://cdn.example/v.mp4", found?.url.toString())
    }

    @Test
    fun `without a browser it finds nothing, where it used to throw`(): Unit = runBlocking {
        assertEquals(null to emptyList(), resolver("x").resolveUsingWebView(page("https://host.example/")) { false })
        WebViewResolverHost.resolver = null
        assertEquals(null to emptyList(), resolver("x").resolveUsingWebView(page("https://host.example/")) { false })
    }

    @Test
    fun `as an interceptor it sends the request it found instead`() {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            val bytes = "at ${exchange.requestURI.path}".toByteArray()
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        try {
            val base = "http://127.0.0.1:${server.address.port}"
            HostHooks.webView = FakeBrowser(listOf("$base/ad.js", "$base/video/master.m3u8"))
            val client = OkHttpClient.Builder().addInterceptor(resolver("""master\.m3u8""")).build()
            client.newCall(Request.Builder().url("$base/embed/1").build()).execute().use {
                assertEquals("at /video/master.m3u8", it.body.string())
            }
        } finally {
            server.stop(0)
        }
    }
}
