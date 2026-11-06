package com.lingjhf.vlc_player

/**
 * Keeps a player's view surface alive past its view until the player has
 * stopped (FORK.md 29). [T] is a SurfaceTexture in the platform view, plain
 * values in the JVM tests. Main thread only.
 *
 * A TextureView releases its SurfaceTexture when it leaves the window, and
 * Flutter takes a platform view's view away before it disposes the view. A
 * video output that is still drawing - one whose input thread is stuck in a
 * read can neither turn its video off nor stop - then swaps into an abandoned
 * BufferQueue: `EGL_BAD_SURFACE` about 13 times a second until its player
 * stops, and on the emulator every other player's output waited behind it.
 * Kept, the surface takes the frames nobody sees, and goes once the player's
 * stop has returned.
 */
internal class VlcSurfaceKeeper<T : Any>(private val release: (T) -> Unit) {
    private val kept = ArrayList<T>()
    private var stopping = false
    private var stopped = false

    /**
     * Whether libvlc-android may hear that the view went. Its listener turns
     * the video off at once, on the main thread, and that waits for the input
     * lock a stopping player's stop holds while it joins an input stuck in a
     * read: 22 minutes after a network loss, with the app not responding
     * (P1 Part 3, the phone's offline row). A stopping player's views go
     * after its stop instead, when nothing waits.
     */
    val tellsLibVlc: Boolean
        get() = !stopping || stopped

    /** The player's stop has been asked for, on a thread of its own. */
    fun playerStopping() {
        stopping = true
    }

    /** The view let go of [surface]: true lets the view release it, false keeps it here. */
    fun viewLetGo(surface: T): Boolean {
        if (stopped) return true
        kept += surface
        return false
    }

    /** The player has stopped, and its output with it: what was kept goes now. */
    fun playerStopped() {
        stopped = true
        kept.forEach(release)
        kept.clear()
    }
}
