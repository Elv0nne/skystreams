package dev.akash.cs3engine.jvm

import android.app.Dialog
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.fragment.app.DialogFragment
import com.lagradost.cloudstream3.CommonActivity
import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.stubs.MainThread
import dev.akash.cs3engine.stubs.Ui
import dev.akash.cs3engine.ui.ExtensionUiHost
import dev.akash.cs3engine.ui.KeptWindows
import dev.akash.cs3engine.ui.NodeIds
import dev.akash.cs3engine.ui.Popups
import dev.akash.cs3engine.ui.Sorting
import dev.akash.cs3engine.ui.UiActions
import dev.akash.cs3engine.ui.UiSession
import dev.akash.cs3engine.ui.UiTree
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Collections
import java.util.IdentityHashMap
import kotlin.coroutines.resume

/**
 * Extension screens on the JVM and iOS. The stand-in windows an open screen's extension shows are read
 * into trees for SkyStream's sheet, and acted on as the person would. A window is an extension's by its
 * fragment's class, its dialog's own class, or the extension's code on the stack where it showed. A screen
 * is read after a main-thread task that changed a stand-in, at most every [READ_MS] (the spec's
 * "Changes"). A window of an extension with no screen open is sorted by the spec's pop-up rules
 * ([Popups]): shown in a screen of its own while the person waits on the extension, else kept for the
 * extension's Support button ([KeptWindows]), which opens them ([openKept]) and gets them back when they close; a page is kept only once no call
 * of its extension waits on it (one that does closes as if the person closed it). Main thread only: [open], [act] and [close] go there, and Ui's listener is called there.
 */
class JvmUiHost(
    private val pluginOf: (Class<*>) -> File?,
    private val pluginIn: (Throwable) -> File?,
    /** The orientation extensions asked of the app's activity, if any: a full-screen window carries it (Phase 7c's §5). */
    private val orientation: () -> Int? = { CommonActivity.activity?.requestedOrientation?.takeIf { it != -1 } },
) : ExtensionUiHost, Ui.Listener {
    private class Captured(val window: Ui.Window, val session: UiSession, val number: Int)

    /** [support]: Support opened it ([openKept]); closing it, or one of its windows, puts back what it took (the spec's §7). */
    private class Screen(val session: UiSession, val support: Boolean = false) {
        val tree = UiTree(NodeIds())
        var last: List<Map<String, Any?>>? = null

        /** The windows Support took from the kept ones: only these go back; one that joined meanwhile closes as anywhere. */
        val fromKept: MutableSet<Ui.Window> = Collections.newSetFromMap(IdentityHashMap())
    }

    private val captured = ArrayList<Captured>()
    private val screens = HashMap<String, Screen>()
    private val kept = KeptWindows<Ui.Window>()

    /** Background pages parked for their second sort ([Sorting.Later]), with their extension: one forgotten meanwhile is never sorted. */
    private val parked = LinkedHashMap<Ui.Window, File>()

    /** The web views' pages (part 5): told which web views are on screen after each read. Set once, as the engine starts. */
    @Volatile
    var pages: JvmPages? = null

    // Set once, on the engine's thread; read on the main thread.
    @Volatile
    private var popups: Popups? = null
    private var nextWindow = 1
    private var lastRead = 0L
    private var readPosted = false

    override fun attach(popups: Popups) {
        this.popups = popups
    }

    override suspend fun open(session: UiSession, plugin: File, open: () -> Unit) = withContext(Dispatchers.Main.immediate) {
        screens[plugin.absolutePath] = Screen(session)
        try {
            open()
        } catch (t: Throwable) {
            screens.remove(plugin.absolutePath)
            throw t
        }
    }

    /** Returns once the main thread has run what was posted before (a dialog fragment's commit). */
    override suspend fun settled(session: UiSession) = suspendCancellableCoroutine { done ->
        MainThread.post { if (done.isActive) done.resume(Unit) }
    }

    override suspend fun act(session: UiSession, node: Int, action: String, value: Any?) = withContext(Dispatchers.Main.immediate) {
        val screen = screenOf(session) ?: throw IllegalStateException("screen ${session.id} is closed")
        val view = screen.tree.ids.view(node) ?: throw IllegalArgumentException("node $node is gone")
        try {
            if (action == "close") {
                val window = captured.lastOrNull { it.session === session && (it.window.root === view || view.isWithin(it.window.root)) }
                    ?: throw IllegalArgumentException("node $node is in no open window")
                if (screen.support && window.window in screen.fromKept) putBack(session, listOf(window)) else dismiss(window, force = value == "force")
            } else {
                Ui.acting { UiActions.apply(view, action, value) }
            }
        } finally {
            // Read after the action, whatever it changed.
            Ui.changed()
        }
    }

    override suspend fun close(session: UiSession, force: Boolean) = withContext(Dispatchers.Main.immediate) {
        val windows = captured.filter { it.session === session }.asReversed()
        if (windows.isEmpty()) {
            end(session, "closed")
            return@withContext
        }
        // Support's own windows go back behind its button, the extension never told (the spec's §7); one that joined it
        // meanwhile (the pop-up's own sub-dialog, a page a call waits on) closes as any screen's window does.
        val screen = screenOf(session)
        val back = if (screen?.support == true) windows.filter { it.window in screen.fromKept } else emptyList()
        if (back.isNotEmpty()) putBack(session, back)
        val rest = windows - back.toSet()
        if (rest.isEmpty()) return@withContext
        rest.forEach { dismiss(it, force) }
        if (!force) {
            MainThread.postDelayed({ captured.filter { it.session === session }.asReversed().forEach { dismiss(it, force = true) } }, FORCE_AFTER_MS)
        }
    }

    override suspend fun openKept(session: UiSession, plugin: File): Boolean = withContext(Dispatchers.Main.immediate) {
        val windows = kept.take(plugin).filter { Ui.isShowing(it.root) }
        popups?.kept(plugin, emptyList(), null)
        if (windows.isEmpty()) return@withContext false
        val screen = Screen(session, support = true)
        screens[plugin.absolutePath] = screen
        // The oldest at the bottom, as they came.
        windows.asReversed().forEach {
            screen.fromKept += it
            take(it, session)
        }
        true
    }

    override suspend fun forgetKept(plugin: File) = withContext(Dispatchers.Main.immediate) {
        // Pages still waiting for their sort go too (the spec's §7): sorted later, they'd be kept for an extension that's gone.
        parked.filterValues { it.absolutePath == plugin.absolutePath }.keys.forEach { window ->
            parked.remove(window)
            forceOut(window)
        }
        val windows = kept.take(plugin)
        windows.forEach(::forceOut)
        if (windows.isNotEmpty()) popups?.kept(plugin, emptyList(), null)
    }

    override fun shown(window: Ui.Window) {
        // Shown off the main thread and closed on it before this ran: nothing to take in.
        if (!Ui.isShowing(window.root)) return
        val plugin = ownerOf(window)
        if (plugin == null) {
            dropPageLater(window)
            return
        }
        // An ended screen's extension (it restarted, or crashed) gets no new windows into it.
        val screen = screens[plugin.absolutePath]?.takeUnless { it.session.ended }
        if (screen != null) take(window, screen.session) else sortLater(window, plugin)
    }

    /**
     * A window whose extension isn't known: no screen or Support button is its, so it's left, unless it holds a
     * page, which closes as if the person closed it once it has shown (part 2's rule: nothing on the JVM loads
     * the page, and the call that showed it would wait out its timeout).
     */
    private fun dropPageLater(window: Ui.Window) {
        MainThread.post {
            if (!Ui.isShowing(window.root) || !window.root.holdsPage()) return@post
            HostHooks.log("a window with a page in it, of no extension found, closes, as if closed")
            cancel(window)
        }
    }

    /** Closes [window] as the person would: its dialog cancels (its extension hears it), or its fragment goes. */
    private fun cancel(window: Ui.Window) {
        runCatching { (window.owner as? Dialog)?.cancel() ?: (window.fragment as? DialogFragment)?.dismissAllowingStateLoss() }
    }

    private fun take(window: Ui.Window, session: UiSession) {
        captured += Captured(window, session, nextWindow++)
        Ui.changed()
    }

    /**
     * Puts Support's [windows] (top first) back behind its button, as they were kept (the spec's §7, the owner
     * 2026-10-08): the extension is never told they closed, so Support opens them again. The screen ends once
     * none is left.
     */
    private fun putBack(session: UiSession, windows: List<Captured>) {
        val plugin = session.plugin
        for (window in windows) {
            captured.remove(window)
            val words = UiTree(NodeIds()).wordsOf(window.window.root)
            val title = words.firstOrNull()?.take(TITLE_MAX) ?: plugin.nameWithoutExtension
            kept.putBack(plugin, window.window, title, words).forEach(::forceOut)
        }
        popups?.kept(plugin, kept.titles(plugin), null)
        if (captured.none { it.session === session }) end(session, "closed") else Ui.changed()
    }

    /**
     * A window of an extension with no screen of its open, sorted once it has shown (a page set in after
     * still counts): the spec's pop-up rules. A page in the background is parked and sorted again later
     * ([sortPage]).
     */
    private fun sortLater(window: Ui.Window, plugin: File) {
        val popups = popups ?: return
        MainThread.post {
            if (!Ui.isShowing(window.root)) return@post
            // Its screen opened meanwhile: it's that screen's.
            screens[plugin.absolutePath]?.takeUnless { it.session.ended }?.let { screen ->
                take(window, screen.session)
                return@post
            }
            when (val sorting = popups.sort(plugin, window.root.holdsPage(), window.unseen())) {
                is Sorting.Show -> {
                    screens[plugin.absolutePath] = Screen(sorting.session)
                    take(window, sorting.session)
                }
                Sorting.Drop -> drop(window, plugin, popups)
                Sorting.Keep -> keep(window, plugin, popups)
                is Sorting.Later -> {
                    parked[window] = plugin
                    MainThread.postDelayed({ sortPage(window, plugin, popups) }, sorting.afterMs)
                }
            }
        }
    }

    /** A background window holding a page, parked [Sorting.Later]: taken into its screen if one opened, else sorted again. */
    private fun sortPage(window: Ui.Window, plugin: File, popups: Popups) {
        // Forgotten meanwhile (its extension unloaded): nothing left to sort.
        if (parked.remove(window) == null) return
        // Closed meanwhile (its extension's own success, or the call ended it): nothing left to sort.
        if (!Ui.isShowing(window.root)) return
        screens[plugin.absolutePath]?.takeUnless { it.session.ended }?.let { screen ->
            take(window, screen.session)
            return
        }
        if (popups.sortPage(plugin) == Sorting.Drop) drop(window, plugin, popups) else keep(window, plugin, popups)
    }

    /** A page a call of its extension waits on: closed as the person would close it, so the call goes on. */
    private fun drop(window: Ui.Window, plugin: File, popups: Popups) {
        HostHooks.log("${plugin.name}'s background window with a page in it, which a call waits on, closes, as if closed")
        cancel(window)
        popups.dropped(plugin, "page")
    }

    /** Kept out of sight for the extension's Support button, titled by its first words. */
    private fun keep(window: Ui.Window, plugin: File, popups: Popups) {
        val words = UiTree(NodeIds()).wordsOf(window.root)
        val title = words.firstOrNull()?.take(TITLE_MAX) ?: plugin.nameWithoutExtension
        kept.keep(plugin, window, title, words).forEach(::forceOut)
        popups.kept(plugin, kept.titles(plugin), title)
    }

    private fun View.holdsPage(): Boolean =
        this is WebView || (this is ViewGroup && (0 until childCount).any { getChildAt(it).holdsPage() })

    /** Whether its extension made this dialog invisible: alpha 0, or a side of a pixel or less. */
    private fun Ui.Window.unseen(): Boolean {
        val params = (owner as? Dialog)?.window?.attributes ?: return false
        return params.alpha <= 0f || params.width in 0..1 || params.height in 0..1
    }

    override fun dismissed(window: Ui.Window) {
        parked.remove(window)
        // A kept window its extension closed by itself: its Support button follows.
        kept.gone { it === window }?.let { plugin -> popups?.kept(plugin, kept.titles(plugin), null) }
        val gone = captured.firstOrNull { it.window === window } ?: return
        captured.remove(gone)
        Ui.changed()
        syncPages()
        MainThread.postDelayed({
            // A session ended elsewhere (replaced, a restart, a crash) is let go of here too, once its windows are gone.
            if (captured.none { it.session === gone.session }) end(gone.session, "closed")
        }, END_GRACE_MS)
    }

    /** After each main-thread task (MainThread.setAfterTask): a changed screen is read, at most every [READ_MS]. */
    fun afterTask() {
        if (!Ui.takeDirty() || screens.isEmpty()) return
        val wait = lastRead + READ_MS - System.currentTimeMillis()
        if (wait <= 0) {
            readAll()
        } else if (!readPosted) {
            readPosted = true
            MainThread.postDelayed({
                readPosted = false
                readAll()
            }, wait)
        }
    }

    private fun readAll() {
        lastRead = System.currentTimeMillis()
        for (screen in screens.values.toList()) snapshot(screen)
        syncPages()
    }

    /** Publishes [screen]'s windows, bottom to top, when they differ from the last read. */
    private fun snapshot(screen: Screen) {
        val session = screen.session
        if (session.ended) return
        val trees = captured.filter { it.session === session }.map { c ->
            val dialog = c.window.owner as? Dialog
            val fullScreen = dialog?.cs3FullScreen() == true
            screen.tree.window(
                "w${c.number}",
                c.window.kind,
                null,
                dialog?.cs3Cancelable() ?: true,
                c.window.root,
                null,
                fullScreen = fullScreen,
                keepScreenOn = dialog?.cs3KeepScreenOn() == true,
                // A game turns the activity before its window shows: an iPhone turns with it.
                orientation = if (fullScreen) orientation() else null,
            )
        }
        if (trees == screen.last) return
        screen.last = trees
        session.publish(trees)
    }

    /** Where [view] is on screen: its open screen's session and its node's number, or null when no open screen holds it. */
    fun locate(view: WebView): Pair<Int, Int>? {
        val window = captured.firstOrNull { !it.session.ended && (it.window.root === view || view.isWithin(it.window.root)) } ?: return null
        val screen = screenOf(window.session) ?: return null
        return window.session.id to screen.tree.ids.of(view)
    }

    /** Whether [view]'s window, in an open screen, asks for the whole screen (Phase 7c's §1). */
    fun isFullScreen(view: WebView): Boolean {
        val window = captured.firstOrNull { !it.session.ended && (it.window.root === view || view.isWithin(it.window.root)) } ?: return false
        return (window.window.owner as? Dialog)?.cs3FullScreen() == true
    }

    /** [view]'s extension: the plugin whose open screen holds its window, which its served folders are named for. */
    fun extensionOf(view: WebView): File? =
        captured.firstOrNull { !it.session.ended && (it.window.root === view || view.isWithin(it.window.root)) }?.session?.plugin

    /** Tells the pages which web views open screens hold now. */
    private fun syncPages() {
        val pages = pages ?: return
        val views = ArrayList<WebView>()
        fun collect(view: View) {
            if (view is WebView) views += view
            if (view is ViewGroup) for (i in 0 until view.childCount) view.getChildAt(i)?.let(::collect)
        }
        captured.filter { !it.session.ended }.forEach { collect(it.window.root) }
        pages.shown(views)
    }

    /** A window's extension: its fragment's, its dialog's own class's, else the extension whose code showed it. */
    private fun ownerOf(window: Ui.Window): File? =
        window.fragment?.let { pluginOf(it.javaClass) } ?: pluginOf(window.owner.javaClass) ?: pluginIn(window.shownFrom)

    /**
     * Closes [window] as Back does: its dialog's own key listener first (Phase 7c's §3), then the dialog cancels if it's
     * cancelable, after its own Back callbacks. [force]d, it's dismissed at once (a fragment's dialog through its
     * fragment, which then goes too).
     */
    private fun dismiss(window: Captured, force: Boolean) {
        val dialog = window.window.owner as? Dialog
        if (!force) {
            runCatching { dialog?.cs3Back() }
            return
        }
        forceOut(window.window)
    }

    /** Dismisses [window] at once; one that wouldn't go is let go of all the same. */
    private fun forceOut(window: Ui.Window) {
        val fragment = window.fragment as? DialogFragment
        if (fragment != null) runCatching { fragment.dismissAllowingStateLoss() } else runCatching { (window.owner as? Dialog)?.dismiss() }
        if (Ui.isShowing(window.root)) Ui.dismissed(window.owner)
    }

    private fun end(session: UiSession, reason: String) {
        if (screenOf(session) != null) screens.remove(session.plugin.absolutePath)
        captured.removeAll { it.session === session }
        syncPages()
        session.end(reason)
    }

    private fun screenOf(session: UiSession): Screen? = screens[session.plugin.absolutePath]?.takeIf { it.session === session }

    private fun View.isWithin(root: View): Boolean {
        var parent = this.parent
        while (parent is ViewGroup) {
            if (parent === root) return true
            parent = parent.parent
        }
        return false
    }

    private companion object {
        const val READ_MS = 50L
        const val END_GRACE_MS = 300L
        const val FORCE_AFTER_MS = 400L

        /** A kept window's title, at most: its first words. */
        const val TITLE_MAX = 80
    }
}
