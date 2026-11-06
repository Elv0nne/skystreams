package dev.akash.cs3engine.host

/**
 * What the embedding app provides to the engine. Every platform host sets these
 * at start-up; the defaults only log.
 */
object HostHooks {
    @Volatile
    var log: (String) -> Unit = { System.err.println("[cs3] $it") }

    @Volatile
    var toast: (String) -> Unit = { log("toast: $it") }

    /** Tells the app something it did not ask about, as it happens: a JSON object with an "event" field. */
    @Volatile
    var event: (String) -> Unit = {}

    /**
     * An extension asked to restart the app, and [RestartRequested] reached the host outside an engine
     * call (Android's crash guard catches it on the main thread): [error]'s stack says which extension.
     */
    @Volatile
    var restartRequested: (error: Throwable) -> Unit = {}

    /** An extension's code crashed on the main thread; the crash guard kept the app alive. [error]'s stack says which. */
    @Volatile
    var pluginCrashed: (error: Throwable) -> Unit = {}

    /** Browser that clears Cloudflare challenges, set by hosts that have one; without it, challenges fail. */
    @Volatile
    var webView: WebViewHost? = null

    /**
     * The agent the host's browser sends on its own, as CloudStream's Android resolver read it from the WebView it made
     * (`WebViewResolver.webViewUserAgent`); null where CloudStream never had one (its JVM resolver).
     */
    @Volatile
    var browserAgent: () -> String? = { null }
}

/** What the engine needs from the host's browser. */
interface WebViewHost {
    /**
     * [url]'s clearance, its cookies and the User-Agent they are bound to: solved in the host's
     * browser, or one it held ([WebClearance.earned] says which); null if the challenge could not be
     * solved. [failed]: the clearance the request met the check with, which the host doesn't hand
     * back as fresh.
     */
    fun solveCloudflare(url: String, failed: WebClearance? = null): WebClearance?

    /**
     * Sends [request] from inside a page on its origin, with the page's cookies and network stack,
     * for a site that lets only the browser through, or to learn whether it does (a refusal with
     * none of a check's marks). Null when the host can't, or the site refused the page too.
     */
    fun fetchInPage(request: PageRequest): PageResponse? = null

    /**
     * Loads [url] in a hidden page and hands each request the page makes to [onRequest] until it
     * answers true, or [timeoutMs] passes. With [script], the page runs it after each request and
     * [onScript] gets the result. Returns when the page is done with; a host without a browser
     * returns at once.
     */
    suspend fun resolvePage(
        url: String,
        headers: Map<String, String>,
        script: String?,
        timeoutMs: Long,
        onScript: (String) -> Unit,
        onRequest: (url: String, method: String?) -> Boolean,
    ) {}
}

/**
 * A site's clearance. [browserOnly]: even with it, the site takes requests from its own pages only.
 * [earned]: a solve's, got by the host's browser in that solve, or moments before, rather than held
 * from before; only such a one meeting the check again says the site lets only the browser through.
 */
data class WebClearance(
    val cookies: Map<String, String>,
    val userAgent: String,
    val browserOnly: Boolean = false,
    val earned: Boolean = true,
)

/** A request to send from inside a page. Text bodies only: a page's `fetch` takes text. */
data class PageRequest(val url: String, val method: String, val headers: Map<String, String>, val body: String?)

/** What a page's request got. [url] is where it ended up, after redirects; [body] comes decoded. */
data class PageResponse(val status: Int, val url: String, val headers: Map<String, String>, val body: String)
