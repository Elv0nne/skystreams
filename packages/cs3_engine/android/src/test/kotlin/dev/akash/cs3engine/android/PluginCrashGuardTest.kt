package dev.akash.cs3engine.android

import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.host.RestartRequested
import org.junit.After
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

class PluginCrashGuardTest {
    private val heard = mutableListOf<Throwable>()
    private val logged = mutableListOf<String>()

    init {
        HostHooks.restartRequested = { heard += it }
        HostHooks.log = { logged += it }
    }

    @After
    fun reset() {
        HostHooks.restartRequested = {}
        HostHooks.log = { System.err.println("[cs3] $it") }
    }

    @Test
    fun `a restart reaching the main loop reloads the extension, wherever it came from`() {
        val restart = RestartRequested()
        assertTrue(PluginCrashGuard.handle(restart) { null })
        assertSame(restart, heard.single())
    }

    @Test
    fun `a restart its guard already reported reaches the main loop quietly`() {
        assertTrue(PluginCrashGuard.handle(RestartRequested().apply { reported = true }) { null })
        assertTrue(heard.isEmpty())
    }

    @Test
    fun `a plugin's crash is logged, survived and reported, and the app's own still crashes it`() {
        val crashes = mutableListOf<Throwable>()
        HostHooks.pluginCrashed = { crashes += it }
        try {
            val boom = IllegalStateException("boom")
            assertTrue(PluginCrashGuard.handle(boom) { "Test.cs3" })
            assertTrue(logged.single().startsWith("Test.cs3 crashed on the main thread"))
            assertSame(boom, crashes.single())
            assertFalse(PluginCrashGuard.handle(IllegalStateException("ours")) { null })
            assertEquals(0, heard.size)
        } finally {
            HostHooks.pluginCrashed = {}
        }
    }
}
