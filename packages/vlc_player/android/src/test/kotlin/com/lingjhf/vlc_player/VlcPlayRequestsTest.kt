package com.lingjhf.vlc_player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class VlcPlayRequestsTest {
    private val gate = VlcStartGate()
    private var heard = 0
    private val requests = VlcPlayRequests(gate) { heard += 1 }
    private val started = mutableListOf<String>()

    @Test
    fun startsAtOnceWhenTheGateIsOpen() {
        requests.request { started += "a" }
        assertEquals(listOf("a"), started)
    }

    @Test
    fun waitsForTheGate() {
        gate.close()
        requests.request { started += "a" }
        assertEquals(emptyList(), started)
        gate.open()
        assertEquals(listOf("a"), started)
    }

    @Test
    fun aPauseOrStopBeforeTheGateOpensDropsIt() {
        gate.close()
        requests.request { started += "a" }
        requests.cancel()
        gate.open()
        assertEquals(emptyList(), started)
    }

    @Test
    fun aNewerRequestReplacesAWaitingOne() {
        gate.close()
        requests.request { started += "a" }
        requests.request { started += "b" }
        gate.open()
        assertEquals(listOf("b"), started)
    }

    @Test
    fun saysWhileAPlayWaitsAtTheGate() {
        gate.close()
        requests.request { started += "a" }
        assertTrue(requests.waiting)
        assertEquals(1, heard)

        gate.open()
        assertFalse(requests.waiting)
        assertEquals(2, heard)
        assertEquals(listOf("a"), started)
    }

    @Test
    fun aPlayThatStartsAtOnceNeverWaits() {
        requests.request { started += "a" }
        assertFalse(requests.waiting)
        assertEquals(0, heard)
    }

    @Test
    fun aPauseOrStopWhileWaitingSaysItNoLongerWaits() {
        gate.close()
        requests.request { started += "a" }
        requests.cancel()
        assertFalse(requests.waiting)
        assertEquals(2, heard)

        gate.open()
        assertEquals(2, heard)
        assertEquals(emptyList(), started)
    }

    @Test
    fun aNewerRequestWaitsOnAndIsSaidOnce() {
        gate.close()
        requests.request { started += "a" }
        requests.request { started += "b" }
        assertTrue(requests.waiting)
        assertEquals(1, heard)

        gate.open()
        assertFalse(requests.waiting)
        assertEquals(2, heard)
        assertEquals(listOf("b"), started)
    }

    @Test
    fun itNoLongerWaitsByTheTimeThePlayStarts() {
        gate.close()
        var waitingAtStart: Boolean? = null
        requests.request { waitingAtStart = requests.waiting }
        gate.open()
        assertEquals(false, waitingAtStart)
    }
}
