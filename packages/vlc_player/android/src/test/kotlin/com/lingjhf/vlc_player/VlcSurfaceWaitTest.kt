package com.lingjhf.vlc_player

import kotlin.test.Test
import kotlin.test.assertEquals

internal class VlcSurfaceWaitTest {
    private var now = 0L
    private val wait = VlcSurfaceWait { now }

    @Test
    fun noWaitWhenTheSurfaceIsReadyAtPlay() {
        wait.playAsked(surfaceReady = true)
        now = 500
        wait.surfaceReady()
        // 0, not null: a key left out kept the last open's wait in Dart.
        assertEquals(0L, wait.waitedMs)
    }

    @Test
    fun theWaitRunsFromPlayToTheSurface() {
        now = 1000
        wait.playAsked(surfaceReady = false)
        now = 4200
        wait.surfaceReady()
        assertEquals(3200L, wait.waitedMs)
    }

    @Test
    fun aNewPlayStartsAgainAndAResetForgets() {
        now = 0
        wait.playAsked(surfaceReady = false)
        now = 100
        wait.surfaceReady()
        now = 200
        wait.playAsked(surfaceReady = true)
        assertEquals(0L, wait.waitedMs)
        wait.playAsked(surfaceReady = false)
        wait.reset()
        now = 900
        wait.surfaceReady()
        assertEquals(0L, wait.waitedMs)
    }
}
