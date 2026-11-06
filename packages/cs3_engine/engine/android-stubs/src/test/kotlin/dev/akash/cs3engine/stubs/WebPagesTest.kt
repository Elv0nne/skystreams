package dev.akash.cs3engine.stubs

import android.content.Context
import android.net.Uri
import android.webkit.ValueCallback
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WebPagesTest {
    private val context = Context()

    @AfterTest
    fun reset() = WebPages.install(null)

    private class Recording : WebPages.Listener {
        val loads = mutableListOf<Triple<String?, Map<String, String>, String?>>()
        val scripts = mutableListOf<String>()
        val destroyed = mutableListOf<WebView>()

        override fun loading(view: WebView) {
            loads += Triple(view.url, view.cs3Headers(), view.settings.userAgentString)
        }

        override fun evaluate(view: WebView, script: String, callback: ValueCallback<String>?) {
            scripts += script
            callback?.onReceiveValue("\"answered\"")
        }

        override fun destroyed(view: WebView) {
            destroyed += view
        }
    }

    @Test
    fun `a web view hands its loads, scripts and end to the engine's pages, with its headers, agent and interfaces`() {
        val pages = Recording()
        WebPages.install(pages)
        val view = WebView(context)
        view.settings.userAgentString = "SkyStreamTest/1.0"
        val bridge = Any()
        view.addJavascriptInterface(bridge, "Bridge")
        view.loadUrl("https://site.test/login", mapOf("Referer" to "https://site.test/"))
        view.reload()
        var answer: String? = null
        view.evaluateJavascript("document.title") { answer = it }
        view.destroy()
        val load = Triple<String?, Map<String, String>, String?>("https://site.test/login", mapOf("Referer" to "https://site.test/"), "SkyStreamTest/1.0")
        assertEquals(listOf(load, load), pages.loads)
        assertEquals(listOf("document.title"), pages.scripts)
        assertEquals("\"answered\"", answer)
        assertEquals(listOf(view), pages.destroyed)
        assertTrue(view.cs3Destroyed())
        assertEquals<Map<String, Any>>(mapOf("Bridge" to bridge), view.cs3Interfaces())
    }

    @Test
    fun `with no pages, a web view loads nothing and its scripts answer null on the main thread`() {
        val view = WebView(context)
        view.loadUrl("https://site.test/")
        val answer = CompletableFuture<Pair<String, Boolean>>()
        view.evaluateJavascript("1 + 1") { answer.complete(it to MainThread.isMainThread()) }
        assertEquals("null" to true, answer.get(5, TimeUnit.SECONDS))
        assertEquals("https://site.test/", view.url)
    }

    @Test
    fun `a page's progress, title and address read back as Android's do`() {
        val view = WebView(context)
        view.cs3Page("https://site.test/done", 100, "Done")
        assertEquals(Triple("https://site.test/done", 100, "Done"), Triple(view.url, view.progress, view.title))
    }

    @Test
    fun `a client's request forms fall back to the older ones, as Android's do`() {
        val seen = mutableListOf<String>()
        val client = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean {
                seen += "override $url"
                return true
            }

            override fun onReceivedError(view: WebView, errorCode: Int, description: String, failingUrl: String) {
                seen += "error $errorCode $description $failingUrl"
            }
        }
        val view = WebView(context)
        val request = object : WebResourceRequest {
            override fun getUrl(): Uri = Uri.parse("https://site.test/done?code=1")
            override fun isForMainFrame() = true
            override fun isRedirect() = false
            override fun hasGesture() = false
            override fun getMethod() = "GET"
            override fun getRequestHeaders() = emptyMap<String, String>()
        }
        val error = object : WebResourceError() {
            override fun getErrorCode() = -2
            override fun getDescription(): CharSequence = "net::ERR_NAME_NOT_RESOLVED"
        }
        assertTrue(client.shouldOverrideUrlLoading(view, request))
        client.onReceivedError(view, request, error)
        assertEquals(null, client.shouldInterceptRequest(view, request))
        assertEquals(
            listOf("override https://site.test/done?code=1", "error -2 net::ERR_NAME_NOT_RESOLVED https://site.test/done?code=1"),
            seen,
        )
    }
}
