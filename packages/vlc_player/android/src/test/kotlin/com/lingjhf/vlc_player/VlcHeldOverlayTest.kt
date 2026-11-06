package com.lingjhf.vlc_player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class VlcHeldOverlayTest {
    /** The main thread's handler, run by hand. */
    private class Queue : VlcHeldOverlay.Scheduler {
        val waiting = mutableListOf<Pair<Long, Runnable>>()

        override fun postDelayed(delayMs: Long, task: Runnable) {
            waiting += delayMs to task
        }

        override fun cancel(task: Runnable) {
            waiting.removeAll { it.second === task }
        }

        fun runAll() {
            val due = waiting.toList()
            waiting.clear()
            due.forEach { it.second.run() }
        }
    }

    private val queue = Queue()
    private val removed = mutableListOf<String>()
    private val overlay = VlcHeldOverlay<String>(queue) { removed += it }

    @Test
    fun aLetGoCopyStaysItsDelayThenGoes() {
        overlay.hold("old")
        assertTrue(overlay.isHeld)
        overlay.release(120)
        assertTrue(overlay.isUp)
        assertFalse(overlay.isHeld)
        assertEquals(listOf(120L), queue.waiting.map { it.first })
        assertEquals(emptyList(), removed)

        queue.runAll()
        assertFalse(overlay.isUp)
        assertEquals(listOf("old"), removed)
    }

    @Test
    fun aHoldInsideTheDelayKeepsTheSameCopy() {
        overlay.hold("old")
        overlay.release(120)

        assertEquals("old", overlay.reuse())
        assertTrue(overlay.isHeld)
        assertEquals(emptyList(), queue.waiting, "its removal is called off")
        queue.runAll()
        assertTrue(overlay.isUp)
        assertEquals(emptyList(), removed)
    }

    @Test
    fun aHoldAfterTheDelayHasNothingToKeep() {
        overlay.hold("old")
        overlay.release(120)
        queue.runAll()
        assertNull(overlay.reuse())
    }

    @Test
    fun aSecondLetGoSchedulesNothingMore() {
        overlay.hold("old")
        overlay.release(120)
        overlay.release(120)
        assertEquals(1, queue.waiting.size)
    }

    @Test
    fun releaseNowTakesItAtOnceAndCallsOffAWaitingRemoval() {
        overlay.hold("old")
        overlay.release(120)
        overlay.releaseNow()
        assertFalse(overlay.isUp)
        assertEquals(listOf("old"), removed)
        assertEquals(emptyList(), queue.waiting)
    }

    @Test
    fun aNewCopyReplacesOneStillUp() {
        overlay.hold("old")
        overlay.hold("new")
        assertEquals(listOf("old"), removed)
        assertEquals("new", overlay.reuse())
    }
}
