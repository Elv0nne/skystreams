package dev.akash.cs3engine.jvm

import android.net.Uri
import android.webkit.JavascriptInterface
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.ValueCallback
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.host.RemoteWebViewHost
import dev.akash.cs3engine.stubs.MainThread
import dev.akash.cs3engine.stubs.StubEnv
import dev.akash.cs3engine.stubs.WebCookies
import dev.akash.cs3engine.stubs.WebPages
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import java.util.IdentityHashMap
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * The web view stand-in's pages (the spec's §9): a web view in an open screen's window gets a page in the app's
 * browser, shown in the sheet at its node; the page's events reach the extension's clients (on the main thread), its
 * JavaScript interfaces and its requests' handler (off it, as Android calls them), and the CookieManager stand-in. A
 * web view no screen holds loads nothing (Phase 3b stays dropped). [locate] says where a web view is on screen: its
 * screen's session and its node. Main thread, but for [event].
 */
class JvmPages(
    private val locate: (WebView) -> Pair<Int, Int>?,
    /** Whether a web view's window asks for the whole screen: its page then says so as it opens (Phase 7c's §2). */
    private val fullScreen: (WebView) -> Boolean = { false },
    /** A web view's extension (its plugin's file), which its served folders are named for (Phase 7c's §6). */
    private val extensionOf: (WebView) -> File? = { null },
    private val bridge: PageBridge = RemoteBridge,
) : WebPages.Listener, RemoteWebViewHost.PageEvents {
    /** What the pages ask of the app: [RemoteBridge], or a test's own. */
    interface PageBridge {
        fun open(
            session: Int,
            node: Int,
            url: String,
            headers: Map<String, String>,
            userAgent: String?,
            interfaces: Map<String, List<String>>,
            fullScreen: Boolean,
            serve: Map<String, String>?,
            answering: Map<String, List<String>>,
        ): Long

        fun navigate(page: Long, url: String, headers: Map<String, String>, serve: Map<String, String>?)

        fun close(page: Long)

        fun eval(page: Long, script: String, onResult: (String) -> Unit)
    }

    /** The app, over the engine protocol. */
    object RemoteBridge : PageBridge {
        override fun open(
            session: Int,
            node: Int,
            url: String,
            headers: Map<String, String>,
            userAgent: String?,
            interfaces: Map<String, List<String>>,
            fullScreen: Boolean,
            serve: Map<String, String>?,
            answering: Map<String, List<String>>,
        ) = RemoteWebViewHost.openPage(session, node, url, headers, userAgent, interfaces, fullScreen, serve, answering)

        override fun navigate(page: Long, url: String, headers: Map<String, String>, serve: Map<String, String>?) =
            RemoteWebViewHost.navigatePage(page, url, headers, serve)

        override fun close(page: Long) = RemoteWebViewHost.closePage(page)

        override fun eval(page: Long, script: String, onResult: (String) -> Unit) = RemoteWebViewHost.evalPage(page, script, onResult)
    }

    private class Page(val view: WebView, val rid: Long, var own: String) {
        var starts = 0

        /** The address its last start reported: a page finishing elsewhere was a navigation reported late. */
        var started: String? = null

        /** The extension loaded [own] itself: its next start is that load's, which Android never offers to shouldOverrideUrlLoading. */
        var ownNext = false

        /** How many loads the extension has made: one made while shouldOverrideUrlLoading runs is its own way of taking over. */
        var loads = 0

        /** Its page dialogs waiting on the extension's chrome client: cancelled if it goes first. */
        val dialogs: MutableSet<CompletableDeferred<Map<String, Any?>>> = ConcurrentHashMap.newKeySet()
    }

    private val mapper = ObjectMapper()

    // The main thread's.
    private val pages = IdentityHashMap<WebView, Page>()
    private val byRid = ConcurrentHashMap<Long, Page>()

    /** Web views whose page the app closed (it couldn't open one, or its renderer went): opened again only by a load. */
    private val closedByApp: MutableSet<WebView> = java.util.Collections.newSetFromMap(IdentityHashMap())

    /** Interface calls and requests, in order, off the main thread. */
    private val calls = Executors.newSingleThreadExecutor { Thread(it, "cs3-page-calls").apply { isDaemon = true } }

    /** Pages whose web view went, for [LATE_CALLS_MS]: a one-way call the page posted just before still reaches it. */
    private val ended = ConcurrentHashMap<Long, Page>()

    /** How long an answering call may take before its page gets undefined (Phase 7c's §7). */
    internal var answerTimeoutMs = ANSWER_TIMEOUT_MS

    override fun loading(view: WebView) {
        val url = view.url ?: return
        closedByApp.remove(view)
        val page = pages[view]
        if (page == null) {
            start(view)
            return
        }
        page.own = url
        page.ownNext = true
        page.loads++
        bridge.navigate(page.rid, url, view.cs3Headers(), serveFor(view, url))
    }

    override fun evaluate(view: WebView, script: String, callback: ValueCallback<String>?) {
        val page = pages[view]
        if (page == null) {
            if (callback != null) MainThread.post { callback.onReceiveValue("null") }
            return
        }
        bridge.eval(page.rid, script) { result -> if (callback != null) MainThread.post { callback.onReceiveValue(result) } }
    }

    override fun destroyed(view: WebView) {
        pages[view]?.let(::end)
    }

    /** [views] are the web views in open screens' windows now: those with a URL get their page, and those gone lose theirs. */
    fun shown(views: Collection<WebView>) {
        val now = views.toCollection(java.util.Collections.newSetFromMap(IdentityHashMap()))
        for (page in pages.values.toList()) if (page.view !in now || page.view.cs3Destroyed()) end(page)
        closedByApp.retainAll(now)
        for (view in views) if (view !in pages && view !in closedByApp && view.url != null && !view.cs3Destroyed()) start(view)
    }

    private fun start(view: WebView) {
        val (session, node) = locate(view) ?: return
        val methods = view.cs3Interfaces().mapValues { (_, target) -> callable(target) }
        // A name any of whose methods returns a value answers the page (Phase 7c's §7); the rest are one way.
        val answering = methods.mapValues { (_, list) -> list.filter { it.returnType != Void.TYPE }.map { it.name }.distinct() }
            .filterValues { it.isNotEmpty() }
        val interfaces = methods.mapValues { (name, list) -> list.map { it.name }.distinct() - answering[name].orEmpty().toSet() }
        val url = view.url!!
        val rid = bridge.open(
            session, node, url, view.cs3Headers(), view.settings.userAgentString, interfaces, fullScreen(view), serveFor(view, url), answering,
        )
        Page(view, rid, url).also {
            pages[view] = it
            byRid[rid] = it
        }
    }

    private fun end(page: Page) {
        pages.remove(page.view)
        byRid.remove(page.rid)
        page.dialogs.forEach { it.complete(CANCEL) }
        ended[page.rid] = page
        MainThread.postDelayed({ ended.remove(page.rid) }, LATE_CALLS_MS)
        bridge.close(page.rid)
    }

    override fun event(rid: Long, event: JsonNode) {
        val type = event.path("type").asText()
        // A one-way call reaches its extension even just after its page went: a game's last save (Phase 7c).
        if (type == "message") {
            val page = byRid[rid] ?: ended[rid] ?: return
            calls.execute { invoke(page, event.path("message").asText("")) }
            return
        }
        val page = byRid[rid] ?: return
        when (type) {
            "request" -> calls.execute { request(page, event) }
            else -> MainThread.post { onMain(page, event) }
        }
    }

    override suspend fun answer(rid: Long, event: JsonNode): Map<String, Any?> {
        val page = byRid[rid]
        return when (event.path("type").asText()) {
            "call" -> if (page == null) UNDEFINED else call(page, event.path("message").asText(""))
            "dialog" -> if (page == null) CANCEL else dialog(page, event)
            else -> UNDEFINED
        }
    }

    /**
     * An answering call (Phase 7c's §7): run on the page's call thread after every call posted before it, its answer
     * what Android's bridge gives the page; undefined, logged, after [answerTimeoutMs].
     */
    private suspend fun call(page: Page, raw: String): Map<String, Any?> {
        val answer = CompletableDeferred<Map<String, Any?>>()
        calls.execute { answer.complete(invoke(page, raw)) }
        return withTimeoutOrNull(answerTimeoutMs) { answer.await() } ?: UNDEFINED.also {
            HostHooks.log("A page's JavaScript call didn't answer in ${answerTimeoutMs / 1000} s: the page gets undefined")
        }
    }

    /**
     * The page's own alert, confirm or prompt (Phase 7c's §8), for its web view's chrome client, asked on the main
     * thread as Android asks it. The answer:
     * - the client's (`accept`, and a prompt's `text`), however late it comes;
     * - `show` when the client leaves the dialog to the app;
     * - cancel with no client, or when the page goes first.
     */
    private suspend fun dialog(page: Page, event: JsonNode): Map<String, Any?> {
        val answer = CompletableDeferred<Map<String, Any?>>()
        page.dialogs += answer
        MainThread.post {
            val chrome = page.view.webChromeClient
            if (pages[page.view] !== page || chrome == null) {
                answer.complete(CANCEL)
                return@post
            }
            val url = event.path("url").asText("").ifEmpty { page.view.url.orEmpty() }
            val message = event.path("message").asText("")
            val receiver = JsResult.ResultReceiver { result ->
                answer.complete(mapOf("accept" to result.result, "text" to (result as? JsPromptResult)?.stringResult))
            }
            val taken = try {
                when (event.path("kind").asText()) {
                    "alert" -> chrome.onJsAlert(page.view, url, message, JsResult(receiver))
                    "confirm" -> chrome.onJsConfirm(page.view, url, message, JsResult(receiver))
                    "prompt" -> chrome.onJsPrompt(page.view, url, message, event.path("defaultText").asText(null), JsPromptResult(receiver))
                    else -> false
                }
            } catch (e: Exception) {
                HostHooks.log("The page's ${event.path("kind").asText()} failed in its chrome client: $e")
                false
            }
            if (!taken) answer.complete(SHOW)
        }
        return try {
            answer.await()
        } finally {
            page.dialogs -= answer
        }
    }

    /**
     * What the app serves for [view]'s [url] (Phase 7c's §6), or null. When [url] is a file inside the engine's data
     * folders (the stand-in context's files and cache), and the web view's settings allow file access, the app serves
     * its folder under an address of its own:
     * - `name`: the folder's, the same every run ([servedName]);
     * - `folder`: what the app serves;
     * - `path`: the address below it;
     * - `file`: the folder's own file address, which the app reports the page's addresses back under, as Android gives
     *   a file page's.
     */
    private fun serveFor(view: WebView, url: String): Map<String, String>? {
        if (!view.settings.allowFileAccess) return null
        val (file, rest) = fileOf(url) ?: return null
        val folder = file.absoluteFile.parentFile ?: return null
        val real = runCatching { folder.canonicalFile }.getOrNull() ?: return null
        if (listOf("files", "cache").none { real.startsWith(StubEnv.dir(it).canonicalFile) }) return null
        val relative = real.relativeTo(StubEnv.root().canonicalFile).invariantSeparatorsPath
        return mapOf(
            "name" to servedName(extensionOf(view)?.nameWithoutExtension.orEmpty(), relative),
            "folder" to folder.path,
            "path" to URI(null, null, file.name, null).toASCIIString() + rest,
            "file" to "file://" + folder.toURI().toASCIIString().removePrefix("file:").let { if (it.endsWith("/")) it else "$it/" },
        )
    }

    private fun onMain(page: Page, event: JsonNode) {
        val view = page.view
        if (pages[view] !== page) return
        val url = event.path("url").asText("").ifEmpty { view.url.orEmpty() }
        for (cookie in event.path("cookies")) {
            WebCookies.setFor(cookie.path("domain").asText("").ifEmpty { Uri.parse(url).host.orEmpty() }, cookie.path("name").asText(), cookie.path("value").asText())
        }
        val client = view.webViewClient
        val chrome = view.webChromeClient
        when (event.path("type").asText()) {
            "started" -> {
                page.started = url
                val first = page.starts++ == 0
                val own = page.ownNext.also { page.ownNext = false }
                // shouldOverrideUrlLoading after the fact: a navigation the extension takes over stops there.
                if (!first && !own && takenOver(page, url)) return
                view.cs3Page(url, 10, null)
                byName(client, "onPageStarted", view, url, null)
                chrome?.onProgressChanged(view, 10)
            }
            "finished" -> {
                // Finished somewhere its start didn't say (WebKitGTK starts a script's navigation under the old
                // address; a server redirect): that navigation is offered now, after the fact, as Android offers one.
                if (page.started != null && url != page.started) {
                    page.started = url
                    if (url != page.own && takenOver(page, url)) return
                }
                val title = event.path("title").asText(null)
                view.cs3Page(url, 100, title)
                chrome?.onProgressChanged(view, 100)
                if (title != null) chrome?.onReceivedTitle(view, title)
                client.onPageFinished(view, url)
            }
            "failed" -> client.onReceivedError(
                view,
                Request(url, "GET", emptyMap(), event.path("mainFrame").asBoolean(true)),
                Failure(event.path("code").asInt(-1), event.path("text").asText("")),
            )
            "closed" -> {
                // The app couldn't keep it: no new page until the extension loads again (else every read retries).
                pages.remove(view)
                byRid.remove(page.rid)
                page.dialogs.forEach { it.complete(CANCEL) }
                closedByApp += view
            }
        }
    }

    /**
     * Offers [url], a navigation of [page]'s that already started, to its client's shouldOverrideUrlLoading: true
     * stops it there, unless the client took it over by loading elsewhere itself (a stop would cancel that load).
     */
    private fun takenOver(page: Page, url: String): Boolean {
        val loads = page.loads
        if (!page.view.webViewClient.shouldOverrideUrlLoading(page.view, Request(url, "GET", emptyMap(), mainFrame = true))) return false
        if (page.loads == loads) bridge.eval(page.rid, "window.stop()") {}
        return true
    }

    /**
     * A page's script called a JavaScript interface: `{"cs3-js": 1, name, method, args}`. Answers what Android's bridge
     * gives the page; a one-way call's answer is dropped.
     */
    private fun invoke(page: Page, raw: String): Map<String, Any?> {
        val call = runCatching { mapper.readTree(raw) }.getOrNull() ?: return UNDEFINED
        val target = page.view.cs3Interfaces()[call.path("name").asText()] ?: return UNDEFINED
        val args = call.path("args").toList()
        val method = callable(target).firstOrNull { it.name == call.path("method").asText() && it.parameterCount == args.size }
            ?: return mapOf("error" to "Method not found")
        val result = try {
            method.invoke(target, *method.parameterTypes.mapIndexed { i, type -> value(args[i], type) }.toTypedArray())
        } catch (e: InvocationTargetException) {
            HostHooks.log("${method.name} of a page's JavaScript interface failed: ${e.cause}")
            return mapOf("error" to JAVA_EXCEPTION)
        } catch (e: Exception) {
            HostHooks.log("${method.name} of a page's JavaScript interface couldn't be called: $e")
            return UNDEFINED
        }
        return answerOf(method, result)
    }

    /**
     * What Android's bridge gives a page for [result], [method]'s return (Phase 7c's §7):
     * - a string, a boolean, a number;
     * - undefined for a null String, as Chromium's bridge gives one;
     * - null for any other null;
     * - undefined, logged, for a number JSON can't hold, or another kind of object.
     */
    private fun answerOf(method: Method, result: Any?): Map<String, Any?> = when {
        method.returnType == Void.TYPE -> UNDEFINED
        result == null -> if (method.returnType == String::class.java) UNDEFINED else mapOf("value" to null)
        result is String || result is Boolean -> mapOf("value" to result)
        result is Char -> mapOf("value" to result.code)
        result is Number && result.toDouble().isFinite() -> mapOf("value" to result)
        else -> UNDEFINED.also {
            HostHooks.log("${method.name} of a page's JavaScript interface returned what a page can't take (${result.javaClass.name}): undefined")
        }
    }

    /** A request the page made: its handler hears it; what it returns can't replace the response. */
    private fun request(page: Page, event: JsonNode) {
        val headers = event.path("headers").fields().asSequence().associate { it.key to it.value.asText() }
        val request = Request(event.path("url").asText(), event.path("method").asText("GET"), headers, event.path("mainFrame").asBoolean(false))
        try {
            page.view.webViewClient.shouldInterceptRequest(page.view, request)
        } catch (e: Exception) {
            HostHooks.log("shouldInterceptRequest failed for ${request.url}: $e")
        }
    }

    /** The methods a page's script may call: those marked @JavascriptInterface, as Android asks, else (a mark lost in conversion) every public one. */
    private fun callable(target: Any): List<Method> {
        val public = target.javaClass.methods.filter { it.declaringClass != Any::class.java }
        return public.filter { it.isAnnotationPresent(JavascriptInterface::class.java) }.ifEmpty { public }
    }

    private fun value(node: JsonNode, type: Class<*>): Any? = when (type) {
        String::class.java -> if (node.isNull) null else node.asText()
        Int::class.javaPrimitiveType, Int::class.javaObjectType -> node.asInt()
        Long::class.javaPrimitiveType, Long::class.javaObjectType -> node.asLong()
        Boolean::class.javaPrimitiveType, Boolean::class.javaObjectType -> node.asBoolean()
        Double::class.javaPrimitiveType, Double::class.javaObjectType -> node.asDouble()
        Float::class.javaPrimitiveType, Float::class.javaObjectType -> node.asDouble().toFloat()
        else -> null
    }

    /**
     * Calls [target]'s [name] taking as many arguments as [args], the most derived first (the extension's override
     * before the generated layer's): a method only the generated layer declares (onPageStarted, whose Bitmap has no
     * hand-written stand-in).
     */
    private fun byName(target: Any, name: String, vararg args: Any?) {
        val method = generateSequence<Class<*>>(target.javaClass) { it.superclass }
            .flatMap { it.declaredMethods.asSequence() }
            .firstOrNull { it.name == name && it.parameterCount == args.size && !java.lang.reflect.Modifier.isStatic(it.modifiers) }
            ?: return
        try {
            method.isAccessible = true
            method.invoke(target, *args)
        } catch (e: InvocationTargetException) {
            throw e.cause ?: e
        }
    }

    private class Request(
        private val url: String,
        private val method: String,
        private val headers: Map<String, String>,
        private val mainFrame: Boolean,
    ) : WebResourceRequest {
        override fun getUrl(): Uri = Uri.parse(url)

        override fun isForMainFrame() = mainFrame

        override fun isRedirect() = false

        override fun hasGesture() = false

        override fun getMethod() = method

        override fun getRequestHeaders() = headers
    }

    private class Failure(private val code: Int, private val text: String) : WebResourceError() {
        override fun getErrorCode() = code

        override fun getDescription(): CharSequence = text
    }

    companion object {
        /** How long an answering call may take before its page gets undefined (Phase 7c's §7). */
        const val ANSWER_TIMEOUT_MS = 30_000L

        /** How long a one-way call the page posted still reaches its extension after the page went: a game's last save. */
        const val LATE_CALLS_MS = 30_000L

        /** Android's message for a call whose Java threw. */
        const val JAVA_EXCEPTION = "Java exception was raised during method invocation"

        private val UNDEFINED = emptyMap<String, Any?>()
        private val CANCEL = mapOf<String, Any?>("accept" to false)
        private val SHOW = mapOf<String, Any?>("show" to true)
    }
}

/**
 * [url]'s file, and what follows its path (`?query#fragment`), when it's a `file:` address, or null. It reads:
 * - Android's forms: `file:///a/b`, `file:/a/b` and `file://localhost/a/b`, escaped or with a raw space;
 * - the JVM's on Windows, which Ayu's launchers make as `"file://" + absolutePath`: `file://C:\a\b`.
 */
internal fun fileOf(url: String): Pair<File, String>? {
    if (!url.regionMatches(0, "file:", 0, 5, ignoreCase = true)) return null
    val end = url.indexOfAny(charArrayOf('?', '#')).let { if (it < 0) url.length else it }
    var path = url.substring(5, end).replace('\\', '/')
    if (path.startsWith("//")) {
        val authority = path.substring(2).substringBefore('/')
        path = when {
            authority.isEmpty() || authority.equals("localhost", ignoreCase = true) -> path.substring(2 + authority.length)
            // file://C:/…: a drive, not a host.
            authority.length == 2 && authority[1] == ':' && authority[0].isLetter() -> path.substring(2)
            // Another machine's file.
            else -> return null
        }
    }
    val decoded = try {
        URLDecoder.decode(path.replace("+", "%2B"), Charsets.UTF_8)
    } catch (e: IllegalArgumentException) {
        return null
    }
    // file:///C:/… names C:/….
    val native = if (decoded.length > 2 && decoded[0] == '/' && decoded[2] == ':' && decoded[1].isLetter()) decoded.substring(1) else decoded
    return if (native.isEmpty()) null else File(native) to url.substring(end)
}

/**
 * The name the app serves a folder under (Phase 7c's §6): the same every run for [extension] (its plugin file's name)
 * and [folder] (relative to the engine's data folder), so a page's own storage there stays its own, and no other
 * extension's. The first 20 hex digits of their SHA-256.
 */
internal fun servedName(extension: String, folder: String): String =
    MessageDigest.getInstance("SHA-256").digest("$extension\n$folder".toByteArray()).joinToString("") { "%02x".format(it) }.take(20)
