package dev.akash.challenge_browser

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.CookieManagerCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import kotlin.coroutines.resume
import kotlin.math.roundToInt
import kotlin.random.Random
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * One page: a WebView of its own. It waits in the plugin's hidden host until a [PageView] adopts
 * it, and goes back there when the view goes, so a shown page is never reloaded.
 */
@SuppressLint("SetJavaScriptEnabled")
internal class Page(
    context: Context,
    val id: Long,
    channel: String,
    private val emit: (PageEvent) -> Unit,
) {
    val webView = WebView(context)

    /** Read on the WebView's network thread. */
    @Volatile
    var capturing = false

    /** Main-frame URLs starting with one of these are stopped and reported, not loaded. */
    var navigationStops: List<String> = emptyList()

    /** A focus request that came before the page was shown: forward, backward, or none. */
    private var pendingFocus: Boolean? = null

    /** Document-start scripts, for WebViews too old to inject them natively. */
    private val startScripts = mutableListOf<String>()
    private val main = Handler(Looper.getMainLooper())

    init {
        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        // WebView scales text by the system font size. A hidden page's text stays at 100%, as on every
        // other platform, so a bigger font doesn't move Cloudflare's widget off the solver's tap rows.
        webView.settings.textZoom = 100
        CookieManager.getInstance().setAcceptCookie(true)
        // Cloudflare's check runs in a frame from challenges.cloudflare.com.
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)
        webView.webViewClient = Client()
        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                emit(PageEvent(PageEventKind.PROGRESS, progress = newProgress / 100.0))
            }
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(webView, channel, setOf("*")) { _, message, _, _, _ ->
                emit(PageEvent(PageEventKind.SCRIPT_MESSAGE, message = message.data))
            }
        }
    }

    fun load(url: String, headers: Map<String, String>) = webView.loadUrl(url, headers)

    suspend fun evaluate(script: String): String = suspendCancellableCoroutine { done ->
        webView.evaluateJavascript(script) { result -> done.resume(result ?: "null") }
    }

    fun addDocumentStartScript(script: String) {
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(webView, script, setOf("*"))
        } else {
            startScripts += script
        }
    }

    fun cookies(url: String): List<PageCookie> = readCookies(url).map { it.cookie }

    suspend fun deleteCookies(url: String, name: String?) {
        val manager = CookieManager.getInstance()
        for (stored in readCookies(url)) {
            if (name != null && stored.cookie.name != name) continue
            // A cookie is replaced only by one with the same name, domain and path.
            val domain = if (stored.hostOnly) "" else "; Domain=${stored.cookie.domain}"
            val expired = "${stored.cookie.name}=; Max-Age=0; Path=${stored.cookie.path}$domain"
            suspendCancellableCoroutine { done -> manager.setCookie(url, expired) { done.resume(Unit) } }
        }
        manager.flush()
    }

    var userAgent: String
        get() = webView.settings.userAgentString
        set(value) {
            webView.settings.userAgentString = value
        }

    /** Shows the page in [container], which a platform view owns. */
    fun show(container: PageContainer) {
        (webView.parent as? ViewGroup)?.removeView(webView)
        // Shown, the person reads it at their own font size.
        webView.settings.textZoom = (webView.resources.configuration.fontScale * 100).roundToInt()
        container.addView(webView, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        pendingFocus?.let { forward -> focusOnceLaidOut(forward) }
        pendingFocus = null
    }

    /** Moves the page back to [host] when the platform view that showed it goes. */
    fun hide(container: ViewGroup, host: ViewGroup) {
        if (webView.parent !== container) return
        container.removeView(webView)
        webView.settings.textZoom = 100
        host.addView(webView, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    }

    fun focus(forward: Boolean) {
        val container = webView.parent as? PageContainer
        if (container == null) {
            pendingFocus = forward
            return
        }
        // Focused before it has a size, WebView takes focus without setting up the D-pad's start, and
        // arrow keys then never leave the page: a newly shown page waits for its first layout.
        if (webView.width == 0 || webView.height == 0) return focusOnceLaidOut(forward)
        container.wantsFocus = true
        if (webView.hasFocus()) return
        webView.requestFocus(if (forward) View.FOCUS_DOWN else View.FOCUS_UP)
        // Outside touch mode (a TV remote, a keyboard) WebView focuses the page's first control
        // itself, inside frames too, such as a challenge's checkbox; a script doing it as well would
        // race it. In touch mode, and entering backwards, the page's own document picks the control.
        if (!forward) {
            webView.evaluateJavascript(FOCUS_LAST, null)
        } else if (webView.isInTouchMode) {
            webView.evaluateJavascript(FOCUS_FIRST, null)
        }
    }

    private fun focusOnceLaidOut(forward: Boolean) {
        webView.addOnLayoutChangeListener(object : View.OnLayoutChangeListener {
            override fun onLayoutChange(
                view: View, left: Int, top: Int, right: Int, bottom: Int,
                oldLeft: Int, oldTop: Int, oldRight: Int, oldBottom: Int,
            ) {
                if (right <= left || bottom <= top) return
                view.removeOnLayoutChangeListener(this)
                view.post { focus(forward) }
            }
        })
    }

    fun blur() {
        pendingFocus = null
        (webView.parent as? PageContainer)?.clearFocus()
    }

    /**
     * A finger's tap at [x], [y] CSS pixels from the page's top left: touch input the WebView takes as
     * a person's, sent straight to it, so the page needn't be shown or focused.
     */
    @Suppress("DEPRECATION") // WebView.getScale: density times the page's zoom, as nothing else gives.
    suspend fun tap(x: Double, y: Double) {
        val scale = webView.scale.takeIf { it > 0f } ?: webView.resources.displayMetrics.density
        val px = (x * scale).toFloat()
        val py = (y * scale).toFloat()
        val down = SystemClock.uptimeMillis()
        fun touch(action: Int, at: Long): MotionEvent {
            val pointer = MotionEvent.PointerProperties().apply {
                id = 0
                toolType = MotionEvent.TOOL_TYPE_FINGER
            }
            val coords = MotionEvent.PointerCoords().apply {
                this.x = px
                this.y = py
                pressure = if (action == MotionEvent.ACTION_UP) 0f else 0.55f
                size = 0.04f
                touchMajor = 16f * scale
                touchMinor = 14f * scale
            }
            return MotionEvent.obtain(
                down, at, action, 1, arrayOf(pointer), arrayOf(coords),
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0,
            )
        }
        touch(MotionEvent.ACTION_DOWN, down).also { webView.dispatchTouchEvent(it) }.recycle()
        // A finger rests a moment before it lifts.
        delay(70L + Random.nextLong(61))
        touch(MotionEvent.ACTION_UP, SystemClock.uptimeMillis()).also { webView.dispatchTouchEvent(it) }.recycle()
    }

    fun destroy() {
        webView.stopLoading()
        (webView.parent as? ViewGroup)?.removeView(webView)
        webView.destroy()
    }

    private fun readCookies(url: String): List<StoredCookie> {
        val manager = CookieManager.getInstance()
        val host = android.net.Uri.parse(url).host.orEmpty()
        if (WebViewFeature.isFeatureSupported(WebViewFeature.GET_COOKIE_INFO)) {
            return CookieManagerCompat.getCookieInfo(manager, url).mapNotNull { parseCookie(it, host) }
        }
        // Older WebViews give names and values only.
        return manager.getCookie(url).orEmpty().split("; ").mapNotNull { pair ->
            val eq = pair.indexOf('=')
            if (eq <= 0) return@mapNotNull null
            StoredCookie(
                PageCookie(pair.substring(0, eq), pair.substring(eq + 1), host, "/", null, false, false),
                hostOnly = true,
            )
        }
    }

    /** Whether [url] is one of [navigationStops]: if so, reports it, and the caller stops it. */
    private fun stopped(url: String): Boolean {
        if (navigationStops.none { url.startsWith(it) }) return false
        emit(PageEvent(PageEventKind.NAVIGATION_STOPPED, url = url))
        return true
    }

    private inner class Client : WebViewClient() {
        // Called for the page's own navigations and their redirects, not for load(): a sign-in's
        // redirect is caught here before anything is requested from it.
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
            request.isForMainFrame && stopped(request.url.toString())

        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
            // A navigation shouldOverrideUrlLoading didn't see (some WebViews skip it for the
            // redirect of a POST).
            if (stopped(url)) {
                view.stopLoading()
                return
            }
            for (script in startScripts) view.evaluateJavascript(script, null)
            emit(PageEvent(PageEventKind.PAGE_STARTED, url = url))
        }

        override fun onPageFinished(view: WebView, url: String) {
            emit(PageEvent(PageEventKind.PAGE_FINISHED, url = url))
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            emit(
                PageEvent(
                    PageEventKind.PAGE_ERROR,
                    url = request.url.toString(),
                    code = error.errorCode.toLong(),
                    errorText = error.description.toString(),
                    mainFrame = request.isForMainFrame,
                ),
            )
        }

        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            if (capturing) {
                val url = request.url.toString()
                val method = request.method
                main.post { emit(PageEvent(PageEventKind.CAPTURED, url = url, method = method)) }
            }
            return null // Observe only.
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            // Returning true keeps the app alive; this WebView can't be used again.
            emit(PageEvent(PageEventKind.RENDERER_GONE, crashed = detail.didCrash()))
            destroy()
            return true
        }
    }

    private class StoredCookie(val cookie: PageCookie, val hostOnly: Boolean)

    private companion object {
        /** The document's own controls. Not frames: focusing a frame element reaches none of its controls. */
        const val FOCUSABLE = "a[href],button,input,select,textarea,[tabindex]:not([tabindex=\\\"-1\\\"])"
        const val FOCUS_FIRST = "(function(){var a=document.activeElement;if(a&&a!==document.body)return;" +
            "var e=document.querySelector('$FOCUSABLE');if(e)e.focus();})()"
        const val FOCUS_LAST = "(function(){var e=document.querySelectorAll('$FOCUSABLE');" +
            "if(e.length)e[e.length-1].focus();})()"

        /** Parses one of CookieManagerCompat.getCookieInfo's Set-Cookie lines. */
        fun parseCookie(line: String, host: String): StoredCookie? {
            val parts = line.split(';').map { it.trim() }
            val pair = parts.firstOrNull() ?: return null
            val eq = pair.indexOf('=')
            if (eq <= 0) return null
            var domain: String? = null
            var path = "/"
            var expires: Long? = null
            var httpOnly = false
            var secure = false
            for (attribute in parts.drop(1)) {
                val key = attribute.substringBefore('=').trim().lowercase()
                val value = attribute.substringAfter('=', "").trim()
                when (key) {
                    "domain" -> domain = value
                    "path" -> path = value.ifEmpty { "/" }
                    "expires" -> expires = parseDate(value)
                    "max-age" -> value.toLongOrNull()?.let { expires = System.currentTimeMillis() + it * 1000 }
                    "httponly" -> httpOnly = true
                    "secure" -> secure = true
                }
            }
            return StoredCookie(
                PageCookie(pair.substring(0, eq), pair.substring(eq + 1), domain ?: host, path, expires, httpOnly, secure),
                hostOnly = domain == null,
            )
        }

        fun parseDate(value: String): Long? = try {
            java.text.SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", java.util.Locale.US).parse(value)?.time
        } catch (_: java.text.ParseException) {
            null
        }
    }
}
