package com.lingjhf.vlc_player

/**
 * When the output keeps showing the last picture of the media before this
 * one: the Kotlin twin of src/native/vlc_picture_hold.h, where the reasons are.
 *
 * libVLC shows a new media's first decoded picture at once, and for a media
 * given a :start-time that is the picture at 0; a hold lasts until libVLC's
 * first time report after the new media's Opening. A media that stops, ends
 * or fails before then leaves it on, and the next arm or release decides.
 * Main thread only: events reach this plugin there.
 */
internal class VlcPictureHold {
    enum class Change { NONE, HOLD, RELEASE }

    private enum class Phase { OFF, AWAITING_OPENING, AWAITING_TIME }

    private var phase = Phase.OFF

    val held: Boolean get() = phase != Phase.OFF

    fun arm(keepPicture: Boolean, hasPicture: Boolean): Change {
        if (!keepPicture) {
            val wasHeld = held
            phase = Phase.OFF
            return if (wasHeld) Change.RELEASE else Change.NONE
        }
        if (held) {
            phase = Phase.AWAITING_OPENING
            return Change.NONE
        }
        if (!hasPicture) return Change.NONE
        phase = Phase.AWAITING_OPENING
        return Change.HOLD
    }

    fun onOpening() {
        if (phase == Phase.AWAITING_OPENING) phase = Phase.AWAITING_TIME
    }

    fun onTimeChanged(): Change = endIfOpened()

    /// A hold outlives the media going: see vlc_picture_hold.h.
    fun onMediaGone(): Change = Change.NONE

    fun release(): Change {
        val wasHeld = held
        phase = Phase.OFF
        return if (wasHeld) Change.RELEASE else Change.NONE
    }

    private fun endIfOpened(): Change {
        if (phase != Phase.AWAITING_TIME) return Change.NONE
        phase = Phase.OFF
        return Change.RELEASE
    }
}
