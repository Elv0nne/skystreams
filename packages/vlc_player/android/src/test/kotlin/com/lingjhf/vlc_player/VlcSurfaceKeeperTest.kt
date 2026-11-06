package com.lingjhf.vlc_player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Surfaces as names; the released ones are listed in order. */
internal class VlcSurfaceKeeperTest {
    private val released = mutableListOf<String>()
    private val keeper = VlcSurfaceKeeper<String> { released += it }

    @Test
    fun aSurfaceTheViewLetsGoOfIsKeptUntilThePlayerHasStopped() {
        assertFalse(keeper.viewLetGo("st1"), "the view must not release it")
        assertEquals(emptyList(), released, "its output may still draw into it")
        keeper.playerStopped()
        assertEquals(listOf("st1"), released)
        keeper.playerStopped()
        assertEquals(listOf("st1"), released, "once")
    }

    @Test
    fun aSurfaceLetGoOfOnceThePlayerHasStoppedGoesWithTheView() {
        keeper.playerStopped()
        assertTrue(keeper.viewLetGo("st1"), "the view releases it")
        assertEquals(emptyList(), released)
    }

    @Test
    fun everySurfaceAViewLetGoOfIsKept() {
        // The view was taken away and put back: a new surface each time.
        keeper.viewLetGo("st1")
        keeper.viewLetGo("st2")
        keeper.playerStopped()
        assertEquals(listOf("st1", "st2"), released)
    }

    @Test
    fun aPlayerThatNeverStopsKeepsItsSurface() {
        keeper.viewLetGo("st1")
        assertEquals(emptyList(), released)
    }

    @Test
    fun libVlcHearsOfALostViewExceptWhileItsPlayerStops() {
        // libvlc-android's listener turns the video off at once, on the main
        // thread, behind the input lock a stop holds while it joins a read
        // that hangs: the app stopped responding (P1 Part 3).
        assertTrue(keeper.tellsLibVlc, "a playing player turns its video off")
        keeper.playerStopping()
        assertFalse(keeper.tellsLibVlc, "a stopping one would hold the main thread")
        keeper.playerStopped()
        assertTrue(keeper.tellsLibVlc, "a stopped one holds no lock")
    }
}
