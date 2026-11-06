package com.lingjhf.vlc_player

/**
 * A test hook: how long every player's release waits before its stop.
 *
 * A device test passes `--vlc-player-release-delay-ms=N` with the player's
 * options to hold a replaced player's video output on its surface for N ms,
 * as a slow or stuck stop does (FORK.md 29). It is read here and left out of
 * the options LibVLC gets, which would refuse an option it doesn't know.
 * Nothing else passes it.
 */
internal class VlcReleaseDelay private constructor(
    val ms: Long,
    val libVlcOptions: ArrayList<String>,
) {
    companion object {
        private const val OPTION = "--vlc-player-release-delay-ms="

        fun from(options: List<String>): VlcReleaseDelay {
            val rest = ArrayList<String>()
            var ms = 0L
            for (option in options) {
                if (option.startsWith(OPTION)) {
                    ms = option.removePrefix(OPTION).toLongOrNull()?.takeIf { it > 0 } ?: 0L
                } else {
                    rest.add(option)
                }
            }
            return VlcReleaseDelay(ms, rest)
        }
    }

    /** Waits the delay, on the releaser thread, before a stop. */
    fun beforeStop() {
        if (ms > 0) Thread.sleep(ms)
    }
}
