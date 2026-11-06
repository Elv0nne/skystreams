package dev.akash.cs3engine.jvm

import android.app.Dialog
import android.content.Context
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.stubs.MainThread
import dev.akash.cs3engine.stubs.Ui
import dev.akash.cs3engine.stubs.WebCookies
import dev.akash.cs3engine.stubs.WebPages
import dev.akash.cs3engine.ui.ExtensionUi
import kotlinx.coroutines.runBlocking
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class JvmPagesTest {
    private val plugin = File("/plugins/Test.cs3")
    private val mapper = jacksonObjectMapper()
    private val host = JvmUiHost(pluginOf = { null }, pluginIn = { plugin })
    private val ui = ExtensionUi(host, emit = { _, _ -> })

    /** The app's side, recorded: what the engine asked of it. */
    private class Bridge : JvmPages.PageBridge {
        val opened = CopyOnWriteArrayList<List<Any?>>()
        val navigated = CopyOnWriteArrayList<String>()
        val served = CopyOnWriteArrayList<Map<String, String>?>()
        val closed = CopyOnWriteArrayList<Long>()
        val scripts = CopyOnWriteArrayList<String>()
        var answer = "null"
        private var next = 100L

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
        ): Long {
            opened += listOf(session, node, url, headers, userAgent, interfaces, fullScreen, serve, answering)
            return ++next
        }

        override fun navigate(page: Long, url: String, headers: Map<String, String>, serve: Map<String, String>?) {
            navigated += url
            served += serve
        }

        override fun close(page: Long) {
            closed += page
        }

        override fun eval(page: Long, script: String, onResult: (String) -> Unit) {
            scripts += script
            onResult(answer)
        }
    }

    private val bridge = Bridge()
    private val pages = JvmPages(locate = host::locate, fullScreen = host::isFullScreen, extensionOf = host::extensionOf, bridge = bridge)

    /** What the extension's clients and interfaces heard, and on which thread. */
    private val heard = CopyOnWriteArrayList<String>()

    private inner class Client : WebViewClient() {
        // onPageStarted takes a Bitmap no stand-in is written for: the engine finds it by name and count.
        @Suppress("unused")
        fun onPageStarted(view: WebView, url: String, favicon: Any?) {
            heard += "started $url"
        }

        override fun onPageFinished(view: WebView, url: String) {
            heard += "finished $url main=${MainThread.isMainThread()}"
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            heard += "error ${error.errorCode} ${error.description}"
        }

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            heard += "override ${request.url}"
            return request.url.toString().contains("code=")
        }

        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            heard += "request ${request.method} ${request.url} ${request.requestHeaders["Authorization"]} main=${MainThread.isMainThread()}"
            return null
        }
    }

    class Interface(private val heard: MutableList<String>) {
        @JavascriptInterface
        fun signedIn(name: String, age: Int) {
            heard += "signedIn $name $age main=${MainThread.isMainThread()}"
        }
    }

    @BeforeTest
    fun wire() {
        Ui.setListener(host)
        MainThread.setAfterTask(host::afterTask)
        host.pages = pages
        WebPages.install(pages)
    }

    @AfterTest
    fun unwire() {
        WebPages.install(null)
        Ui.setListener(null)
        MainThread.setAfterTask(null)
        Ui.windows().forEach { Ui.dismissed(it.owner) }
        WebCookies.clear()
    }

    private fun event(json: String): JsonNode = mapper.readTree(json)

    private fun waitFor(test: () -> Boolean) {
        val until = System.currentTimeMillis() + 5_000
        while (!test() && System.currentTimeMillis() < until) Thread.sleep(10)
        assertTrue(test(), "timed out; heard $heard, opened ${bridge.opened}")
    }

    /** A screen whose dialog holds [view]; returns the session. */
    private fun screenWith(view: () -> WebView): Int = runBlocking {
        ui.openSettings(plugin) {
            Dialog(Context()).apply { setContentView(LinearLayout(context).apply { addView(view()) }) }.show()
        }["session"] as Int
    }

    private fun pageView(): WebView = WebView(Context()).apply {
        settings.userAgentString = "SkyStreamTest/1.0"
        webViewClient = Client()
        webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                heard += "progress $newProgress"
            }
        }
        addJavascriptInterface(Interface(heard), "Bridge")
        loadUrl("https://site.test/login", mapOf("Referer" to "https://site.test/"))
    }

    @Test
    fun `a WebView in an open screen's window gets its page, with its headers, agent and interfaces, and loads again through it`() {
        lateinit var view: WebView
        val session = screenWith { pageView().also { view = it } }
        waitFor { bridge.opened.isNotEmpty() }
        val (openedSession, node, url, headers, agent, interfaces) = bridge.opened.single().let { Six(it) }
        assertEquals(false, bridge.opened.single()[6], "its window doesn't ask for the whole screen")
        assertEquals(session, openedSession)
        assertEquals(host.locate(onMain { view })!!.second, node)
        assertEquals("https://site.test/login", url)
        assertEquals(mapOf("Referer" to "https://site.test/"), headers)
        assertEquals("SkyStreamTest/1.0", agent)
        assertEquals(mapOf("Bridge" to listOf("signedIn")), interfaces)
        onMain { view.loadUrl("https://site.test/next") }
        assertEquals(listOf("https://site.test/next"), bridge.navigated)
    }

    @Test
    fun `a WebView no screen holds loads nothing, however it's driven`() {
        val headless = onMain { WebView(Context()).apply { loadUrl("https://scraper.test/") } }
        var answer: String? = null
        onMain {
            headless.reload()
            headless.evaluateJavascript("document.cookie") { answer = it }
        }
        drainMain()
        // A background window's page isn't on screen either: parked, or kept behind Support.
        onMain { Dialog(Context()).apply { setContentView(pageView()) }.show() }
        drainMain()
        Thread.sleep(200)
        drainMain()
        assertEquals("null", answer)
        assertTrue(bridge.opened.isEmpty(), "no page for a WebView no screen holds: ${bridge.opened}")
    }

    @Test
    fun `page events reach the extension's clients on the main thread, and its cookies the CookieManager`() {
        screenWith { pageView() }
        waitFor { bridge.opened.isNotEmpty() }
        val rid = 101L
        pages.event(rid, event("""{"type": "started", "url": "https://site.test/login"}"""))
        pages.event(rid, event("""{"type": "finished", "url": "https://site.test/login", "title": "Sign in", "cookies": [{"name": "session", "value": "ok", "domain": ".site.test"}]}"""))
        pages.event(rid, event("""{"type": "failed", "url": "https://site.test/img.png", "code": -2, "text": "net::ERR_FAILED", "mainFrame": false}"""))
        waitFor { heard.any { it.startsWith("error") } }
        assertEquals(
            listOf("started https://site.test/login", "progress 10", "progress 100", "finished https://site.test/login main=true", "error -2 net::ERR_FAILED"),
            heard.toList(),
        )
        assertEquals("session=ok", CookieManager.getInstance().getCookie("https://www.site.test/"))
    }

    @Test
    fun `a navigation after the first asks shouldOverrideUrlLoading, and true stops the page there`() {
        screenWith { pageView() }
        waitFor { bridge.opened.isNotEmpty() }
        pages.event(101, event("""{"type": "started", "url": "https://site.test/login"}"""))
        pages.event(101, event("""{"type": "started", "url": "https://site.test/done?code=abc"}"""))
        waitFor { "window.stop()" in bridge.scripts }
        assertEquals(listOf("started https://site.test/login", "progress 10", "override https://site.test/done?code=abc"), heard.toList())
    }

    @Test
    fun `a navigation a browser reports late - started at the old address, finished at the new - still reaches shouldOverrideUrlLoading`() {
        // WebKitGTK (Linux, 2026-10-07): a script's navigation starts under the page's old address.
        screenWith { pageView() }
        waitFor { bridge.opened.isNotEmpty() }
        pages.event(101, event("""{"type": "started", "url": "https://site.test/login"}"""))
        pages.event(101, event("""{"type": "finished", "url": "https://site.test/login"}"""))
        pages.event(101, event("""{"type": "started", "url": "https://site.test/login"}"""))
        pages.event(101, event("""{"type": "finished", "url": "https://site.test/done?code=abc"}"""))
        waitFor { "window.stop()" in bridge.scripts }
        assertEquals(listOf("override https://site.test/login", "override https://site.test/done?code=abc"), heard.filter { it.startsWith("override") })
        assertTrue(heard.none { it == "finished https://site.test/done?code=abc main=true" }, "taken over: no onPageFinished for it")
    }

    @Test
    fun `the extension's own loads aren't offered to shouldOverrideUrlLoading, however the browser reports them - Android never offers loadUrl's`() {
        lateinit var view: WebView
        screenWith { pageView().also { view = it } }
        waitFor { bridge.opened.isNotEmpty() }
        pages.event(101, event("""{"type": "started", "url": "https://site.test/login"}"""))
        pages.event(101, event("""{"type": "finished", "url": "https://site.test/login"}"""))
        // Its own load, which its client would take over if offered (code=).
        onMain { view.loadUrl("https://site.test/account?code=own") }
        pages.event(101, event("""{"type": "started", "url": "https://site.test/account?code=own"}"""))
        pages.event(101, event("""{"type": "finished", "url": "https://site.test/account?code=own"}"""))
        // Another, reported late as WebKitGTK reports one: started at the old address, finished at the new.
        onMain { view.loadUrl("https://site.test/profile?code=own") }
        pages.event(101, event("""{"type": "started", "url": "https://site.test/account?code=own"}"""))
        pages.event(101, event("""{"type": "finished", "url": "https://site.test/profile?code=own"}"""))
        waitFor { heard.any { it.startsWith("finished https://site.test/profile") } }
        assertEquals(emptyList(), heard.filter { it.startsWith("override") })
        assertTrue("window.stop()" !in bridge.scripts)
    }

    @Test
    fun `a navigation the extension takes over by loading elsewhere itself isn't stopped - its own load goes on, not offered again`() {
        screenWith {
            pageView().apply {
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                        heard += "override ${request.url}"
                        view.loadUrl("https://site.test/app?${request.url.query}")
                        return true
                    }
                }
            }
        }
        waitFor { bridge.opened.isNotEmpty() }
        pages.event(101, event("""{"type": "started", "url": "https://site.test/login"}"""))
        pages.event(101, event("""{"type": "started", "url": "https://site.test/done?code=abc"}"""))
        waitFor { bridge.navigated.isNotEmpty() }
        pages.event(101, event("""{"type": "started", "url": "https://site.test/app?code=abc"}"""))
        drainMain()
        assertEquals(listOf("https://site.test/app?code=abc"), bridge.navigated.toList())
        assertTrue("window.stop()" !in bridge.scripts, "a stop would cancel the load it just started")
        assertEquals(listOf("override https://site.test/done?code=abc"), heard.filter { it.startsWith("override") })
    }

    @Test
    fun `a page's script calls its JavaScript interface, and its requests reach shouldInterceptRequest, both off the main thread`() {
        screenWith { pageView() }
        waitFor { bridge.opened.isNotEmpty() }
        pages.event(101, event("""{"type": "message", "message": "{\"cs3-js\": 1, \"name\": \"Bridge\", \"method\": \"signedIn\", \"args\": [\"Test Person\", 30]}"}"""))
        pages.event(101, event("""{"type": "request", "url": "https://site.test/api/me", "method": "GET", "headers": {"Authorization": "Bearer t"}}"""))
        waitFor { heard.size == 2 }
        assertEquals(
            setOf("signedIn Test Person 30 main=false", "request GET https://site.test/api/me Bearer t main=false"),
            heard.toSet(),
        )
    }

    @Test
    fun `evaluateJavascript goes to the page and answers on the main thread`() {
        lateinit var view: WebView
        screenWith { pageView().also { view = it } }
        waitFor { bridge.opened.isNotEmpty() }
        bridge.answer = "\"Sign in\""
        var answer: Pair<String, Boolean>? = null
        onMain { view.evaluateJavascript("document.title") { answer = it to MainThread.isMainThread() } }
        waitFor { answer != null }
        assertEquals("\"Sign in\"" to true, answer)
        assertEquals(listOf("document.title"), bridge.scripts)
    }

    @Test
    fun `a page the app closed isn't asked for again by each read, only by the extension's next load`() {
        lateinit var view: WebView
        screenWith { pageView().also { view = it } }
        waitFor { bridge.opened.isNotEmpty() }
        pages.event(101, event("""{"type": "closed"}"""))
        drainMain()
        onMain { pages.shown(listOf(view)) }
        assertEquals(1, bridge.opened.size, "not opened again by a read")
        onMain { view.loadUrl("https://site.test/again") }
        assertEquals(2, bridge.opened.size)
        assertEquals("https://site.test/again", bridge.opened.last()[2])
    }

    @Test
    fun `a window going closes its page, and so does a destroyed WebView`() {
        val session = screenWith { pageView() }
        waitFor { bridge.opened.isNotEmpty() }
        runBlocking { ui.close(session, force = true) }
        waitFor { bridge.closed == listOf(101L) }
        lateinit var second: WebView
        screenWith { pageView().also { second = it } }
        waitFor { bridge.opened.size == 2 }
        onMain { second.destroy() }
        waitFor { bridge.closed == listOf(101L, 102L) }
    }

    private class Six(val list: List<Any?>) {
        operator fun component1() = list[0]
        operator fun component2() = list[1]
        operator fun component3() = list[2]
        operator fun component4() = list[3]
        operator fun component5() = list[4]
        operator fun component6() = list[5]
    }

    @Test
    fun `a page in a full-screen window says so as it opens, for the app to give it what a full-screen page needs`() {
        // Phase 7c's §2: its extension's toasts in it, and on a desktop its own close button.
        lateinit var view: WebView
        runBlocking {
            ui.openSettings(plugin) {
                Dialog(Context(), 16973834).apply { setContentView(LinearLayout(context).apply { addView(pageView().also { view = it }) }) }.show()
            }
        }
        waitFor { bridge.opened.isNotEmpty() }
        assertEquals(true, bridge.opened.single()[6])
        assertTrue(onMain { host.isFullScreen(view) })
    }

    /** A game's web view, made as Ayu's launchers make theirs: its page in the extension's own files, file access on. */
    private fun gameView(page: File, allowFiles: Boolean = true): WebView = WebView(Context()).apply {
        settings.javaScriptEnabled = true
        settings.allowFileAccess = allowFiles
        loadUrl("file://${page.absolutePath}?game=test")
    }

    @Test
    fun `a page of the extension's own files is served from its folder, under a name the same every run for the extension and the folder`() {
        // Phase 7c's §6: the GBA games read their game file beside their page, which no browser lets a file page do.
        val folder = File(Context().filesDir, "cs3test-served/game").apply { mkdirs() }
        screenWith { gameView(File(folder, "index.html")) }
        waitFor { bridge.opened.isNotEmpty() }
        @Suppress("UNCHECKED_CAST")
        val serve = bridge.opened.single()[7] as Map<String, String>
        assertEquals(folder.absolutePath, serve["folder"])
        assertEquals("index.html?game=test", serve["path"])
        val file = serve["file"]!!
        assertTrue(file.startsWith("file:///") && file.endsWith("/cs3test-served/game/"), file)
        assertEquals(File(folder, "index.html") to "?game=test", fileOf(file + serve["path"]), "reported back, it reads as the page")
        // The test's plugin is /plugins/Test.cs3.
        assertEquals(servedName("Test", "files/cs3test-served/game"), serve["name"])
        assertTrue(serve["name"]!!.matches(Regex("[0-9a-f]{20}")), serve["name"])
        assertNotEquals(servedName("Other", "files/cs3test-served/game"), serve["name"], "another extension's")
        assertNotEquals(servedName("Test", "files/cs3test-served/other"), serve["name"], "another folder's")
    }

    @Test
    fun `a file page with no file access, or outside the engine's data folders, isn't served - its address loads as it is`() {
        val inside = File(Context().cacheDir, "cs3test-unserved").apply { mkdirs() }
        val outside = createTempDirectory("cs3-outside").toFile()
        lateinit var view: WebView
        screenWith { gameView(File(inside, "index.html"), allowFiles = false).also { view = it } }
        waitFor { bridge.opened.isNotEmpty() }
        assertEquals(null, bridge.opened.single()[7], "no file access: Android's default since API 30")
        onMain {
            view.settings.allowFileAccess = true
            view.loadUrl("file://${File(outside, "index.html").absolutePath}")
        }
        assertEquals(listOf<Map<String, String>?>(null), bridge.served.toList(), "outside the data folders")
        onMain { view.loadUrl("file://${File(inside, "index.html").absolutePath}") }
        assertEquals("index.html", bridge.served.last()!!["path"], "a later load into the cache is served too")
    }

    @Test
    fun `file addresses are read in Android's forms and the desktops' - a raw space, escapes, localhost, Windows' backslashes`() {
        // Ayu's launchers write "file://" + the absolute path: on Windows that's file://C:\Users\…, and macOS's data
        // folder has a space in it (Application Support).
        assertEquals(File("/a b/c.html") to "?x=1#y", fileOf("file:///a b/c.html?x=1#y"))
        assertEquals(File("/a b/ü.html") to "", fileOf("file:/a%20b/%C3%BC.html"))
        assertEquals(File("/a/c.html") to "", fileOf("file://localhost/a/c.html"))
        assertEquals(File("C:/Users/a/c.html") to "?game=x", fileOf("file://C:\\Users\\a\\c.html?game=x"))
        assertEquals(File("C:/Users/a/c.html") to "", fileOf("file:///C:/Users/a/c.html"))
        assertEquals(File("/a/1+1.html") to "", fileOf("file:///a/1+1.html"))
        assertEquals(null, fileOf("https://site.test/a.html"))
        assertEquals(null, fileOf("file://server/share/a.html"), "another machine's")
        assertEquals(null, fileOf("file:///100%.html"), "not an address")
    }

    /** A game's interface (Phase 7c's §7): a one-way save, and methods that answer the page. */
    class GameInterface(private val heard: MutableList<String>) {
        @Volatile private var saved = ""

        @JavascriptInterface fun saveState(state: String) { saved = state; heard += "saveState $state" }
        @JavascriptInterface fun loadState(): String = saved
        @JavascriptInterface fun isReady(): Boolean = true
        @JavascriptInterface fun level(): Int = 42
        @JavascriptInterface fun half(): Double = 2.5
        @JavascriptInterface fun name(): String = "Test Game ü\u0000!"
        @JavascriptInterface fun nothing(): String? = null
        @JavascriptInterface fun empty(): Any? = null
        @JavascriptInterface fun thing(): Any = Thread.currentThread()
        @JavascriptInterface fun broken(): String = throw IllegalStateException("broken on purpose")
        @JavascriptInterface fun slow(): String { Thread.sleep(500); return "late" }
    }

    /** A screen with a game's page; its session. */
    private fun gameScreen(): Int = screenWith {
        WebView(Context()).apply {
            settings.javaScriptEnabled = true
            addJavascriptInterface(GameInterface(heard), "Game")
            loadUrl("https://game.test/")
        }
    }

    private var callIds = 0

    /** The page's answering call of Game's [method] with [args], as the app asks the engine about it. */
    private fun call(method: String, vararg args: Any?): Map<String, Any?> = runBlocking {
        val message = mapper.writeValueAsString(
            mapOf("cs3-js" to 1, "name" to "Game", "method" to method, "args" to args.toList(), "id" to "d.${++callIds}"),
        )
        pages.answer(101, mapper.valueToTree(mapOf("type" to "call", "message" to message)))
    }

    /** The page's one-way call of Game's [method]. */
    private fun post(method: String, vararg args: Any?) {
        val message = mapper.writeValueAsString(mapOf("cs3-js" to 1, "name" to "Game", "method" to method, "args" to args.toList()))
        pages.event(101, mapper.valueToTree(mapOf("type" to "message", "message" to message)))
    }

    /** Collects what the engine logs while [block] runs. */
    private fun logged(block: () -> Unit): List<String> {
        val logs = CopyOnWriteArrayList<String>()
        val log = HostHooks.log
        HostHooks.log = { logs += it }
        try {
            block()
        } finally {
            HostHooks.log = log
        }
        return logs
    }

    @Test
    fun `an interface's methods that return a value are named apart as the page opens - its one-way ones stay as they were`() {
        gameScreen()
        waitFor { bridge.opened.isNotEmpty() }
        assertEquals(mapOf("Game" to listOf("saveState")), bridge.opened.single()[5])
        @Suppress("UNCHECKED_CAST")
        val answering = (bridge.opened.single()[8] as Map<String, List<String>>).mapValues { it.value.sorted() }
        assertEquals(
            mapOf("Game" to listOf("broken", "empty", "half", "isReady", "level", "loadState", "name", "nothing", "slow", "thing")),
            answering,
        )
    }

    @Test
    fun `answering calls give the page what Android's bridge gives it - values, a null String as undefined, a throw`() {
        gameScreen()
        waitFor { bridge.opened.isNotEmpty() }
        val logs = logged {
            assertEquals(mapOf("value" to true), call("isReady"))
            assertEquals(mapOf("value" to 42), call("level"))
            assertEquals(mapOf("value" to 2.5), call("half"))
            assertEquals(mapOf("value" to "Test Game ü\u0000!"), call("name"))
            assertEquals(emptyMap(), call("nothing"), "a null String: undefined, as Chromium's bridge gives it")
            assertEquals(mapOf("value" to null), call("empty"), "any other null: null")
            assertEquals(emptyMap(), call("thing"), "another kind of object: undefined")
            assertEquals(mapOf("error" to "Java exception was raised during method invocation"), call("broken"))
            assertEquals(mapOf("error" to "Method not found"), call("missing"))
        }
        assertTrue(logs.any { "thing" in it && "undefined" in it }, "$logs")
        assertTrue(logs.any { "broken" in it && "broken on purpose" in it }, "$logs")
    }

    @Test
    fun `an answering call runs after every call the page posted before it`() {
        gameScreen()
        waitFor { bridge.opened.isNotEmpty() }
        post("saveState", """{"level":3}""")
        assertEquals(mapOf("value" to """{"level":3}"""), call("loadState"))
    }

    @Test
    fun `an answering call with no answer in time answers undefined, and is logged - the page goes on`() {
        gameScreen()
        waitFor { bridge.opened.isNotEmpty() }
        pages.answerTimeoutMs = 100
        val logs = logged { assertEquals(emptyMap(), call("slow")) }
        assertTrue(logs.any { "didn't answer" in it }, "$logs")
    }

    @Test
    fun `a one-way call the page posted just before its window went still reaches the extension - a game's last save`() {
        // Ayu's games save on their second Back and close 250 ms later. On the JVM a one-way call is posted, and can
        // reach the engine after the window went: the save must still land.
        val session = gameScreen()
        waitFor { bridge.opened.isNotEmpty() }
        runBlocking { ui.close(session, force = true) }
        waitFor { bridge.closed == listOf(101L) }
        post("saveState", "last")
        waitFor { "saveState last" in heard }
        assertEquals(emptyMap(), call("loadState"), "a page that went answers nothing more")
    }

    /** The page's own [kind] dialog, as the app asks the engine about it. */
    private fun dialog(kind: String, message: String, defaultText: String? = null): Map<String, Any?> = runBlocking {
        pages.answer(
            101,
            mapper.valueToTree(
                mapOf("type" to "dialog", "kind" to kind, "message" to message, "defaultText" to defaultText, "url" to "file:///data/files/game/index.html"),
            ),
        )
    }

    @Test
    fun `with no chrome client, the page's own dialogs get the cancel answer, and nothing shows`() {
        screenWith { WebView(Context()).apply { loadUrl("https://game.test/") } }
        waitFor { bridge.opened.isNotEmpty() }
        assertEquals(mapOf("accept" to false), dialog("alert", "Hello"))
        assertEquals(mapOf("accept" to false), dialog("prompt", "Your name?", "Player"))
    }

    @Test
    fun `a chrome client that takes the page's dialogs answers them, now or later, from any thread - asked on the main thread`() {
        val asked = CopyOnWriteArrayList<String>()
        screenWith {
            WebView(Context()).apply {
                webChromeClient = object : WebChromeClient() {
                    override fun onJsAlert(view: WebView, url: String, message: String, result: JsResult): Boolean {
                        asked += "alert $message $url main=${MainThread.isMainThread()}"
                        result.confirm()
                        return true
                    }

                    override fun onJsConfirm(view: WebView, url: String, message: String, result: JsResult): Boolean {
                        result.cancel()
                        return true
                    }

                    override fun onJsPrompt(view: WebView, url: String, message: String, defaultValue: String?, result: JsPromptResult): Boolean {
                        asked += "prompt $message $defaultValue"
                        Thread {
                            Thread.sleep(200)
                            result.confirm("Tester")
                        }.start()
                        return true
                    }
                }
                loadUrl("https://game.test/")
            }
        }
        waitFor { bridge.opened.isNotEmpty() }
        assertEquals(mapOf("accept" to true, "text" to null), dialog("alert", "Game ready"))
        assertEquals(mapOf("accept" to false, "text" to null), dialog("confirm", "Keep playing?"))
        assertEquals(mapOf("accept" to true, "text" to "Tester"), dialog("prompt", "Your name?", "Player"))
        assertEquals(listOf("alert Game ready file:///data/files/game/index.html main=true", "prompt Your name? Player"), asked.toList())
    }

    @Test
    fun `a chrome client that leaves a dialog to the app has SkyStream show it`() {
        screenWith {
            WebView(Context()).apply {
                webChromeClient = WebChromeClient()
                loadUrl("https://game.test/")
            }
        }
        waitFor { bridge.opened.isNotEmpty() }
        assertEquals(mapOf("show" to true), dialog("confirm", "Keep playing?"))
    }

    @Test
    fun `a dialog whose page goes while its chrome client holds the answer gets cancel`() {
        lateinit var held: JsResult
        // The page goes once the chrome client holds the answer, not after a guess at how long the main thread takes.
        val holding = CountDownLatch(1)
        val session = screenWith {
            WebView(Context()).apply {
                webChromeClient = object : WebChromeClient() {
                    override fun onJsAlert(view: WebView, url: String, message: String, result: JsResult): Boolean {
                        held = result
                        holding.countDown()
                        return true
                    }
                }
                loadUrl("https://game.test/")
            }
        }
        waitFor { bridge.opened.isNotEmpty() }
        val answer = CompletableFuture.supplyAsync { dialog("alert", "Held") }
        assertTrue(holding.await(5, TimeUnit.SECONDS), "the chrome client was asked")
        runBlocking { ui.close(session, force = true) }
        assertEquals(mapOf("accept" to false), answer.get(5, TimeUnit.SECONDS))
        held.confirm() // late: nothing hears it
    }
}
