package dev.akash.cs3engine.ui

import dev.akash.cs3engine.host.BrokerClock
import dev.akash.cs3engine.host.RestartRequested
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Extension screens open in the app, one at a time (its sheet is modal): what the protocol's
 * `openSettings`, `openPopups`, `uiAction` and `closeUi` do, and the `ui`, `uiClosed` and `restartRequested`
 * events. It's also the spec's pop-up rules ([Popups]), which the platform asks about each window of an
 * extension with no screen open: shown in a screen of its own while the person waits on the extension (its
 * `load` or `loadLinks`, and [WAITING_GRACE_MS] after), a page as much as any window; else, in the background,
 * kept for the extension's Support button, a page only once [pageSortMs] have passed with no call of its
 * extension running (one still running waits on it: the page is dropped) (`uiOpened`, `popupDropped`,
 * `popupKept` and `popups`). While a screen the
 * person waits on is open, calls' clocks ([callClock]) stand still, as for the check sheet, for
 * [holdLimitMs] at most; while a window of an extension's that asks for the whole screen shows, the calls of that
 * extension the person waits on don't time out ([fullScreenShowing], Phase 7c's §4).
 */
class ExtensionUi(
    private val host: ExtensionUiHost?,
    private val emit: (type: String, fields: Map<String, Any?>) -> Unit,
    private val openTimeoutMs: Long = OPEN_TIMEOUT_MS,
    private val clock: () -> Long = System::currentTimeMillis,
    private val callClock: BrokerClock = BrokerClock.shared,
    private val holdLimitMs: Long = WAITING_HOLD_LIMIT_MS,
    private val pageSortMs: Long = PAGE_SORT_MS,
) : UiSession.Listener, Popups {
    private val nextId = AtomicInteger(1)
    private val sessions = ConcurrentHashMap<Int, UiSession>()
    private val shown = ConcurrentHashMap<Int, CompletableDeferred<Unit>>()
    private val errors = ConcurrentHashMap<Int, String>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val personCalls = ConcurrentHashMap<String, Int>()
    private val personEnded = ConcurrentHashMap<String, Long>()
    private val calls = ConcurrentHashMap<String, Int>()

    /** Screens the person waits on that hold calls' clocks still. */
    private val holding: MutableSet<Int> = ConcurrentHashMap.newKeySet()

    /** Extensions with a full-screen window showing now, by path, from what their screens published (Phase 7c's §4). */
    private val fullScreen: MutableSet<String> = ConcurrentHashMap.newKeySet()

    /** When each extension's full-screen window was last seen showing ([clock]). */
    private val fullScreenSeen = ConcurrentHashMap<String, Long>()

    // Last, once everything the rules use is set: the host can ask them from now on.
    init {
        host?.attach(this)
    }

    private fun host(): ExtensionUiHost =
        host ?: throw UnsupportedOperationException("extension screens aren't supported on this platform yet")

    /**
     * Opens [plugin]'s settings screen by calling [settings], and returns `{session}` once a window shows.
     * Fails when there's no screen, [settings] throws, or nothing shows within [openTimeoutMs] of the
     * main thread running what [settings] posted (a slow device takes seconds to get there).
     */
    suspend fun openSettings(plugin: File, settings: (() -> Unit)?): Map<String, Any?> {
        val host = host()
        settings ?: throw IllegalStateException("${plugin.name} has no settings screen")
        for (open in sessions.values.toList()) {
            // Ended first: the platform's own end, once the windows are gone, would say "closed".
            open.end("replaced")
            host.close(open, force = true)
        }
        val session = UiSession(nextId.getAndIncrement(), plugin, this)
        val first = CompletableDeferred<Unit>()
        sessions[session.id] = session
        shown[session.id] = first
        try {
            host.open(session, plugin, settings)
            withTimeoutOrNull(SETTLE_LIMIT_MS) { host.settled(session) }
            withTimeout(openTimeoutMs) { first.await() }
        } catch (e: TimeoutCancellationException) {
            session.end("nothing")
            host.close(session, force = true)
            throw IllegalStateException("${plugin.name} showed no settings screen")
        } catch (t: Throwable) {
            session.end("error")
            throw t
        } finally {
            shown.remove(session.id)
        }
        return mapOf("session" to session.id)
    }

    /** Applies the person's [action] to [node] of screen [id]. */
    suspend fun act(id: Int, node: Int, action: String, value: Any?): Map<String, Any?> {
        val host = host()
        val session = sessions[id] ?: throw IllegalArgumentException("no open screen $id")
        if (action !in UNCOUNTED) session.actions++
        try {
            host.act(session, node, action, value)
        } catch (e: RestartRequested) {
            if (!e.reported) restartRequested(session.plugin)
            return mapOf("restarted" to true)
        }
        return mapOf("done" to true)
    }

    /** Closes screen [id]'s windows; `uiClosed` follows once they're gone. */
    suspend fun close(id: Int, force: Boolean): Map<String, Any?> {
        val session = sessions[id] ?: return mapOf("closed" to false)
        host().close(session, force)
        return mapOf("closed" to true)
    }

    /** The screen [plugin] has open, if any. */
    fun sessionOf(plugin: File): Int? =
        sessions.values.firstOrNull { it.plugin.absolutePath == plugin.absolutePath && !it.ended }?.id

    /**
     * Runs [call], one the person waits on for [plugin] (a title opening, `load`, or its links, `loadLinks`): a
     * window the extension shows meanwhile, or within [WAITING_GRACE_MS] after, opens in the app (the check
     * sheet's rule, the owner, 2026-10-03).
     */
    suspend fun <T> personCall(plugin: File?, call: suspend () -> T): T {
        val key = plugin?.absolutePath ?: return call()
        personCalls.merge(key, 1, Int::plus)
        try {
            return call()
        } finally {
            // The end first, then the count: a window sorted in between still counts as waited for.
            personEnded[key] = clock()
            personCalls.compute(key) { _, running -> if (running == null || running <= 1) null else running - 1 }
        }
    }

    /** Whether the person waits on [plugin]: one of its [personCall]s runs, or one ended within [WAITING_GRACE_MS]. */
    fun personWaiting(plugin: File): Boolean {
        val key = plugin.absolutePath
        if ((personCalls[key] ?: 0) > 0) return true
        val ended = personEnded[key] ?: return false
        return clock() - ended <= WAITING_GRACE_MS
    }

    /**
     * Runs [call], any call of [plugin]'s (its home page, a search, a title, its links): a background page it shows
     * meanwhile is one it may wait on ([sortPage]).
     */
    suspend fun <T> call(plugin: File?, call: suspend () -> T): T {
        val key = plugin?.absolutePath ?: return call()
        calls.merge(key, 1, Int::plus)
        try {
            return call()
        } finally {
            calls.compute(key) { _, running -> if (running == null || running <= 1) null else running - 1 }
        }
    }

    /** Whether a call of [plugin]'s runs now ([call]). */
    fun callRunning(plugin: File): Boolean = (calls[plugin.absolutePath] ?: 0) > 0

    /** Now, by the clock the rules keep: what [fullScreenEndedWith] compares with. */
    fun now(): Long = clock()

    /** Whether a window of [plugin]'s that asks for the whole screen shows now: its person calls don't time out meanwhile. */
    fun fullScreenShowing(plugin: File): Boolean = plugin.absolutePath in fullScreen

    /**
     * Whether a links call of [plugin]'s that began at [since] ended with its full-screen window: one showed during it, and
     * still shows or went at most [withinMs] ago. A window that was the call itself (a game) goes as the call ends; one
     * the extension went on from (a check before its links) doesn't, and finding no links then is the person's to hear
     * (Phase 7c's §4; the owner's call, 2026-10-09). A window that went the moment the call began was the last call's.
     */
    fun fullScreenEndedWith(plugin: File, since: Long, withinMs: Long): Boolean {
        if (fullScreenShowing(plugin)) return true
        val seen = fullScreenSeen[plugin.absolutePath] ?: return false
        return seen > since && clock() - seen <= withinMs
    }

    override fun sort(plugin: File, holdsPage: Boolean, unseen: Boolean): Sorting {
        // One screen at a time: with another open, the window is the background's. So is one its extension made
        // invisible, the person waiting or not: Faselhd's link resolver and MyCima's cookie fetch show their scraper
        // page in a 1×1 dialog (the final review, 2026-10-07).
        if (!unseen && personWaiting(plugin) && sessions.values.none { !it.ended }) {
            val session = UiSession(nextId.getAndIncrement(), plugin, this)
            sessions[session.id] = session
            hold(session)
            emit("uiOpened", mapOf("session" to session.id, "plugin" to plugin.absolutePath, "why" to "waiting"))
            return Sorting.Show(session)
        }
        return if (holdsPage) Sorting.Later(pageSortMs) else Sorting.Keep
    }

    override fun sortPage(plugin: File): Sorting = if (callRunning(plugin)) Sorting.Drop else Sorting.Keep

    /** The person reads [session]: calls' clocks stand still until it ends, or [holdLimitMs] passes. */
    private fun hold(session: UiSession) {
        holding += session.id
        callClock.pause()
        scope.launch {
            delay(holdLimitMs)
            release(session.id)
        }
    }

    private fun release(id: Int) {
        if (holding.remove(id)) callClock.resume()
    }

    override fun kept(plugin: File, titles: List<String>, added: String?) {
        if (added != null) emit("popupKept", mapOf("plugin" to plugin.absolutePath, "title" to added))
        emit("popups", mapOf("plugin" to plugin.absolutePath, "titles" to titles))
    }

    override fun dropped(plugin: File, reason: String) = emit("popupDropped", mapOf("plugin" to plugin.absolutePath, "reason" to reason))

    override fun escaped(plugin: File, why: String) = emit("popupEscaped", mapOf("plugin" to plugin.absolutePath, "why" to why))

    /**
     * Opens [plugin]'s kept windows as a screen, as its Support button does, and returns `{session}` once they're
     * published. They're no longer kept while they show; closing one puts it back behind Support (the spec's §7).
     * Fails when it has none.
     */
    suspend fun openPopups(plugin: File): Map<String, Any?> {
        val host = host()
        for (open in sessions.values.toList()) {
            open.end("replaced")
            host.close(open, force = true)
        }
        val session = UiSession(nextId.getAndIncrement(), plugin, this)
        val first = CompletableDeferred<Unit>()
        sessions[session.id] = session
        shown[session.id] = first
        try {
            if (!host.openKept(session, plugin)) throw IllegalStateException("${plugin.name} has no pop-ups kept")
            withTimeout(openTimeoutMs) { first.await() }
        } catch (e: TimeoutCancellationException) {
            session.end("nothing")
            host.close(session, force = true)
            throw IllegalStateException("${plugin.name}'s pop-ups didn't show")
        } catch (t: Throwable) {
            session.end("error")
            throw t
        } finally {
            shown.remove(session.id)
        }
        return mapOf("session" to session.id)
    }

    /**
     * [plugin] asked to restart the app, which reloads it instead: the app hears `restartRequested`,
     * and its open screen ends with reason "restart".
     */
    fun restartRequested(plugin: File?) {
        plugin ?: return
        emit("restartRequested", mapOf("plugin" to plugin.absolutePath))
        for (session in sessions.values.filter { it.plugin.absolutePath == plugin.absolutePath }) {
            session.end("restart")
            scope.launch { runCatching { host?.close(session, force = true) } }
        }
    }

    /**
     * [plugin] is about to be unloaded (an update installed, a utility plugin run again, a reload) with
     * its screen open: the screen ends with reason "unloaded", and its windows close before the plugin's
     * classes go (on the desktops and iOS its class loader closes with it, and nothing could run them).
     */
    suspend fun pluginUnloaded(plugin: File) {
        for (session in sessions.values.filter { it.plugin.absolutePath == plugin.absolutePath }) {
            session.end("unloaded")
            withTimeoutOrNull(CLOSE_TIMEOUT_MS) { runCatching { host?.close(session, force = true) } }
        }
        // Its kept windows too: nothing must hold its classes once it's gone.
        withTimeoutOrNull(CLOSE_TIMEOUT_MS) { runCatching { host?.forgetKept(plugin) } }
    }

    /** [plugin]'s code crashed on the main thread: its open screen ends, with [message] for the app to show. */
    fun pluginCrashed(plugin: File?, message: String) {
        plugin ?: return
        for (session in sessions.values.filter { it.plugin.absolutePath == plugin.absolutePath }) {
            errors[session.id] = message
            session.end("error")
            scope.launch { runCatching { host?.close(session, force = true) } }
        }
    }

    override fun published(session: UiSession, windows: List<Map<String, Any?>>) {
        if (windows.isNotEmpty()) shown[session.id]?.complete(Unit)
        val key = session.plugin.absolutePath
        if (windows.any { it["fullScreen"] == true }) {
            fullScreen += key
            fullScreenSeen[key] = clock()
        } else if (fullScreen.remove(key)) {
            fullScreenSeen[key] = clock()
        }
        emit("ui", mapOf("session" to session.id, "plugin" to session.plugin.absolutePath, "windows" to windows))
    }

    override fun ended(session: UiSession, reason: String) {
        if (fullScreen.remove(session.plugin.absolutePath)) fullScreenSeen[session.plugin.absolutePath] = clock()
        release(session.id)
        sessions.remove(session.id)
        shown.remove(session.id)?.completeExceptionally(IllegalStateException("${session.plugin.name}'s screen closed at once"))
        val fields = mutableMapOf<String, Any?>(
            "session" to session.id,
            "plugin" to session.plugin.absolutePath,
            "reason" to reason,
            "actions" to session.actions,
        )
        errors.remove(session.id)?.let { fields["error"] = it }
        emit("uiClosed", fields)
    }

    override fun pageFocusLeft(session: UiSession, node: Int, direction: String) =
        emit("pageFocusExit", mapOf("session" to session.id, "node" to node, "direction" to direction))

    companion object {
        const val OPEN_TIMEOUT_MS = 3_000L

        /** Actions that aren't the person's changes: closing, and a page's focus (nothing to apply after). */
        private val UNCOUNTED = setOf("close", "focus", "blur")

        /** How long an unload waits for an open screen's windows to close. */
        const val CLOSE_TIMEOUT_MS = 3_000L

        /** The longest a main thread that never frees up holds the open timeout off. */
        const val SETTLE_LIMIT_MS = 30_000L

        /** How long after a call the person waits on a window still counts as theirs (the check sheet's rule). */
        const val WAITING_GRACE_MS = 5_000L

        /** The longest a screen the person waits on holds calls' clocks: a sheet left open doesn't stop every call timing out. */
        const val WAITING_HOLD_LIMIT_MS = 300_000L

        /** How long a background page is parked before it's sorted: its call has had time to end, or still waits on it. */
        const val PAGE_SORT_MS = 5_000L
    }
}
