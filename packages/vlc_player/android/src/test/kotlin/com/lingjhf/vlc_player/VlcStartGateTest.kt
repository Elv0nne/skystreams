package com.lingjhf.vlc_player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

internal class VlcStartGateTest {
    private val gate = VlcStartGate()

    @Test
    fun runsAtOnceWhileOpen() {
        var ran = 0
        gate.whenOpen { ran += 1 }
        assertEquals(1, ran)
    }

    @Test
    fun holdsWhileClosedAndRunsInOrderOnceOpened() {
        val order = mutableListOf<Int>()
        gate.close()
        gate.whenOpen { order += 1 }
        gate.whenOpen { order += 2 }
        assertEquals(emptyList(), order)

        gate.open()
        assertEquals(listOf(1, 2), order)
        gate.open()
        assertEquals(listOf(1, 2), order, "each waiting start runs once")
    }

    @Test
    fun runsAtOnceAgainAfterOpening() {
        gate.close()
        gate.open()
        var ran = false
        gate.whenOpen { ran = true }
        assertTrue(ran)
    }
}
