package com.lingjhf.vlc_player

/**
 * Which player's video surface is on show, and when a replaced player's
 * surface may go: the decisions behind giving every player a surface of its
 * own (FORK.md 29). [P] is a player and [S] its surface - a VLCVideoLayout in
 * the platform view, plain values in the JVM tests. Main thread only: the
 * platform view applies the [Change]s it returns.
 *
 * libVLC 3's video output keeps its EGL window surface on its view's
 * SurfaceTexture until its player's stop() has returned, and a second output
 * can't connect to a BufferQueue the first still holds. A new player handed
 * the same view lost its hardware decoder whenever it asked for an output
 * first: "Opaque Vout request failed", then libvlc-android's
 * `:codec=mediacodec_ndk,all` fell back to software decoding for the media.
 *
 * - A new player's surface goes under the one on show, and comes to the front
 *   at its first picture: its first frame that [isPicture], or a moment after
 *   its first time report, whichever comes first. An output's first frame can
 *   be its black clear, and the time report comes about 0.4 s after the first
 *   picture.
 * - A replaced surface stays in the view until its player is released: until
 *   then its output may still draw into it. The one on show stays until a
 *   newer picture is up.
 */
internal class VlcSurfaceHandover<P : Any, S : Any> {
    sealed interface Change<out S> {
        /** Bring [surface] to the front, under the held picture. */
        data class Show<S>(val surface: S) : Change<S>

        /** Take [surface] out of the view. */
        data class Remove<S>(val surface: S) : Change<S>
    }

    private class Entry<P, S>(val player: P, val surface: S) {
        var released = false
    }

    /** Every surface in the view, oldest first. */
    private val entries = ArrayList<Entry<P, S>>()
    private var current: Entry<P, S>? = null
    private var shown: Entry<P, S>? = null
    private var disposed = false

    /** The surface on show: the newest whose player has had a picture. */
    val onShow: S? get() = if (disposed) null else shown?.surface

    /** The view's first player: nothing to cover, so its surface shows at once. */
    fun start(player: P, surface: S) {
        val entry = Entry(player, surface)
        entries += entry
        current = entry
        shown = entry
    }

    /** [retired] is replaced by [next], drawing into [surface] under the one on show. */
    fun replace(retired: P, next: P, surface: S) {
        check(current?.player === retired) { "only the current player is replaced" }
        val entry = Entry(next, surface)
        entries += entry
        current = entry
    }

    /** The current player's first picture is up: its surface comes to the front. */
    fun pictureUp(player: P): List<Change<S>> {
        val entry = current
        if (disposed || entry == null || entry.player !== player || shown === entry) return emptyList()
        shown = entry
        val changes = mutableListOf<Change<S>>(Change.Show(entry.surface))
        val iterator = entries.iterator()
        while (iterator.hasNext()) {
            val other = iterator.next()
            if (other !== entry && other.released) {
                iterator.remove()
                changes += Change.Remove(other.surface)
            }
        }
        return changes
    }

    /** [player] is released: its output has let go of its surface. */
    fun released(player: P): List<Change<S>> {
        if (disposed) return emptyList()
        val entry = entries.firstOrNull { it.player === player } ?: return emptyList()
        entry.released = true
        // The picture on show stays until a newer one is up, and the current
        // player's surface is the view's.
        if (entry === shown || entry === current) return emptyList()
        entries.remove(entry)
        return listOf(Change.Remove(entry.surface))
    }

    /** The view is gone, and its surfaces with it: nothing changes from here. */
    fun dispose() {
        disposed = true
        entries.clear()
        current = null
        shown = null
    }

    companion object {
        /**
         * Whether a small copy of a frame (ARGB pixels) shows a picture rather
         * than an output's black clear: its average luminance is at least 16
         * of 255. A letterboxed picture passes on its own rows; one too dark
         * to tell waits for the time report.
         */
        fun isPicture(argb: IntArray): Boolean {
            if (argb.isEmpty()) return false
            var sum = 0L
            for (pixel in argb) {
                val r = (pixel shr 16) and 0xff
                val g = (pixel shr 8) and 0xff
                val b = pixel and 0xff
                sum += (r * 299 + g * 587 + b * 114) / 1000
            }
            return sum / argb.size >= 16
        }
    }
}
