package dev.akash.cs3engine.host

import kotlinx.coroutines.Deferred
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The time that counts against an engine call's timeout: wall time, except while an extension
 * waits on the app's browser ([RemoteWebViewHost]). A slow hidden solve, or a person finishing a
 * check in the sheet, doesn't use up the call's own time (webview roadmap, Phase 1c: call clocks).
 *
 * One clock for the engine: while any extension waits, every call's clock stands still. Waits are
 * short and rare, so a call that happens to run beside another's wait gets a little longer.
 */
class BrokerClock(private val now: () -> Long = { System.nanoTime() / 1_000_000 }) {
    private var waiting = 0
    private var pausedSince = 0L
    private var pausedTotal = 0L

    /** An extension started waiting on the app's browser. */
    @Synchronized
    fun pause() {
        if (waiting++ == 0) pausedSince = now()
    }

    /** It stopped waiting. */
    @Synchronized
    fun resume() {
        if (waiting == 0) return
        if (--waiting == 0) pausedTotal += now() - pausedSince
    }

    /** Milliseconds of running time, from an arbitrary origin. */
    @Synchronized
    fun running(): Long = now() - pausedTotal - (if (waiting > 0) now() - pausedSince else 0L)

    /**
     * Waits for [call] for up to [timeoutMs] of running time, looking again at least every [checkMs] in case a wait began
     * or ended. While [standStill] holds (its extension's full-screen window shows: Phase 7c's §4), the call's own time
     * stands still too. True once it finished; false when the time ran out.
     */
    suspend fun await(call: Deferred<*>, timeoutMs: Long, checkMs: Long = 1_000, standStill: () -> Boolean = { false }): Boolean {
        var used = 0L
        var last = running()
        while (true) {
            val now = running()
            if (!standStill()) used += now - last
            last = now
            val left = timeoutMs - used
            if (left <= 0) return call.isCompleted
            withTimeoutOrNull(minOf(left, checkMs)) { call.join() }
            if (call.isCompleted) return true
        }
    }

    companion object {
        /** The engine's clock. */
        val shared = BrokerClock()
    }
}
