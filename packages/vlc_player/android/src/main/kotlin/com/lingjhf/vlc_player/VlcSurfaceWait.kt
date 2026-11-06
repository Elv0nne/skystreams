package com.lingjhf.vlc_player

/**
 * How long libvlc-android held playback back for its video surface.
 *
 * MediaPlayer.play() returns without starting while the views it was given
 * have no surface yet, and starts when the surface arrives (libvlc-android
 * 3.7.7 MediaPlayer.play, AWindow.areSurfacesWaiting). A TextureView gets its
 * surface at its first draw, which a busy main thread puts off: an open then
 * waits with the network idle. Reported so the app's QoE log can say how
 * often, and for how long, that happens on real devices.
 */
internal class VlcSurfaceWait(private val now: () -> Long) {
    private var askedAt: Long? = null

    /** The last wait, in milliseconds: 0 when the surface was there, null while one is pending. */
    var waitedMs: Long? = 0L
        private set

    fun playAsked(surfaceReady: Boolean) {
        waitedMs = if (surfaceReady) 0L else null
        askedAt = if (surfaceReady) null else now()
    }

    fun surfaceReady() {
        val asked = askedAt ?: return
        askedAt = null
        waitedMs = now() - asked
    }

    fun reset() {
        askedAt = null
        waitedMs = 0L
    }
}
