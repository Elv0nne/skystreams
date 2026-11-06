package dev.akash.cs3engine.android.ui

import android.content.res.Resources
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.WebView
import androidx.fragment.app.DialogFragment
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentManager
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
import kotlin.coroutines.resume

/**
 * Extension screens on Android. The windows an open screen's extension adds are kept invisible and
 * untouchable while their views stay live; they're read into trees for SkyStream's sheet and acted on
 * as a person would. Once the engine attaches its pop-up rules ([Popups]), a window of an extension with no
 * screen open is hidden as it's added too, then sorted on the main thread: shown in a screen of its own
 * while the person waits on the extension, else kept for the extension's Support button ([KeptWindows]), which
 * opens them ([openKept]) and gets them back when they close; a page only once no call of its extension waits on
 * it (one that does is cancelled as if closed). A page node's WebView is lent to the sheet's platform view while
 * it shows ([lendPage]), a stand-in keeping its slot. Main thread only: [open], [act] and [close] go there.
 */
internal class AndroidUiHost(
    private val owners: WindowOwners,
    private val main: Handler = Handler(Looper.getMainLooper()),
    /** An extension's own resources, when it has them loaded. */
    private val resourcesOf: (File) -> Resources? = { null },
) : ExtensionUiHost, WindowHook.Listener {
    private class Captured(
        val root: View,
        var params: WindowManager.LayoutParams,
        val session: UiSession,
        val number: Int,
        val kind: String,
        val owner: WindowOwners.Owner,
    ) {
        /** Set once it stayed on Back: it isn't cancelable (a plain dialog doesn't say beforehand). */
        var staysOnBack = false

        val cancelable get() = !staysOnBack && (owner.fragment?.isCancelable ?: true)
    }

    /**
     * [resources] are the extension's own, for the words its layouts left as raw references (UiTree). [support]:
     * Support opened it ([openKept]); closing it, or one of its windows, puts back what it took (the spec's §7).
     */
    private class Screen(val session: UiSession, resources: Resources?, val support: Boolean = false) {
        val tree = UiTree(NodeIds()) { id -> resources?.getText(id) }
        val ids get() = tree.ids
        var last: List<Map<String, Any?>>? = null

        /** The roots Support took from the kept windows: only these go back; one that joined meanwhile closes as anywhere. */
        val fromKept = HashSet<View>()
    }

    /** A window kept out of sight for its extension's Support button: still attached, hidden and inert. */
    private class Parked(val root: View, var params: WindowManager.LayoutParams, val owner: WindowOwners.Owner)

    private val captured = ArrayList<Captured>()
    private val screens = HashMap<String, Screen>()
    private val scheduled = HashSet<Int>()
    private var nextWindow = 1
    private val kept = KeptWindows<Parked>()

    /** Windows hidden as they were added, waiting for [sort]: one removed meanwhile is never sorted. */
    private val sorting = HashSet<View>()

    /** Background pages parked for their second sort ([Sorting.Later]), with their owner: one removed or forgotten meanwhile is never sorted. */
    private val parkedPages = HashMap<View, WindowOwners.Owner>()

    /** Pages lent to the sheet's platform views (the spec's §9), by WebView: where each goes back to. */
    private val lent = HashMap<WebView, PageSlot>()

    // Set once, as the engine starts (on its thread); read on the main thread.
    @Volatile
    private var popups: Popups? = null

    override fun attach(popups: Popups) {
        this.popups = popups
    }

    override suspend fun open(session: UiSession, plugin: File, open: () -> Unit) = withContext(Dispatchers.Main.immediate) {
        screens[plugin.absolutePath] = Screen(session, resourcesOf(plugin))
        try {
            open()
        } catch (t: Throwable) {
            screens.remove(plugin.absolutePath)
            throw t
        }
        poll(session)
    }

    /** Returns once the main thread has run what was posted before (the extension's dialog fragment's show). */
    override suspend fun settled(session: UiSession) = suspendCancellableCoroutine { done ->
        main.post { if (done.isActive) done.resume(Unit) }
    }

    override suspend fun act(session: UiSession, node: Int, action: String, value: Any?) = withContext(Dispatchers.Main.immediate) {
        val screen = screenOf(session) ?: throw IllegalStateException("screen ${session.id} is closed")
        val view = screen.ids.view(node) ?: throw IllegalArgumentException("node $node is gone")
        try {
            if (action == "focus" || action == "blur") {
                // A page's focus (Android's lent WebView): only once it's in the sheet.
                val container = (view as? WebView)?.parent as? ExtensionPageContainer ?: return@withContext
                if (action == "focus") container.focusPage(value != false) else container.blurPage()
                return@withContext
            }
            if (action == "close") {
                // A lent page sits in the sheet's view: its stand-in holds its place in the window.
                val inWindow = (view as? WebView)?.let { lent[it]?.standIn } ?: view
                val window = captured.lastOrNull { it.session === session && (it.root === inWindow || inWindow.isWithin(it.root)) }
                    ?: throw IllegalArgumentException("node $node is in no open window")
                if (screen.support && window.root in screen.fromKept) putBack(session, listOf(window)) else dismiss(window, force = value == "force")
            } else {
                UiActions.apply(view, action, value)
            }
        } finally {
            read(session)
            main.postDelayed({ read(session) }, SETTLE_MS)
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
        val back = if (screen?.support == true) windows.filter { it.root in screen.fromKept } else emptyList()
        if (back.isNotEmpty()) putBack(session, back)
        val rest = windows - back.toSet()
        if (rest.isEmpty()) return@withContext
        rest.forEach { dismiss(it, force) }
        if (!force) {
            main.postDelayed({ captured.filter { it.session === session }.asReversed().forEach { dismiss(it, force = true) } }, FORCE_AFTER_MS)
        }
    }

    override suspend fun openKept(session: UiSession, plugin: File): Boolean = withContext(Dispatchers.Main.immediate) {
        val windows = kept.take(plugin)
        popups?.kept(plugin, emptyList(), null)
        if (windows.isEmpty()) return@withContext false
        val screen = Screen(session, resourcesOf(plugin), support = true)
        screens[plugin.absolutePath] = screen
        // The oldest at the bottom, as they came; visible again (still hidden), so they're drawn and read.
        windows.asReversed().forEach {
            screen.fromKept += it.root
            it.root.visibility = View.VISIBLE
            take(it.root, it.params, session, it.owner)
        }
        poll(session)
        true
    }

    override suspend fun forgetKept(plugin: File) = withContext(Dispatchers.Main.immediate) {
        // Pages still waiting for their sort go too (the spec's §7): sorted later, they'd be kept for an extension that's gone.
        parkedPages.entries.filter { it.value.plugin.absolutePath == plugin.absolutePath }.forEach { (root, owner) ->
            parkedPages.remove(root)
            forceOut(root, owner)
        }
        val windows = kept.take(plugin)
        windows.forEach { forceOut(it.root, it.owner) }
        if (windows.isNotEmpty()) popups?.kept(plugin, emptyList(), null)
    }

    /**
     * Lends the page at [node] of screen [session] (the extension's WebView) to [container], a platform view in the
     * sheet: a stand-in takes its slot, so its window's tree keeps the page node. A page already lent moves from the
     * view it was in. False when the node is no page, or its screen is closed. Main thread.
     */
    fun lendPage(session: Int, node: Int, container: ViewGroup): Boolean {
        val screen = screens.values.firstOrNull { it.session.id == session && !it.session.ended } ?: return false
        val page = screen.ids.view(node) as? WebView ?: return false
        if (page !in lent) lent[page] = PageSlot.takeOut(page, session) ?: return false
        (page.parent as? ViewGroup)?.removeView(page)
        container.addView(page, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        return true
    }

    /** [container]'s platform view went: its page goes back to its slot, unless the extension emptied that. */
    fun returnPage(container: ViewGroup) {
        val page = container.getChildAt(0) as? WebView ?: return
        val slot = lent.remove(page) ?: return
        container.removeView(page)
        if (!slot.putBack()) Log.i("cs3", "a page's slot went while the sheet showed it: it's let go of")
    }

    /** Focus left the page lent to [container]: its screen tells the app. */
    fun pageFocusLeft(container: ViewGroup, direction: String) {
        val page = container.getChildAt(0) as? WebView ?: return
        val slot = lent[page] ?: return
        val screen = screens.values.firstOrNull { it.session.id == slot.session } ?: return
        screen.session.pageFocusLeft(screen.ids.of(page), direction)
    }

    override fun adding(root: View, params: WindowManager.LayoutParams) {
        // No pop-up rules yet (no engine) and no screen open: nothing to take in, and no owner lookup (a walk
        // of the stack) for the app's windows. With the rules on, each window added is looked up: SkyStream
        // itself adds few (its UI is Flutter's), and the walk skips the framework's and the app's frames.
        if (popups == null && screens.isEmpty()) return
        // The screens and the rules are the main thread's. Only an extension's window is told of: SkyStream's
        // own aren't the rules' to hold.
        if (Looper.myLooper() !== Looper.getMainLooper()) {
            val plugin = owners.onStack() ?: return
            Log.i("cs3", "${plugin.name}'s window added off the main thread shows as Android draws it")
            popups?.escaped(plugin, "thread")
            return
        }
        val owner = owners.ownerOf(root, params, ::capturedOwner)
        if (owner == null) {
            if (screens.isNotEmpty()) Log.i("cs3", "a window no extension owns shows as Android draws it, with a screen open")
            return
        }
        // An ended screen's extension (it restarted, or crashed) gets no new windows into it.
        val screen = screens[owner.plugin.absolutePath]?.takeUnless { it.session.ended }
        if (screen != null) {
            hide(root, params)
            take(root, params, screen.session, owner)
            return
        }
        val popups = popups
        if (popups == null) {
            Log.i("cs3", "${owner.plugin.name}'s window shows as Android draws it: no screen of its is open")
            return
        }
        // Hidden before it exists, then sorted once added, off WindowManagerGlobal's lock (the spec's pop-up rules).
        // Whether the extension made it invisible is read first: hiding sets its alpha.
        val unseen = params.alpha <= 0f || params.width in 0..1 || params.height in 0..1
        hide(root, params)
        sorting += root
        main.post { sort(root, params, owner, popups, unseen) }
    }

    private fun hide(root: View, params: WindowManager.LayoutParams) {
        Hiding.hide(params)
        root.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    }

    private fun take(root: View, params: WindowManager.LayoutParams, session: UiSession, owner: WindowOwners.Owner) {
        captured += Captured(root, params, session, nextWindow++, Kinds.of(root, params), owner)
        main.post { read(session) }
    }

    /** A window of [owner]'s extension with no screen of its open, once added. */
    private fun sort(
        root: View,
        params: WindowManager.LayoutParams,
        owner: WindowOwners.Owner,
        popups: Popups,
        unseen: Boolean,
    ) {
        if (!sorting.remove(root)) return
        val plugin = owner.plugin
        // Its screen opened meanwhile: it's that screen's.
        screens[plugin.absolutePath]?.takeUnless { it.session.ended }?.let { screen ->
            take(root, params, screen.session, owner)
            return
        }
        when (val sorted = popups.sort(plugin, root.holdsPage(), unseen)) {
            is Sorting.Show -> {
                screens[plugin.absolutePath] = Screen(sorted.session, resourcesOf(plugin))
                take(root, params, sorted.session, owner)
                poll(sorted.session)
            }
            Sorting.Drop -> drop(root, owner, popups)
            Sorting.Keep -> keep(root, params, owner, popups)
            is Sorting.Later -> {
                // Hidden still (alpha 0, untouchable): its page keeps loading while its call decides.
                parkedPages[root] = owner
                main.postDelayed({ sortPage(root, params, owner, popups) }, sorted.afterMs)
            }
        }
    }

    /** A background window holding a page, parked [Sorting.Later]: taken into its screen if one opened, else sorted again. */
    private fun sortPage(root: View, params: WindowManager.LayoutParams, owner: WindowOwners.Owner, popups: Popups) {
        if (parkedPages.remove(root) == null) return
        val plugin = owner.plugin
        screens[plugin.absolutePath]?.takeUnless { it.session.ended }?.let { screen ->
            take(root, params, screen.session, owner)
            return
        }
        if (popups.sortPage(plugin) == Sorting.Drop) drop(root, owner, popups) else keep(root, params, owner, popups)
    }

    /** A page a call of its extension waits on: cancelled as if closed, so the call goes on. */
    private fun drop(root: View, owner: WindowOwners.Owner, popups: Popups) {
        Log.i("cs3", "${owner.plugin.name}'s background window with a page in it, which a call waits on, closes, as if closed")
        cancel(root, owner)
        popups.dropped(owner.plugin, "page")
    }

    /** Kept out of sight for the extension's Support button, titled by its first words. */
    private fun keep(root: View, params: WindowManager.LayoutParams, owner: WindowOwners.Owner, popups: Popups) {
        val plugin = owner.plugin
        val words = UiTree(NodeIds()).wordsOf(root)
        val title = words.firstOrNull()?.take(TITLE_MAX) ?: plugin.nameWithoutExtension
        // Parked: gone, so it has no drawing surface while it waits (read before, as a tree skips it).
        root.visibility = View.GONE
        kept.keep(plugin, Parked(root, params, owner), title, words).forEach { forceOut(it.root, it.owner) }
        popups.kept(plugin, kept.titles(plugin), title)
    }

    /**
     * Puts Support's [windows] (top first) back behind its button, parked as they were kept (the spec's §7, the
     * owner 2026-10-08): the extension is never told they closed, so Support opens them again. A page of theirs
     * lent to the sheet goes back to its slot first. The screen ends once none is left.
     */
    private fun putBack(session: UiSession, windows: List<Captured>) {
        val plugin = session.plugin
        for (window in windows) {
            captured.remove(window)
            lent.values.filter { it.standIn.isWithin(window.root) }.forEach { slot ->
                (slot.page.parent as? ViewGroup)?.removeView(slot.page)
                lent.remove(slot.page)
                slot.putBack()
            }
            // Read before it's gone, as a tree skips it.
            val words = UiTree(NodeIds()).wordsOf(window.root)
            val title = words.firstOrNull()?.take(TITLE_MAX) ?: plugin.nameWithoutExtension
            window.root.visibility = View.GONE
            kept.putBack(plugin, Parked(window.root, window.params, window.owner), title, words).forEach { forceOut(it.root, it.owner) }
        }
        popups?.kept(plugin, kept.titles(plugin), null)
        if (captured.none { it.session === session }) end(session, "closed") else read(session)
    }

    private fun View.holdsPage(): Boolean =
        this is android.webkit.WebView || (this is ViewGroup && (0 until childCount).any { getChildAt(it).holdsPage() })

    /** Closes a window as the person would: its dialog cancels (its extension hears it), else it goes at once. */
    private fun cancel(root: View, owner: WindowOwners.Owner) {
        val dialog = owner.fragment?.dialog ?: Dialogs.of(root)
        if (dialog != null) runCatching { dialog.cancel() } else forceOut(root, owner)
    }

    /** Dismisses a window at once: its fragment, else its dialog, else the window itself. */
    private fun forceOut(root: View, owner: WindowOwners.Owner) {
        val fragment = owner.fragment
        val dialog = Dialogs.of(root)
        when {
            fragment != null -> runCatching { fragment.dismissAllowingStateLoss() }
            dialog != null -> runCatching { dialog.dismiss() }
            else -> runCatching { root.context.getSystemService(WindowManager::class.java).removeViewImmediate(root) }
        }
    }

    override fun updating(root: View, params: WindowManager.LayoutParams) {
        // An extension making its window visible or focusable again (for a field, say) would show it, or take
        // SkyStream's keyboard: hidden again, whether it's a screen's, waiting to be sorted, or kept.
        captured.firstOrNull { it.root === root }?.let { window ->
            Hiding.hide(params)
            window.params = params
            return
        }
        if (root in sorting) Hiding.hide(params)
        if (root in parkedPages) Hiding.hide(params)
        kept.find { it.root === root }?.let { parked ->
            Hiding.hide(params)
            parked.params = params
        }
    }

    override fun removed(root: View) {
        sorting.remove(root)
        parkedPages.remove(root)
        // A kept window its extension closed by itself: its Support button follows, told off the window lock.
        kept.gone { it.root === root }?.let { plugin -> main.post { popups?.kept(plugin, kept.titles(plugin), null) } }
        val gone = captured.firstOrNull { it.root === root } ?: return
        captured.remove(gone)
        main.postDelayed({
            // A session ended elsewhere (replaced, a restart, a crash) is let go of here too, once its windows are gone.
            if (captured.none { it.session === gone.session }) end(gone.session, "closed") else read(gone.session)
        }, END_GRACE_MS)
    }

    /**
     * Without the window hook (a future Android that blocks it), [activity]'s DialogFragments are still
     * hidden: each one an open screen's extension starts is hidden and taken in from its start, before its
     * first frame. Plain dialogs then show as Android draws them.
     */
    fun watchFragments(activity: FragmentActivity) {
        activity.supportFragmentManager.registerFragmentLifecycleCallbacks(
            object : FragmentManager.FragmentLifecycleCallbacks() {
                override fun onFragmentStarted(fm: FragmentManager, f: Fragment) {
                    val window = (f as? DialogFragment)?.dialog?.window ?: return
                    val root = window.decorView
                    // Started again (the app came back from the background): taken in, being sorted, or kept
                    // already. A kept one sorted again would replace itself, its same words dismissing it.
                    if (captured.any { it.root === root } || root in sorting || root in parkedPages || kept.find { it.root === root } != null) return
                    val params = window.attributes
                    adding(root, params)
                    // Taken in, or hidden to be sorted: it takes the hidden parameters before its first frame.
                    if (!Hiding.isHidden(params)) return
                    // The window exists already; it takes the hidden parameters before its first frame.
                    window.attributes = params
                    // By the fragment's own callbacks its dialog is gone (onDestroyView clears it): the
                    // window's removal says it closed.
                    root.addOnAttachStateChangeListener(
                        object : View.OnAttachStateChangeListener {
                            override fun onViewAttachedToWindow(view: View) = Unit

                            override fun onViewDetachedFromWindow(view: View) {
                                view.removeOnAttachStateChangeListener(this)
                                removed(view)
                            }
                        },
                    )
                }
            },
            true,
        )
    }

    private fun capturedOwner(token: IBinder?): File? =
        token?.let { t -> captured.firstOrNull { it.root.windowToken === t }?.session?.plugin }

    private fun screenOf(session: UiSession): Screen? = screens[session.plugin.absolutePath]?.takeIf { it.session === session }

    /** Reads [session]'s windows in [READ_MS], once however often it's asked meanwhile. */
    private fun read(session: UiSession) {
        if (session.ended || !scheduled.add(session.id)) return
        main.postDelayed({
            scheduled.remove(session.id)
            snapshot(session)
        }, READ_MS)
    }

    /** Reads every [POLL_MS] while the screen is open: an extension changes it by itself too (loads, timers). */
    private fun poll(session: UiSession) {
        if (session.ended || screenOf(session) == null) return
        read(session)
        main.postDelayed({ poll(session) }, POLL_MS)
    }

    private fun snapshot(session: UiSession) {
        val screen = screenOf(session) ?: return
        val windows = captured.filter { it.session === session }
        // Lists grow to hold every item; they're read once laid out again.
        if (windows.fold(false) { changed, w -> Lists.makeTall(w.root) || changed }) {
            read(session)
            return
        }
        val trees = windows.map { w ->
            screen.tree.window(
                "w${w.number}",
                w.kind,
                null,
                w.cancelable,
                w.root,
                Hiding.isHidden(w.params),
                fullScreen = w.params.flags and WindowManager.LayoutParams.FLAG_FULLSCREEN != 0,
                keepScreenOn = w.params.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0,
            )
        }
        if (trees == screen.last) return
        screen.last = trees
        session.publish(trees)
    }

    /**
     * Closes [window] as Back does, or [force]d out at once. Back goes to the window's dialog itself: its own key listener
     * first (Phase 7c's §3), then the dialog, which closes only if it's cancelable (as a key it would reach no dialog under
     * Android 16's predictive back). A window still there once Back has settled isn't cancelable, and is published so,
     * unless its key listener took Back. Forced, a dialog's window is dismissed through its dialog, so its extension hears
     * it (a game's Play call ends); only one that stays is removed outright.
     */
    private fun dismiss(window: Captured, force: Boolean) {
        val fragment = window.owner.fragment
        if (force) {
            if (fragment != null) {
                runCatching { fragment.dismissAllowingStateLoss() }
            } else {
                Dialogs.of(window.root)?.let { runCatching { it.dismiss() } }
                if (window.root.isAttachedToWindow) {
                    runCatching { window.root.context.getSystemService(WindowManager::class.java).removeViewImmediate(window.root) }
                }
            }
            return
        }
        val dialog = fragment?.dialog ?: Dialogs.of(window.root)
        if (dialog != null && Dialogs.keyBack(dialog)) return
        when {
            dialog != null -> @Suppress("DEPRECATION") dialog.onBackPressed()
            fragment != null -> if (fragment.isCancelable) fragment.dismissAllowingStateLoss()
            else -> {
                // Not a dialog's (a popup, a window of its own): its views take Back as a key.
                val (down, up) = Dialogs.backKeys()
                window.root.dispatchKeyEvent(down)
                window.root.dispatchKeyEvent(up)
            }
        }
        main.postDelayed({
            if (window in captured && window.root.isAttachedToWindow && !window.staysOnBack) {
                window.staysOnBack = true
                read(window.session)
            }
        }, SETTLE_MS)
    }

    private fun end(session: UiSession, reason: String) {
        if (screenOf(session) != null) screens.remove(session.plugin.absolutePath)
        captured.removeAll { it.session === session }
        // Its pages' views go with the sheet: anything still lent goes back now.
        lent.values.filter { it.session == session.id }.forEach { slot ->
            (slot.page.parent as? ViewGroup)?.removeView(slot.page)
            lent.remove(slot.page)
            slot.putBack()
        }
        session.end(reason)
    }

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
        const val SETTLE_MS = 300L
        const val POLL_MS = 500L
        const val END_GRACE_MS = 300L
        const val FORCE_AFTER_MS = 400L

        /** A kept window's title, at most: its first words. */
        const val TITLE_MAX = 80
    }
}
