package com.lingjhf.vlc_player

/**
 * The copy of the last frame laid over the video for a hold, and how long it
 * outlives the hold.
 *
 * The hold itself is [VlcPictureHold]'s; this is only the view. Let go, the
 * copy stays a moment: the new player's first frame at its start can reach
 * the view a frame after libVLC's first time report. A new hold inside that
 * moment keeps the copy rather than copying the view again, which may by then
 * show the newer media's picture at 0 (P1 Part 2's whole-part review). Main
 * thread only.
 */
internal class VlcHeldOverlay<V : Any>(
    private val scheduler: Scheduler,
    private val remove: (V) -> Unit,
) {
    /** Where a removal waits: the main thread's handler, or a test's queue. */
    interface Scheduler {
        fun postDelayed(delayMs: Long, task: Runnable)
        fun cancel(task: Runnable)
    }

    private var view: V? = null
    private var removal: Runnable? = null

    /** Whether a copy is over the video: held, or let go and not yet removed. */
    val isUp: Boolean get() = view != null

    /** Whether the copy over the video is held: up, and not let go. */
    val isHeld: Boolean get() = view != null && removal == null

    /** The copy over the video, its removal called off; null when none is. */
    fun reuse(): V? {
        val current = view ?: return null
        removal?.let(scheduler::cancel)
        removal = null
        return current
    }

    /** A new copy, laid over the video. One still up goes at once. */
    fun hold(overlay: V) {
        releaseNow()
        view = overlay
    }

    /** Lets the copy go after [delayMs]: once, however often it is asked. */
    fun release(delayMs: Long) {
        val current = view ?: return
        if (removal != null) return
        val task = Runnable {
            removal = null
            if (view === current) view = null
            remove(current)
        }
        removal = task
        scheduler.postDelayed(delayMs, task)
    }

    /** Takes the copy away now: the view is going. */
    fun releaseNow() {
        removal?.let(scheduler::cancel)
        removal = null
        val current = view ?: return
        view = null
        remove(current)
    }
}
