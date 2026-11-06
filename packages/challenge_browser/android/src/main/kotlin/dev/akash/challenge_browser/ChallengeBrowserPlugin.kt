package dev.akash.challenge_browser

import android.app.Activity
import android.content.Context
import android.content.MutableContextWrapper
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.webkit.WebViewCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Android backend of `ChallengeBrowser`: one WebView per page, created on request and destroyed on
 * dispose. Hidden pages wait in a host view behind Flutter, inside the activity's window: a WebView
 * there runs at full speed with a real viewport, which a WebView outside any window doesn't have.
 */
class ChallengeBrowserPlugin : FlutterPlugin, ActivityAware, PageHostApi {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val pages = HashMap<Long, Page>()
    private var nextId = 1L
    private var events: PageFlutterApi? = null
    private var activity: Activity? = null

    /** Pages are created on this, so they outlive an activity recreated by a configuration change. */
    private var context: MutableContextWrapper? = null
    private var host: FrameLayout? = null

    /** For what needs no window: the engine's version. */
    private var appContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        PageHostApi.setUp(binding.binaryMessenger, this)
        events = PageFlutterApi(binding.binaryMessenger)
        binding.platformViewRegistry.registerViewFactory(
            "dev.akash.challenge_browser/page",
            PageViewFactory({ pages[it] }, { host }, { id, direction -> emit(id, PageEvent(PageEventKind.FOCUS_EXIT, direction = direction)) }),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        PageHostApi.setUp(binding.binaryMessenger, null)
        pages.values.forEach { it.destroy() }
        pages.clear()
        events = null
        scope.cancel()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = attach(binding.activity)

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attach(binding.activity)

    override fun onDetachedFromActivityForConfigChanges() = detachHost()

    override fun onDetachedFromActivity() {
        detachHost()
        // Without an activity the pages have no window; they can't be used again.
        for ((id, page) in pages) {
            page.destroy()
            emit(id, PageEvent(PageEventKind.RENDERER_GONE, crashed = false))
        }
        pages.clear()
        activity = null
    }

    private fun attach(activity: Activity) {
        this.activity = activity
        context?.baseContext = activity
        host?.let { root(activity).addView(it, 0, hostSize(activity)) }
    }

    private fun detachHost() {
        (host?.parent as? ViewGroup)?.removeView(host)
    }

    private fun root(activity: Activity): ViewGroup = activity.findViewById(android.R.id.content)

    /** In density-independent pixels, as the page's CSS pixels are. */
    private fun hostSize(activity: Activity): FrameLayout.LayoutParams {
        val density = activity.resources.displayMetrics.density
        return FrameLayout.LayoutParams((HIDDEN_WIDTH * density).toInt(), (HIDDEN_HEIGHT * density).toInt())
    }

    /** The hidden host: transparent, untouchable, out of focus order and accessibility, behind Flutter. */
    private fun hiddenHost(activity: Activity): FrameLayout = host ?: FrameLayout(activity).also { layout ->
        layout.alpha = 0f
        layout.descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
        layout.importantForAccessibility = ViewGroup.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        root(activity).addView(layout, 0, hostSize(activity))
        host = layout
    }

    private fun emit(pageId: Long, event: PageEvent) {
        val events = events ?: return
        scope.launch { events.onEvent(pageId, event) }
    }

    private fun page(pageId: Long): Page =
        pages[pageId] ?: throw FlutterError("no-page", "No page $pageId: it was disposed, or its renderer ended", null)

    override suspend fun create(scriptChannel: String): Long {
        val activity = activity ?: throw FlutterError("no-activity", "Pages need the app's activity", null)
        val context = context ?: MutableContextWrapper(activity).also { context = it }
        val id = nextId++
        val page = Page(context, id, scriptChannel) { event ->
            if (event.kind == PageEventKind.RENDERER_GONE) pages.remove(id)
            emit(id, event)
        }
        hiddenHost(activity).addView(page.webView, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        pages[id] = page
        return id
    }

    override fun load(pageId: Long, url: String, headers: Map<String, String>) = page(pageId).load(url, headers)

    override suspend fun evaluate(pageId: Long, script: String): String = page(pageId).evaluate(script)

    override fun addDocumentStartScript(pageId: Long, script: String) = page(pageId).addDocumentStartScript(script)

    override suspend fun cookies(pageId: Long, url: String): List<PageCookie> = page(pageId).cookies(url)

    override suspend fun deleteCookies(pageId: Long, url: String, name: String?) = page(pageId).deleteCookies(url, name)

    override suspend fun userAgent(pageId: Long): String = page(pageId).userAgent

    override fun setUserAgent(pageId: Long, userAgent: String) {
        page(pageId).userAgent = userAgent
    }

    override fun setCapture(pageId: Long, enabled: Boolean) {
        page(pageId).capturing = enabled
    }

    /** Desktop only: Android shows pages through platform views. */
    override fun setFrame(pageId: Long, frame: PageFrame?) = Unit

    override fun focus(pageId: Long, forward: Boolean) = page(pageId).focus(forward)

    override fun blur(pageId: Long) = page(pageId).blur()

    override fun setNavigationStops(pageId: Long, prefixes: List<String>) {
        page(pageId).navigationStops = prefixes
    }

    override suspend fun tap(pageId: Long, x: Double, y: Double) = page(pageId).tap(x, y)

    override suspend fun evaluateIsolated(pageId: Long, script: String): String =
        throw FlutterError("unsupported", "Android's WebView has no isolated world", null)

    override fun capabilities(): PageCapabilities = PageCapabilities(canTap = true, isolatedWorlds = false)

    /** Android System WebView's version name: the solver skips checks an outdated one would fail. */
    override fun engineVersion(): String =
        appContext?.let { WebViewCompat.getCurrentWebViewPackage(it)?.versionName } ?: ""

    override suspend fun devTools(pageId: Long, method: String, paramsJson: String): String =
        throw FlutterError("unsupported", "DevTools calls are for Windows only", null)

    override fun serveFolder(pageId: Long, name: String, folder: String): String =
        throw FlutterError("unsupported", "Android's WebView reads an extension's files itself", null)

    override fun holdDialogs(pageId: Long, hold: Boolean): Unit =
        throw FlutterError("unsupported", "Android's extension pages are the extension's own WebView, with its own dialogs", null)

    override fun answerDialog(pageId: Long, dialogId: Long, accept: Boolean, text: String?): Unit =
        throw FlutterError("unsupported", "Android's extension pages are the extension's own WebView, with its own dialogs", null)

    /** The page's title as its WebView has it (an untitled page's address): nothing runs in the page. */
    override fun title(pageId: Long): String? = page(pageId).webView.title

    override suspend fun dispose(pageId: Long) {
        pages.remove(pageId)?.destroy()
    }

    private companion object {
        /** A hidden page's viewport: a common laptop size, so pages lay out as they would for a person. */
        const val HIDDEN_WIDTH = 1024
        const val HIDDEN_HEIGHT = 768
    }
}
