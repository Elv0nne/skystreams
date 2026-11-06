package com.lingjhf.vlc_player

import kotlin.test.Test
import kotlin.test.assertEquals

internal class VlcReleaseDelayTest {
    @Test
    fun theDelayIsReadAndLeftOutOfLibVlcsOptions() {
        val delay = VlcReleaseDelay.from(listOf("--no-audio", "--vlc-player-release-delay-ms=6000", "--quiet"))
        assertEquals(6000L, delay.ms)
        assertEquals(listOf("--no-audio", "--quiet"), delay.libVlcOptions)
    }

    @Test
    fun noOptionMeansNoDelay() {
        val delay = VlcReleaseDelay.from(listOf("--no-audio"))
        assertEquals(0L, delay.ms)
        assertEquals(listOf("--no-audio"), delay.libVlcOptions)
    }

    @Test
    fun aValueThatIsNotACountMeansNoDelay() {
        assertEquals(0L, VlcReleaseDelay.from(listOf("--vlc-player-release-delay-ms=soon")).ms)
        assertEquals(0L, VlcReleaseDelay.from(listOf("--vlc-player-release-delay-ms=-5")).ms)
    }
}
