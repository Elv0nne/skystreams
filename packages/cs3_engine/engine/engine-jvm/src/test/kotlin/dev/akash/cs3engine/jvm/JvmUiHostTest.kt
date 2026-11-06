package dev.akash.cs3engine.jvm

import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.view.KeyEvent
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import android.webkit.WebView
import com.lagradost.cloudstream3.CommonActivity
import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.stubs.MainThread
import dev.akash.cs3engine.stubs.Platform
import dev.akash.cs3engine.stubs.Ui
import dev.akash.cs3engine.ui.ExtensionUi
import kotlinx.coroutines.runBlocking
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class JvmUiHostTest {
    private val plugin = File("/plugins/Test.cs3")
    private val events = CopyOnWriteArrayList<Pair<String, Map<String, Any?>>>()
    // Every window here is the test extension's, by the code on the stack.
    private val host = JvmUiHost(pluginOf = { null }, pluginIn = { plugin })
    // A short page sort: long enough for a screen to open before it, in the last page test.
    private val ui = ExtensionUi(host, emit = { type, fields -> events += type to fields }, pageSortMs = 300)

    @BeforeTest
    fun wire() {
        Ui.setListener(host)
        MainThread.setAfterTask(host::afterTask)
    }

    @AfterTest
    fun unwire() {
        Ui.setListener(null)
        MainThread.setAfterTask(null)
        Platform.install(null)
        HostHooks.pluginCrashed = {}
        Ui.windows().forEach { Ui.dismissed(it.owner) }
    }

    /** Opens the extension's screen, which [show] shows; returns its session. */
    private fun open(show: () -> Unit): Int = runBlocking { ui.openSettings(plugin, show) }["session"] as Int

    @Suppress("UNCHECKED_CAST")
    private fun nodes(node: Map<String, Any?>): List<Map<String, Any?>> =
        listOf(node) + ((node["children"] as? List<Map<String, Any?>>)?.flatMap(::nodes) ?: emptyList())

    @Suppress("UNCHECKED_CAST")
    private fun windowsOf(event: Map<String, Any?>) = event["windows"] as List<Map<String, Any?>>

    @Suppress("UNCHECKED_CAST")
    private fun all(windows: List<Map<String, Any?>>) = windows.flatMap { nodes(it["root"] as Map<String, Any?>) }

    private fun texts(windows: List<Map<String, Any?>>) = all(windows).mapNotNull { it["text"] as String? }

    /** The latest event [test] accepts, waited for up to 5 s. */
    private fun await(test: (Pair<String, Map<String, Any?>>) -> Boolean): Map<String, Any?> {
        val until = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < until) {
            events.lastOrNull(test)?.let { return it.second }
            Thread.sleep(10)
        }
        error("no such event in $events")
    }

    /** [session]'s windows, from its latest ui event, once [test] accepts them. */
    private fun windows(session: Int, test: (List<Map<String, Any?>>) -> Boolean) =
        windowsOf(await { it.first == "ui" && it.second["session"] == session && test(windowsOf(it.second)) })

    private fun closed(session: Int, reason: String) =
        await { it.first == "uiClosed" && it.second["session"] == session && it.second["reason"] == reason }

    private fun dialog(words: String): Dialog =
        Dialog(Context()).apply { setContentView(TextView(context).apply { text = words }) }.also { it.show() }

    @Suppress("UNCHECKED_CAST")
    private fun kept(titles: List<String>) = await { it.first == "popups" && it.second["titles"] as List<String> == titles }

    /** Waits until the latest `popups` event says [titles]. */
    private fun keptNow(titles: List<String>) {
        val until = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < until) {
            if (events.lastOrNull { it.first == "popups" }?.second?.get("titles") == titles) return
            Thread.sleep(10)
        }
        error("Support's titles are ${events.lastOrNull { it.first == "popups" }}, not $titles")
    }

    @Test
    fun `a dialog an open screen's extension shows is read into its screen, and read again when it changes`() {
        lateinit var words: TextView
        val session = open {
            Dialog(Context()).apply { setContentView(TextView(context).apply { text = "Before"; words = this }) }.show()
        }
        assertEquals("dialog", windows(session) { texts(it) == listOf("Before") }.single()["kind"])
        onMain { words.text = "After" }
        windows(session) { texts(it) == listOf("After") }
    }

    @Test
    fun `a dialog shown from another thread is read on the main thread`() {
        // Review Focus 3: an extension changing its views off cs3-main.
        val readOn = CopyOnWriteArrayList<String>()
        val watching = AtomicBoolean()
        val session = open {
            thread {
                val dialog = Dialog(Context())
                dialog.setContentView(
                    object : TextView(dialog.context) {
                        override fun getText(): CharSequence {
                            if (watching.get()) readOn += Thread.currentThread().name
                            return super.getText()
                        }
                    }.apply { text = "From afar" },
                )
                watching.set(true)
                dialog.show()
            }
        }
        windows(session) { texts(it) == listOf("From afar") }
        assertTrue(readOn.isNotEmpty() && readOn.all { it == "cs3-main" }, "read on $readOn")
    }

    @Test
    fun `an ended session's windows are dismissed, and its extension's later windows ignored`() {
        // Review Focus 4: the screen's extension restarts (or crashes) with its windows open.
        lateinit var mine: Dialog
        val session = open {
            mine = Dialog(Context()).apply { setContentView(TextView(context).apply { text = "Mine" }) }
            mine.show()
        }
        windows(session) { texts(it) == listOf("Mine") }
        ui.restartRequested(plugin)
        closed(session, "restart")
        val until = System.currentTimeMillis() + 5_000
        while (mine.isShowing && System.currentTimeMillis() < until) Thread.sleep(10)
        assertFalse(mine.isShowing, "its window was dismissed")
        val later = onMain { Dialog(Context()).apply { setContentView(TextView(context).apply { text = "Later" }) }.also { it.show() } }
        drainMain()
        Thread.sleep(100)
        assertTrue(events.none { it.first == "ui" && "Later" in texts(windowsOf(it.second)) }, "no screen of its is open")
        onMain { later.dismiss() }
    }

    /** A dialog holding a page, as an extension's own bot check or promotion; [cancelled] hears it closed as by the person. */
    private fun pageDialog(cancelled: AtomicBoolean = AtomicBoolean()): Dialog = onMain {
        Dialog(Context()).apply {
            setContentView(LinearLayout(context).apply { addView(WebView(context)) })
            setOnCancelListener { cancelled.set(true) }
        }.also { it.show() }
    }

    @Test
    fun `a background page a call of its extension still waits on closes as if closed, after its sort`() = runBlocking {
        val cancelled = AtomicBoolean()
        ui.call(plugin) {
            val page = pageDialog(cancelled)
            await { it.first == "popupDropped" && it.second["reason"] == "page" }
            assertTrue(cancelled.get(), "the page's window closed as the person closes it")
            assertFalse(onMain { page.isShowing })
        }
        assertTrue(events.none { it.first == "popupKept" || it.first == "uiOpened" })
    }

    @Test
    fun `a background page no call waits on is a promotion, kept for Support, and a plain window is kept at once`() {
        val promo = onMain { dialog("Support us") }
        kept(listOf("Support us"))
        val page = pageDialog()
        kept(listOf(plugin.nameWithoutExtension, "Support us"))
        assertTrue(onMain { page.isShowing && promo.isShowing }, "kept: still the extension's, unseen")
        assertTrue(events.none { it.first == "popupDropped" || it.first == "ui" || it.first == "uiOpened" })
        onMain {
            page.dismiss()
            promo.dismiss()
        }
    }

    @Test
    fun `a page window while the person waits on its extension opens a screen of its own, page and all`() = runBlocking {
        ui.personCall(plugin) {
            pageDialog()
            val session = await { it.first == "uiOpened" }["session"] as Int
            assertTrue(all(windows(session) { it.size == 1 }).any { it["kind"] == "page" }, "the page is in the screen")
            ui.close(session, force = true)
        }
        Unit
    }

    @Test
    fun `a page window its extension made invisible isn't the person's while they wait - it's sorted as the background's`() = runBlocking {
        // Faselhd's link resolver and MyCima's cookie fetch size their dialog 1×1 (the final review); alpha 0 hides one too.
        val tiny = AtomicBoolean()
        val clear = AtomicBoolean()
        // Its links, as the engine runs them: a call the person waits on.
        ui.call(plugin) {
            ui.personCall(plugin) {
                onMain {
                    pageDialog(tiny).window!!.apply {
                        attributes.width = 1
                        attributes.height = 1
                        setAttributes(attributes)
                    }
                    pageDialog(clear).window!!.setAttributes(WindowManager.LayoutParams().apply { alpha = 0f })
                }
                await { it.first == "popupDropped" && events.count { e -> e.first == "popupDropped" } == 2 }
            }
        }
        assertTrue(tiny.get() && clear.get(), "both closed as background bot checks")
        assertTrue(events.none { it.first == "uiOpened" }, "no screen for pages no one can see")
    }

    @Test
    fun `a parked page closed by its extension before it's sorted leaves nothing`() {
        val page = pageDialog()
        onMain { page.dismiss() }
        Thread.sleep(500)
        drainMain()
        assertTrue(events.none { it.first == "popupKept" || it.first == "popups" || it.first == "popupDropped" })
    }

    @Test
    fun `a parked page whose extension's screen opened meanwhile goes into that screen`() {
        val page = pageDialog()
        val session = open { dialog("Settings") }
        val joined = windows(session) { it.size == 2 }
        assertTrue(all(joined).any { it["kind"] == "page" }, "the page joined the screen")
        assertTrue(events.none { it.first == "popupKept" || it.first == "popupDropped" })
        runBlocking { ui.close(session, force = true) }
        onMain { page.dismiss() }
    }

    @Test
    fun `Back closes a window, and one that stays is forced out after a moment, ending the screen`() {
        lateinit var stubborn: Dialog
        val session = open {
            stubborn = Dialog(Context()).apply {
                setCancelable(false)
                setContentView(TextView(context).apply { text = "Stay" })
            }
            stubborn.show()
        }
        assertEquals(false, windows(session) { texts(it) == listOf("Stay") }.single()["cancelable"])
        runBlocking { ui.close(session, force = false) }
        assertTrue(stubborn.isShowing, "Back leaves a window that isn't cancelable")
        closed(session, "closed")
        assertFalse(stubborn.isShowing)
    }

    @Test
    fun `an action is the person's, and an extension's crash on the main thread ends its screen with the error`() {
        Platform.install(JvmPlatform(pluginIn = { plugin }, notice = { _, _, _ -> }))
        HostHooks.pluginCrashed = { error -> ui.pluginCrashed(plugin, error.message ?: "") }
        var byPerson = false
        val session = open {
            Dialog(Context()).apply {
                setContentView(
                    LinearLayout(context).apply {
                        orientation = LinearLayout.VERTICAL
                        addView(
                            SeekBar(context).apply {
                                max = 10
                                setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                                    override fun onProgressChanged(bar: SeekBar, value: Int, fromUser: Boolean) {
                                        byPerson = fromUser
                                    }

                                    override fun onStartTrackingTouch(bar: SeekBar) {}
                                    override fun onStopTrackingTouch(bar: SeekBar) {}
                                })
                            },
                        )
                        addView(Button(context).apply {
                            text = "Crash"
                            setOnClickListener { MainThread.post { throw IllegalStateException("boom") } }
                        })
                    },
                )
            }.show()
        }
        val windows = windows(session) { all(it).any { node -> node["kind"] == "slider" } }
        val slider = all(windows).first { it["kind"] == "slider" }["id"] as Int
        val crash = all(windows).first { it["text"] == "Crash" }["id"] as Int
        runBlocking { ui.act(session, slider, "slide", 4) }
        assertTrue(byPerson)
        runBlocking { ui.act(session, crash, "click", null) }
        assertEquals("boom", closed(session, "error")["error"])
    }

    @Test
    fun `a window while the person waits on its extension opens a screen of its own, which the app hears of`() {
        val shown = runBlocking { ui.personCall(plugin) { onMain { dialog("Pick a server") } } }
        drainMain()
        val session = await { it.first == "uiOpened" }["session"] as Int
        windows(session) { texts(it) == listOf("Pick a server") }
        onMain { shown.dismiss() }
        closed(session, "closed")
    }

    @Test
    fun `Support opens the kept windows in a screen, the newest on top, and closing puts them back behind it`() {
        // The spec's §7 (the owner, 2026-10-08): Support keeps its pop-ups for the run; the extension is never told.
        val older = onMain { dialog("Old news") }
        drainMain()
        val newer = onMain { dialog("Support us") }
        drainMain()
        kept(listOf("Support us", "Old news"))
        val session = runBlocking { ui.openPopups(plugin) }["session"] as Int
        val windows = windows(session) { it.size == 2 }
        assertEquals(listOf("Old news", "Support us"), windows.map { texts(listOf(it)).single() })
        keptNow(emptyList())
        runBlocking { ui.close(session, force = false) }
        closed(session, "closed")
        keptNow(listOf("Support us", "Old news"))
        assertTrue(onMain { older.isShowing && newer.isShowing }, "still the extension's: never told they closed")
        val again = runBlocking { ui.openPopups(plugin) }["session"] as Int
        assertEquals(listOf("Old news", "Support us"), windows(again) { it.size == 2 }.map { texts(listOf(it)).single() })
        runBlocking { ui.close(again, force = true) }
        closed(again, "closed")
        keptNow(listOf("Support us", "Old news"))
        assertTrue(onMain { older.isShowing && newer.isShowing }, "Force close puts them back too (Review Focus 3)")
        onMain {
            older.dismiss()
            newer.dismiss()
        }
    }

    @Test
    fun `closing one of Support's windows puts that one back, and the screen ends with the last`() {
        // Review Focus 5.
        val older = onMain { dialog("Old news") }
        drainMain()
        val newer = onMain { dialog("Support us") }
        drainMain()
        kept(listOf("Support us", "Old news"))
        val session = runBlocking { ui.openPopups(plugin) }["session"] as Int
        val top = windows(session) { it.size == 2 }.last()
        runBlocking { ui.act(session, (top["root"] as Map<*, *>)["id"] as Int, "close", null) }
        val left = windows(session) { it.size == 1 }
        assertEquals(listOf("Old news"), texts(left))
        keptNow(listOf("Support us"))
        runBlocking { ui.act(session, (left.single()["root"] as Map<*, *>)["id"] as Int, "close", null) }
        closed(session, "closed")
        keptNow(listOf("Support us", "Old news"))
        assertTrue(onMain { older.isShowing && newer.isShowing })
        onMain {
            older.dismiss()
            newer.dismiss()
        }
    }

    @Test
    fun `a page a call waits on that joins an open Support screen closes with it, as the person closes it, and isn't kept`() {
        // The final review (part 6): only what Support took goes back; §7's Support holds no bot check.
        val promo = onMain { dialog("Support us") }
        drainMain()
        kept(listOf("Support us"))
        val session = runBlocking { ui.openPopups(plugin) }["session"] as Int
        windows(session) { it.size == 1 }
        val cancelled = AtomicBoolean()
        runBlocking {
            ui.call(plugin) {
                pageDialog(cancelled)
                windows(session) { it.size == 2 }
                ui.close(session, force = false)
                closed(session, "closed")
            }
        }
        assertTrue(cancelled.get(), "closed as the person closes it: the call waiting on it goes on")
        keptNow(listOf("Support us"))
        assertTrue(onMain { promo.isShowing })
        onMain { promo.dismiss() }
    }

    @Test
    fun `a pop-up's own sub-dialog closed by Back goes, as anywhere, and only the pop-up goes back behind Support`() {
        // The final review (part 6).
        val promo = onMain {
            Dialog(Context()).apply {
                setContentView(
                    LinearLayout(context).apply {
                        addView(TextView(context).apply { text = "Support us" })
                        addView(
                            Button(context).apply {
                                text = "Donate"
                                setOnClickListener { dialog("Choose a way to donate") }
                            },
                        )
                    },
                )
            }.also { it.show() }
        }
        drainMain()
        kept(listOf("Support us"))
        val session = runBlocking { ui.openPopups(plugin) }["session"] as Int
        val donate = all(windows(session) { it.size == 1 }).first { it["text"] == "Donate" }["id"] as Int
        runBlocking { ui.act(session, donate, "click", null) }
        val top = (windows(session) { it.size == 2 }.last()["root"] as Map<*, *>)["id"] as Int
        runBlocking { ui.act(session, top, "close", null) }
        windows(session) { it.size == 1 }
        runBlocking { ui.close(session, force = false) }
        closed(session, "closed")
        keptNow(listOf("Support us"))
        assertTrue(onMain { promo.isShowing })
        onMain { promo.dismiss() }
    }

    @Test
    fun `a Support window its extension closes itself is gone, and its Support button with it`() {
        // Review Focus 2. A guard: it passes before this task, and must still pass after it (put back only what
        // SkyStream closes).
        val notice = onMain { dialog("Notice") }
        drainMain()
        kept(listOf("Notice"))
        val session = runBlocking { ui.openPopups(plugin) }["session"] as Int
        windows(session) { it.size == 1 }
        onMain { notice.dismiss() }
        closed(session, "closed")
        Thread.sleep(200)
        keptNow(emptyList())
    }

    @Test
    fun `a fourth kept window pushes the oldest out, and the same words replace the older window`() {
        val first = onMain { dialog("Notice 1") }
        drainMain()
        val again = onMain { dialog("Notice 1") }
        drainMain()
        kept(listOf("Notice 1"))
        assertFalse(onMain { first.isShowing }, "replaced by the newer one")
        assertTrue(onMain { again.isShowing })
        val more = (2..4).map { n -> onMain { dialog("Notice $n") }.also { drainMain() } }
        kept(listOf("Notice 4", "Notice 3", "Notice 2"))
        assertFalse(onMain { again.isShowing }, "the oldest pushed out")
        onMain { more.forEach { it.dismiss() } }
    }

    @Test
    fun `a kept window its extension closes by itself takes its Support button with it`() {
        // Review Focus 2.
        val notice = onMain { dialog("Notice") }
        drainMain()
        kept(listOf("Notice"))
        onMain { notice.dismiss() }
        kept(emptyList())
    }

    @Test
    fun `a page parked for its sort goes when its extension unloads, never kept for an extension that's gone`() {
        // The spec's §7 (part 5's deferred minor): an uninstall or a switch-off within 5 s of a Home page promotion.
        val page = pageDialog()
        drainMain()
        runBlocking { ui.pluginUnloaded(plugin) }
        Thread.sleep(500)
        drainMain()
        assertFalse(onMain { page.isShowing })
        assertTrue(events.none { it.first == "popupKept" })
    }

    @Test
    fun `an extension unloading while Support shows its pop-up leaves nothing kept`() {
        // Review Focus 4. A guard across Task 1: the screen's close puts the pop-up back, and forgetting it then
        // dismisses it; the other order would leave it kept.
        val promo = onMain { dialog("Promo") }
        drainMain()
        kept(listOf("Promo"))
        val session = runBlocking { ui.openPopups(plugin) }["session"] as Int
        windows(session) { it.size == 1 }
        runBlocking { ui.pluginUnloaded(plugin) }
        closed(session, "unloaded")
        assertFalse(onMain { promo.isShowing })
        keptNow(emptyList())
    }

    @Test
    fun `an extension unloading dismisses its kept windows, and nothing holds them`() {
        // Review Focus 3, part 2's minor #7.
        val promo = onMain { dialog("Promo") }
        drainMain()
        kept(listOf("Promo"))
        runBlocking { ui.pluginUnloaded(plugin) }
        assertFalse(onMain { promo.isShowing })
        assertTrue(Ui.windows().none { it.owner === promo })
        kept(emptyList())
    }

    @Test
    fun `a window with a page in it whose extension isn't known still closes as if closed`() {
        // Part 2's rule, kept: nothing on the JVM loads its page, so the call that showed it would wait out its timeout.
        Ui.setListener(JvmUiHost(pluginOf = { null }, pluginIn = { null }))
        val cancelled = AtomicBoolean()
        val page = onMain {
            Dialog(Context()).apply {
                setContentView(WebView(context))
                setOnCancelListener { cancelled.set(true) }
            }.also { it.show() }
        }
        drainMain()
        assertTrue(cancelled.get(), "closed as the person closes it")
        assertFalse(onMain { page.isShowing })
    }

    @Test
    fun `a window shown off the main thread and closed on it before it is sorted leaves no ghost`() {
        // Review Focus 4, part 2's minor #6: its "shown" waits behind the main thread's task, which closes it.
        val session = open { dialog("Mine") }
        windows(session) { texts(it) == listOf("Mine") }
        val ghost = AtomicReference<Dialog>()
        val shownOffMain = CountDownLatch(1)
        MainThread.post {
            thread {
                ghost.set(Dialog(Context()).apply { setContentView(TextView(context).apply { text = "Ghost" }) }.also { it.show() })
                shownOffMain.countDown()
            }
            shownOffMain.await()
            ghost.get().dismiss()
        }
        drainMain()
        Thread.sleep(100)
        assertTrue(events.none { it.first == "ui" && "Ghost" in texts(windowsOf(it.second)) }, "no ghost in the screen")
    }

    @Test
    fun `a window that asks for the whole screen says so, with the screen kept on and its extension's orientation`() {
        // Phase 7c's §1 and §5: Ayu's games make their dialog with Theme.Black.NoTitleBar.Fullscreen (16973834), keep the
        // screen on, and turn the activity to sensor landscape (6) first; Comix's reader sets FLAG_FULLSCREEN on its
        // window, here after it shows (the flags are read again when they change).
        val before = CommonActivity.activity
        val activity = Activity()
        CommonActivity.setActivityInstance(activity)
        try {
            val session = open { dialog("Plain") }
            val plain = windows(session) { texts(it) == listOf("Plain") }.single()
            assertFalse("fullScreen" in plain || "keepScreenOn" in plain || "orientation" in plain)
            lateinit var reader: Dialog
            onMain {
                activity.requestedOrientation = 6
                Dialog(Context(), 16973834).apply {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    setContentView(TextView(context).apply { text = "Game" })
                }.show()
                reader = dialog("Reader")
            }
            windows(session) { it.size == 3 }
            onMain { reader.window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN) }
            val all = windows(session) { it.size == 3 && it[2]["fullScreen"] == true }
            val game = all[1]
            assertEquals(true, game["fullScreen"], "the theme asked")
            assertEquals(true, game["keepScreenOn"])
            assertEquals(6, game["orientation"])
            assertFalse("keepScreenOn" in all[2])
            assertEquals(6, all[2]["orientation"], "a full-screen window carries the activity's orientation")
        } finally {
            CommonActivity.setActivityInstance(before)
        }
    }

    @Test
    fun `Back reaches a window's own key listener first - one that takes it keeps its window, one that doesn't backs it`() {
        // Phase 7c's §3 and Review Focus 5: Ayu's Zelda takes only Back's down, its Pokémon only the up; either keeps the
        // window (the game pauses and saves, then closes itself on the second Back).
        lateinit var zelda: Dialog
        lateinit var pokemon: Dialog
        lateinit var plain: Dialog
        val session = open {
            zelda = dialog("Zelda").apply { setOnKeyListener { _, code, event -> code == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_DOWN } }
            pokemon = dialog("Pokemon").apply { setOnKeyListener { _, code, event -> code == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP } }
            plain = dialog("Plain").apply { setOnKeyListener { _, _, _ -> false } }
        }
        @Suppress("UNCHECKED_CAST")
        val roots = windows(session) { it.size == 3 }.map { (it["root"] as Map<String, Any?>)["id"] as Int }
        roots.forEach { runBlocking { ui.act(session, it, "close", null) } }
        windows(session) { it.size == 2 }
        assertTrue(onMain { zelda.isShowing && pokemon.isShowing }, "their listeners took Back")
        assertFalse(onMain { plain.isShowing }, "its listener took nothing: the dialog's own Back")
    }

    @Test
    fun `Back's key events carry their times, as Android's do`() {
        // Part 1's review: a listener that times its double Back with eventTime took the first Back as the second, as
        // every synthetic event said 0.
        val heard = CopyOnWriteArrayList<Triple<Int, Long, Long>>()
        val session = open {
            dialog("Game").apply {
                setOnKeyListener { _, code, event ->
                    heard.add(Triple(event.action, event.downTime, event.eventTime))
                    code == KeyEvent.KEYCODE_BACK
                }
            }
        }
        @Suppress("UNCHECKED_CAST")
        val root = (windows(session) { it.size == 1 }.single()["root"] as Map<String, Any?>)["id"] as Int
        runBlocking { ui.act(session, root, "close", null) }
        val until = System.currentTimeMillis() + 5_000
        while (heard.size < 2 && System.currentTimeMillis() < until) Thread.sleep(10)
        val (down, up) = heard
        assertEquals(KeyEvent.ACTION_DOWN, down.first)
        assertTrue(down.third > 0, "the down's eventTime: ${down.third}")
        assertEquals(down.third, down.second, "a down's downTime is its own eventTime")
        assertEquals(down.second, up.second, "the up's downTime is the down's")
        assertTrue(up.third >= down.third, "the up comes after the down")
    }
}
