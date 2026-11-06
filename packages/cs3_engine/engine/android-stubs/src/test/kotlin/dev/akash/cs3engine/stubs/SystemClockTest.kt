package dev.akash.cs3engine.stubs

import android.os.SystemClock
import java.net.URLClassLoader
import kotlin.test.Test
import kotlin.test.assertTrue

class SystemClockTest {
    @Test
    fun `the clock counts from the device's start, as Android's does, not from its own first use`() {
        // Phase 7c part 1's second review: a clock counting from its class's first use read 0 for the first Back of an
        // engine run (Dialog.cs3Back is its first user), so a listener timing a double Back took it for the second.
        // A loader of its own, as in an engine that has just started: the class starts here.
        val classes = SystemClock::class.java.protectionDomain.codeSource.location
        URLClassLoader(arrayOf(classes), null).use { loader ->
            val uptime = loader.loadClass("android.os.SystemClock").getMethod("uptimeMillis").invoke(null) as Long
            assertTrue(uptime > 1_000, "uptimeMillis on its first use: $uptime")
        }
    }
}
