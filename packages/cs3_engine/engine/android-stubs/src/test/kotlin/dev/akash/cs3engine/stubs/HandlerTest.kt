package dev.akash.cs3engine.stubs

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class HandlerTest {
    @Test
    fun `removeCallbacks stops a loop that posts itself again`() {
        // CloudflareSolver's poll, and StreamCenter's pulses: only removeCallbacks ends them.
        val handler = Handler(Looper.getMainLooper())
        val ran = AtomicInteger()
        val loop = object : Runnable {
            override fun run() {
                ran.incrementAndGet()
                handler.postDelayed(this, 10)
            }
        }
        onMain { handler.post(loop) }
        val until = System.currentTimeMillis() + 5_000
        while (ran.get() < 3 && System.currentTimeMillis() < until) Thread.sleep(5)
        onMain { handler.removeCallbacks(loop) }
        val stopped = ran.get()
        Thread.sleep(100)
        assertEquals(stopped, ran.get(), "the loop stopped")
    }

    @Test
    fun `a view's posts, a token's and what a handler holds can be taken back`() {
        val ran = AtomicBoolean()
        val view = View(Context())
        val mine = Runnable { ran.set(true) }
        view.postDelayed(mine, 50)
        assertTrue(view.removeCallbacks(mine))
        val handler = Handler()
        val token = Any()
        handler.postDelayed({ ran.set(true) }, token, 50)
        handler.removeCallbacksAndMessages(token)
        handler.postAtTime({ ran.set(true) }, SystemClock.uptimeMillis() + 50)
        handler.removeCallbacksAndMessages(null)
        Thread.sleep(150)
        assertFalse(ran.get(), "nothing taken back ran")
        val later = AtomicBoolean()
        handler.postAtTime({ later.set(true) }, SystemClock.uptimeMillis() + 20)
        Thread.sleep(150)
        assertTrue(later.get(), "postAtTime runs at its time")
    }
}
