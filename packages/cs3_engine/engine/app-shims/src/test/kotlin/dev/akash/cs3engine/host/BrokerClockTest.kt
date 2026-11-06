package dev.akash.cs3engine.host

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BrokerClockTest {
    @Test
    fun `time spent waiting on the app's browser is not running time`() {
        var now = 0L
        val clock = BrokerClock { now }
        now = 100
        assertEquals(100, clock.running())
        clock.pause()
        now = 600
        assertEquals(100, clock.running())
        // Two waits at once: the clock runs again only when both end.
        clock.pause()
        clock.resume()
        now = 700
        assertEquals(100, clock.running())
        clock.resume()
        now = 750
        assertEquals(150, clock.running())
        // An unmatched resume changes nothing.
        clock.resume()
        assertEquals(150, clock.running())
    }

    @Test
    fun `a call outlives its timeout while its extension waits on the browser`() = runBlocking {
        val clock = BrokerClock()
        val call = CompletableDeferred<Unit>()
        clock.pause()
        val finished = async { clock.await(call, timeoutMs = 200, checkMs = 20) }
        delay(500)
        call.complete(Unit)
        assertTrue(finished.await())
        clock.resume()
    }

    @Test
    fun `with no wait, the timeout holds`() = runBlocking {
        val clock = BrokerClock()
        assertFalse(clock.await(CompletableDeferred<Unit>(), timeoutMs = 100, checkMs = 20))
    }

    @Test
    fun `time before and after a wait counts`() = runBlocking {
        val clock = BrokerClock()
        val call = CompletableDeferred<Unit>()
        val finished = async { clock.await(call, timeoutMs = 300, checkMs = 20) }
        delay(200)
        clock.pause()
        delay(400)
        clock.resume()
        delay(250)
        // 450 ms ran in all: past the 300 allowed.
        assertFalse(finished.await())
    }

    @Test
    fun `a call's own time stands still while its extension's full-screen window shows, and runs again after`() = runBlocking {
        // Phase 7c's §4: a game left open doesn't end the Play call that opened it.
        val clock = BrokerClock()
        var fullScreen = true
        val finished = async { clock.await(CompletableDeferred<Unit>(), timeoutMs = 200, checkMs = 20, standStill = { fullScreen }) }
        delay(500)
        assertFalse(finished.isCompleted, "500 ms on, the window showing all along")
        fullScreen = false
        assertFalse(finished.await(), "once it's gone, its 200 ms run out")
    }
}
