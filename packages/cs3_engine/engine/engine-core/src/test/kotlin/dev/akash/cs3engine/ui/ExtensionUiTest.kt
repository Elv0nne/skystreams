package dev.akash.cs3engine.ui

import dev.akash.cs3engine.host.BrokerClock
import dev.akash.cs3engine.host.RestartRequested
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ExtensionUiTest {
    private val plugin = File("/plugins/Test.cs3")

    /** A platform whose extension shows one window as its screen opens, unless told otherwise. */
    private class FakeHost : ExtensionUiHost {
        var showsWindow = true

        /** Set: the window shows only once the main thread gets to it, this many ms on (a slow device). */
        var slowShowMs: Long? = null
        var throwOnAct: Throwable? = null
        val acted = mutableListOf<Triple<Int, String, Any?>>()
        val closed = mutableListOf<Pair<Int, Boolean>>()
        val sessions = mutableListOf<UiSession>()

        /** Kept windows by extension path, as many as Support should open. */
        val keptWindows = mutableMapOf<String, Int>()
        val forgotten = mutableListOf<File>()
        lateinit var popups: Popups

        override fun attach(popups: Popups) {
            this.popups = popups
        }

        override suspend fun openKept(session: UiSession, plugin: File): Boolean {
            val count = keptWindows.remove(plugin.absolutePath) ?: return false
            sessions += session
            session.publish((1..count).map { mapOf("id" to "w$it", "kind" to "dialog") })
            return true
        }

        override suspend fun forgetKept(plugin: File) {
            forgotten += plugin
        }

        override suspend fun open(session: UiSession, plugin: File, open: () -> Unit) {
            sessions += session
            open()
            if (showsWindow) session.publish(listOf(mapOf("id" to "w1", "kind" to "sheet")))
        }

        override suspend fun settled(session: UiSession) {
            val ms = slowShowMs ?: return
            delay(ms)
            session.publish(listOf(mapOf("id" to "w1", "kind" to "sheet")))
        }

        override suspend fun act(session: UiSession, node: Int, action: String, value: Any?) {
            throwOnAct?.let { throw it }
            acted += Triple(node, action, value)
        }

        override suspend fun close(session: UiSession, force: Boolean) {
            closed += session.id to force
            session.end("closed")
        }
    }

    private val events = mutableListOf<Pair<String, Map<String, Any?>>>()

    private fun ui(host: FakeHost) = ExtensionUi(host, { type, fields -> events += type to fields }, openTimeoutMs = 200)

    private fun named(type: String) = events.filter { it.first == type }.map { it.second }

    @Test
    fun `a screen opens once a window shows, and its windows go out as ui events`() = runBlocking {
        var opened = false
        val answer = ui(FakeHost()).openSettings(plugin) { opened = true }
        assertTrue(opened)
        assertEquals(mapOf("session" to 1), answer)
        val event = named("ui").single()
        assertEquals(1, event["session"])
        assertEquals(plugin.absolutePath, event["plugin"])
        assertEquals(listOf(mapOf("id" to "w1", "kind" to "sheet")), event["windows"])
    }

    @Test
    fun `a window a slow device shows late still opens the screen - the wait starts once posted work has run`() = runBlocking {
        val host = FakeHost().apply {
            showsWindow = false
            slowShowMs = 500
        }
        assertEquals(mapOf("session" to 1), ui(host).openSettings(plugin) {})
    }

    @Test
    fun `an extension without settings, or showing nothing, fails to open`() = runBlocking {
        val host = FakeHost()
        assertFailsWith<IllegalStateException> { ui(host).openSettings(plugin, null) }
        host.showsWindow = false
        val error = assertFailsWith<IllegalStateException> { ui(host).openSettings(plugin) {} }
        assertTrue("showed no settings screen" in error.message!!)
        assertEquals(listOf(1 to true), host.closed)
        assertEquals(listOf("nothing"), named("uiClosed").map { it["reason"] })
    }

    @Test
    fun `opening another screen closes the one open`() = runBlocking {
        val host = FakeHost()
        val ui = ui(host)
        ui.openSettings(plugin) {}
        ui.openSettings(File("/plugins/Other.cs3")) {}
        assertEquals(listOf(1 to true), host.closed)
        assertEquals(listOf(1 to "replaced"), named("uiClosed").map { it["session"] to it["reason"] })
    }

    @Test
    fun `actions reach the platform, and count unless they close`() = runBlocking {
        val host = FakeHost()
        val ui = ui(host)
        ui.openSettings(plugin) {}
        ui.act(1, 7, "check", true)
        ui.act(1, 3, "close", null)
        assertEquals(listOf<Triple<Int, String, Any?>>(Triple(7, "check", true), Triple(3, "close", null)), host.acted)
        assertEquals(1, host.sessions.single().actions)
        assertFailsWith<IllegalArgumentException> { ui.act(99, 1, "click", null) }
        Unit
    }

    @Test
    fun `an extension's restart during an action reloads it instead, and closes its screen`() = runBlocking {
        val host = FakeHost()
        val ui = ui(host)
        ui.openSettings(plugin) {}
        host.throwOnAct = RestartRequested()
        assertEquals(mapOf("restarted" to true), ui.act(1, 2, "click", null))
        assertEquals(plugin.absolutePath, named("restartRequested").single()["plugin"])
        assertEquals("restart", named("uiClosed").single()["reason"])
    }

    @Test
    fun `a restart its guard already reported isn't reported again`() = runBlocking {
        val host = FakeHost()
        val ui = ui(host)
        ui.openSettings(plugin) {}
        host.throwOnAct = RestartRequested().apply { reported = true }
        assertEquals(mapOf("restarted" to true), ui.act(1, 2, "click", null))
        assertTrue(named("restartRequested").isEmpty())
    }

    @Test
    fun `a restart caught outside an action closes that extension's screen too`() = runBlocking {
        val ui = ui(FakeHost())
        ui.openSettings(plugin) {}
        ui.restartRequested(plugin)
        assertEquals("restart", named("uiClosed").single()["reason"])
        ui.restartRequested(null)
        assertEquals(1, named("restartRequested").size)
    }

    @Test
    fun `the platform ending a screen reports how many actions it had`() = runBlocking {
        val host = FakeHost()
        val ui = ui(host)
        ui.openSettings(plugin) {}
        ui.act(1, 4, "click", null)
        host.sessions.single().end("closed")
        assertEquals(
            mapOf("session" to 1, "plugin" to plugin.absolutePath, "reason" to "closed", "actions" to 1),
            named("uiClosed").single(),
        )
    }

    @Test
    fun `an extension crashing on the main thread ends its screen, with the error`() = runBlocking {
        val ui = ui(FakeHost())
        ui.openSettings(plugin) {}
        ui.pluginCrashed(File("/plugins/Other.cs3"), "not this one")
        assertTrue(named("uiClosed").isEmpty())
        ui.pluginCrashed(plugin, "NullPointerException: views gone")
        val closed = named("uiClosed").single()
        assertEquals("error", closed["reason"])
        assertEquals("NullPointerException: views gone", closed["error"])
    }

    @Test
    fun `a restart is an Error, which a catch of Exception doesn't swallow`() {
        val caught = runCatching {
            try {
                throw RestartRequested()
            } catch (e: Exception) {
                "swallowed"
            }
        }
        assertTrue(caught.exceptionOrNull() is RestartRequested)
    }

    @Test
    fun `a window with no screen open is kept, a page is sorted again later, and the events say so`() {
        val host = FakeHost()
        ui(host)
        assertEquals(Sorting.Keep, host.popups.sort(plugin, holdsPage = false))
        assertEquals(Sorting.Later(ExtensionUi.PAGE_SORT_MS), host.popups.sort(plugin, holdsPage = true))
        host.popups.kept(plugin, listOf("Support us"), "Support us")
        host.popups.kept(plugin, emptyList(), null)
        host.popups.dropped(plugin, "page")
        host.popups.escaped(plugin, "thread")
        assertEquals(listOf(mapOf("plugin" to plugin.absolutePath, "title" to "Support us")), named("popupKept"))
        assertEquals(
            listOf(mapOf("plugin" to plugin.absolutePath, "titles" to listOf("Support us")), mapOf("plugin" to plugin.absolutePath, "titles" to emptyList<String>())),
            named("popups"),
        )
        assertEquals(listOf(mapOf("plugin" to plugin.absolutePath, "reason" to "page")), named("popupDropped"))
        assertEquals(listOf(mapOf("plugin" to plugin.absolutePath, "why" to "thread")), named("popupEscaped"))
        assertTrue(named("uiOpened").isEmpty())
    }

    @Test
    fun `while the person waits on an extension, and for 5 s after, its window opens a screen the app shows`() = runBlocking {
        var now = 1_000L
        val host = FakeHost()
        val ui = ExtensionUi(host, { type, fields -> events += type to fields }, openTimeoutMs = 200, clock = { now })
        val first = ui.personCall(plugin) { host.popups.sort(plugin, holdsPage = false) } as Sorting.Show
        assertEquals(listOf(mapOf("session" to first.session.id, "plugin" to plugin.absolutePath, "why" to "waiting")), named("uiOpened"))
        first.session.end("closed")
        now += ExtensionUi.WAITING_GRACE_MS
        val second = host.popups.sort(plugin, holdsPage = false) as Sorting.Show
        second.session.end("closed")
        now += 1
        assertEquals(Sorting.Keep, host.popups.sort(plugin, holdsPage = false), "after 5 s: the background's")
        assertEquals(Sorting.Keep, host.popups.sort(File("/plugins/Other.cs3"), holdsPage = false), "another extension: no one waits on it")
    }

    @Test
    fun `a call failing still ends the wait, and overlapping calls hold it until the last ends`() = runBlocking {
        var now = 1_000L
        val ui = ExtensionUi(FakeHost(), { _, _ -> }, clock = { now })
        assertFailsWith<IllegalStateException> { ui.personCall<Unit>(plugin) { error("no links") } }
        now += ExtensionUi.WAITING_GRACE_MS + 1
        assertTrue(!ui.personWaiting(plugin), "ended, and long ago")
        ui.personCall(plugin) {
            ui.personCall(plugin) {}
            now += ExtensionUi.WAITING_GRACE_MS + 1
            assertTrue(ui.personWaiting(plugin), "the outer call still runs")
        }
    }

    @Test
    fun `the person still waits at the instant their call ends - a window sorted then isn't kept`() = runBlocking {
        // A host sorts on its main thread while the call's own thread leaves personCall: the instant the end is
        // noted (the clock read) must still count as waiting, or the window goes behind Support.
        lateinit var ui: ExtensionUi
        var look = false
        val seen = mutableListOf<Boolean>()
        ui = ExtensionUi(FakeHost(), { _, _ -> }, clock = {
            if (look) {
                look = false
                seen += ui.personWaiting(plugin)
            }
            1_000L
        })
        ui.personCall(plugin) { look = true }
        assertEquals(listOf(true), seen)
    }

    @Test
    fun `a page while the person waits opens a screen, as the extension's other windows do`() = runBlocking {
        val host = FakeHost()
        val ui = ui(host)
        val shown = ui.personCall(plugin) { host.popups.sort(plugin, holdsPage = true) }
        assertTrue(shown is Sorting.Show, "the sheet draws pages now: $shown")
        assertEquals(1, named("uiOpened").size)
    }

    @Test
    fun `a window its extension made invisible isn't the person's, even while they wait - a page is sorted later, anything else kept`() = runBlocking {
        // Faselhd's link resolver and MyCima's cookie fetch show a 1×1 dialog holding their scraper page (the final review).
        val host = FakeHost()
        val ui = ui(host)
        ui.personCall(plugin) {
            assertEquals(Sorting.Later(ExtensionUi.PAGE_SORT_MS), host.popups.sort(plugin, holdsPage = true, unseen = true))
            assertEquals(Sorting.Keep, host.popups.sort(plugin, holdsPage = false, unseen = true))
        }
        assertTrue(named("uiOpened").isEmpty())
    }

    @Test
    fun `a background page is dropped while a call of its extension runs, the call waiting on it, else kept`() = runBlocking {
        val host = FakeHost()
        val ui = ui(host)
        ui.call(plugin) {
            assertEquals(Sorting.Drop, host.popups.sortPage(plugin), "its search still runs: a bot check it waits on")
            assertEquals(Sorting.Keep, host.popups.sortPage(File("/plugins/Other.cs3")), "another extension's calls aren't its")
        }
        assertEquals(Sorting.Keep, host.popups.sortPage(plugin), "no call of its runs: a promotion")
    }

    @Test
    fun `every call counts while it runs, a failing one too, and overlapping calls until the last ends`() = runBlocking {
        val ui = ui(FakeHost())
        assertFailsWith<IllegalStateException> { ui.call<Unit>(plugin) { error("no results") } }
        assertTrue(!ui.callRunning(plugin), "ended")
        ui.call(plugin) {
            ui.call(plugin) {}
            assertTrue(ui.callRunning(plugin), "the outer call still runs")
        }
        assertTrue(!ui.callRunning(plugin))
        assertEquals("plain", ui.call(null) { "plain" }, "no extension known: just run")
    }

    @Test
    fun `a page the person waits on while another screen is open is sorted later - one screen at a time`() = runBlocking {
        val host = FakeHost()
        val ui = ui(host)
        ui.openSettings(plugin) {}
        ui.personCall(plugin) { assertEquals(Sorting.Later(ExtensionUi.PAGE_SORT_MS), host.popups.sort(plugin, holdsPage = true)) }
    }

    @Test
    fun `while a screen the person waits on is open, calls' clocks stand still, for a while at most`() = runBlocking {
        var now = 0L
        val calls = BrokerClock { now }
        val host = FakeHost()
        val ui = ExtensionUi(host, { _, _ -> }, clock = { now }, callClock = calls, holdLimitMs = 500)
        val first = ui.personCall(plugin) { host.popups.sort(plugin, holdsPage = false) } as Sorting.Show
        now += 40_000
        assertEquals(0L, calls.running(), "the person reading the extension's window takes none of its call's time")
        first.session.end("closed")
        now += 1_000
        assertEquals(1_000L, calls.running())
        // A sheet left open holds them for the limit only.
        ui.personCall(plugin) { host.popups.sort(plugin, holdsPage = false) }
        delay(1_000)
        now += 1_000
        assertEquals(2_000L, calls.running())
    }

    @Test
    fun `a window the person waits on, while another screen is open, is kept - one screen at a time`() = runBlocking {
        // The Global Constraints' "one screen at a time".
        val host = FakeHost()
        val ui = ui(host)
        ui.openSettings(File("/plugins/Other.cs3")) {}
        ui.personCall(plugin) { assertEquals(Sorting.Keep, host.popups.sort(plugin, holdsPage = false)) }
    }

    @Test
    fun `Support opens the kept windows as a screen, and fails when there are none`() = runBlocking {
        val host = FakeHost()
        val ui = ui(host)
        host.keptWindows[plugin.absolutePath] = 2
        assertEquals(mapOf("session" to 1), ui.openPopups(plugin))
        assertEquals(2, (named("ui").last()["windows"] as List<*>).size)
        assertFailsWith<IllegalStateException> { ui.openPopups(plugin) }
        Unit
    }

    @Test
    fun `an extension unloading forgets its kept windows`() = runBlocking {
        // Review Focus 3.
        val host = FakeHost()
        ui(host).pluginUnloaded(plugin)
        assertEquals(listOf(plugin), host.forgotten)
    }

    @Test
    fun `a page's focus and blur reach the platform uncounted, and focus leaving it is told to the app`() = runBlocking {
        val host = FakeHost()
        val ui = ui(host)
        ui.openSettings(plugin) {}
        ui.act(1, 5, "focus", true)
        ui.act(1, 5, "blur", null)
        assertEquals(listOf<Triple<Int, String, Any?>>(Triple(5, "focus", true), Triple(5, "blur", null)), host.acted)
        assertEquals(0, host.sessions.single().actions)
        host.sessions.single().pageFocusLeft(5, "down")
        assertEquals(listOf(mapOf<String, Any?>("session" to 1, "node" to 5, "direction" to "down")), named("pageFocusExit"))
    }

    @Test
    fun `an extension's full-screen window is known while it shows, and when it last showed`() = runBlocking {
        // Phase 7c's §4: what the person's calls of that extension stand still for, and what ends a Play quietly.
        var now = 1_000L
        val host = FakeHost()
        val ui = ExtensionUi(host, { type, fields -> events += type to fields }, openTimeoutMs = 200, clock = { now })
        ui.openSettings(plugin) {}
        val open = host.sessions.single()
        assertFalse(ui.fullScreenShowing(plugin))
        now = 2_000
        open.publish(listOf(mapOf("id" to "w1", "kind" to "sheet"), mapOf("id" to "w2", "fullScreen" to true)))
        assertTrue(ui.fullScreenShowing(plugin))
        now = 3_000
        open.publish(listOf(mapOf("id" to "w1", "kind" to "sheet")))
        assertFalse(ui.fullScreenShowing(plugin))
        assertTrue(ui.fullScreenEndedWith(plugin, since = 2_500, withinMs = 1_000), "it showed until 3 000")
        assertFalse(ui.fullScreenEndedWith(plugin, since = 3_500, withinMs = 1_000))
        now = 4_000
        open.publish(listOf(mapOf("id" to "w2", "fullScreen" to true)))
        open.end("closed")
        assertFalse(ui.fullScreenShowing(plugin), "its screen ended")
        assertTrue(ui.fullScreenEndedWith(plugin, since = 3_900, withinMs = 1_000))
        assertFalse(ui.fullScreenShowing(File("/plugins/Other.cs3")))
    }

    @Test
    fun `a call ends with its full-screen window while one shows or just went - not once its extension went on`() = runBlocking {
        // The quiet end (Phase 7c's §4; the owner's call, 2026-10-09): a game is its call; a check before the links isn't.
        var now = 1_000L
        val host = FakeHost()
        val ui = ExtensionUi(host, { type, fields -> events += type to fields }, openTimeoutMs = 200, clock = { now })
        ui.openSettings(plugin) {}
        val open = host.sessions.single()
        assertFalse(ui.fullScreenEndedWith(plugin, since = 500, withinMs = 2_000), "none showed")
        now = 2_000
        open.publish(listOf(mapOf("id" to "w1", "fullScreen" to true)))
        assertTrue(ui.fullScreenEndedWith(plugin, since = 500, withinMs = 2_000), "one shows")
        now = 3_000
        open.publish(emptyList())
        assertFalse(ui.fullScreenEndedWith(plugin, since = 3_000, withinMs = 2_000), "it went as this call began: the last one's")
        now = 4_900
        assertTrue(ui.fullScreenEndedWith(plugin, since = 500, withinMs = 2_000), "gone 1.9 s before")
        now = 5_100
        assertFalse(ui.fullScreenEndedWith(plugin, since = 500, withinMs = 2_000), "gone 2.1 s before: the extension went on")
        assertFalse(ui.fullScreenEndedWith(plugin, since = 3_500, withinMs = 10_000), "not during this call")
    }
}
