package dev.akash.cs3engine.android.ui

import android.app.Dialog
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.webkit.WebView
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import dev.akash.cs3engine.host.BrokerClock
import dev.akash.cs3engine.host.RestartRequested
import dev.akash.cs3engine.ui.ExtensionUi
import dev.akash.cs3engine.ui.UiSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowLog
import org.robolectric.util.ReflectionHelpers
import java.io.File
import java.time.Duration
import kotlin.concurrent.thread
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
class AndroidUiHostTest {
    private val activity = Robolectric.buildActivity(ThemedActivity::class.java).setup().get()
    private val plugin = File("/plugins/Test.cs3")
    private val published = mutableListOf<List<Map<String, Any?>>>()
    private val ended = mutableListOf<String>()
    private val listener = object : UiSession.Listener {
        override fun published(session: UiSession, windows: List<Map<String, Any?>>) {
            published += windows
        }

        override fun ended(session: UiSession, reason: String) {
            ended += reason
        }
    }
    private val session = UiSession(1, plugin, listener)

    /** The extension owns every window, as if its code were on the stack. */
    private val host = AndroidUiHost(WindowOwners(pluginIn = { plugin }, pluginOf = { null }, activity = { activity }))

    private fun idle(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))

    private fun window(vararg views: View) = LinearLayout(activity).apply { views.forEach(::addView) }

    @Suppress("UNCHECKED_CAST")
    private fun texts(node: Map<String, Any?>): List<String> =
        listOfNotNull(node["text"] as String?) + (node["children"] as List<Map<String, Any?>>? ?: emptyList()).flatMap(::texts)

    @Suppress("UNCHECKED_CAST")
    private fun lastRoot(index: Int = 0) = published.last()[index]["root"] as Map<String, Any?>

    private fun rootId(index: Int = 0) = lastRoot(index)["id"] as Int

    private val events = mutableListOf<Pair<String, Map<String, Any?>>>()

    /**
     * The engine's pop-up rules on [host]: windows of an extension with no screen open are sorted. Their own
     * call clock: a screen left open here mustn't hold the engine's.
     */
    private fun rules(host: AndroidUiHost = this.host) =
        ExtensionUi(host, { type, fields -> events += type to fields }, callClock = BrokerClock(), pageSortMs = 100)

    @Suppress("UNCHECKED_CAST")
    private fun titles() = events.last { it.first == "popups" }.second["titles"] as List<String>

    /**
     * Android 16's predictive back, on as it is for SkyStream (targetSdk 37, no opt-out): a Back key no
     * longer reaches a dialog's onBackPressed.
     */
    private fun predictiveBack() {
        ReflectionHelpers.setStaticField(Class.forName("android.window.WindowOnBackInvokedDispatcher"), "ENABLE_PREDICTIVE_BACK", true)
        ReflectionHelpers.callInstanceMethod<Any?>(
            activity.applicationInfo,
            "setEnableOnBackInvokedCallback",
            ReflectionHelpers.ClassParameter.from(Boolean::class.javaPrimitiveType, true),
        )
    }

    @Test
    fun `a window the open screen's extension adds is hidden, read, and published`() = runBlocking {
        host.open(session, plugin) {}
        val params = WindowManager.LayoutParams()
        host.adding(window(CheckBox(activity).apply { text = "Disney" }, TextView(activity).apply { text = "Studios" }), params)
        assertTrue(Hiding.isHidden(params))
        idle(100)
        val window = published.last().single()
        assertEquals(true, window["hidden"])
        assertEquals(listOf("Disney", "Studios"), texts(lastRoot()))
    }

    @Test
    fun `windows of an extension with no open screen are left alone`() {
        val params = WindowManager.LayoutParams()
        host.adding(window(TextView(activity)), params)
        assertFalse(Hiding.isHidden(params))
        idle(600)
        assertTrue(published.isEmpty())
    }

    @Test
    fun `while a screen is open, another extension's window is logged as shown by Android, to find windows that escape the sheet`() = runBlocking {
        val other = File("/plugins/Other.cs3")
        val quiet = object : UiSession.Listener {
            override fun published(session: UiSession, windows: List<Map<String, Any?>>) = Unit

            override fun ended(session: UiSession, reason: String) = Unit
        }
        host.open(UiSession(2, other, quiet), other) {}
        host.adding(window(TextView(activity)), WindowManager.LayoutParams())
        assertTrue(ShadowLog.getLogsForTag("cs3").any { it.msg.contains("Test.cs3") && it.msg.contains("as Android draws it") })
    }

    @Test
    fun `an action reaches its view, and the tree is read again`() = runBlocking {
        host.open(session, plugin) {}
        val box = CheckBox(activity).apply { text = "Disney" }
        host.adding(window(box), WindowManager.LayoutParams())
        idle(100)
        @Suppress("UNCHECKED_CAST")
        val id = lastRoot()["id"] as Int
        host.act(session, id, "click", null)
        idle(100)
        assertTrue(box.isChecked)
        assertEquals(true, lastRoot()["checked"])
    }

    @Test
    fun `a restart an action triggers reaches the caller`() = runBlocking {
        host.open(session, plugin) {}
        val restart = TextView(activity).apply {
            text = "Restart"
            setOnClickListener { throw RestartRequested() }
        }
        host.adding(window(restart), WindowManager.LayoutParams())
        idle(100)
        @Suppress("UNCHECKED_CAST")
        val id = lastRoot()["id"] as Int
        assertFailsWith<RestartRequested> { host.act(session, id, "click", null) }
        Unit
    }

    @Test
    fun `a screen ends once its last window is gone, not while another one opens`() = runBlocking {
        host.open(session, plugin) {}
        val first = window(TextView(activity).apply { text = "First" })
        host.adding(first, WindowManager.LayoutParams())
        host.removed(first)
        host.adding(window(TextView(activity).apply { text = "Second" }), WindowManager.LayoutParams())
        idle(400)
        assertTrue(ended.isEmpty())
        assertEquals(listOf("Second"), texts(lastRoot()))
    }

    @Test
    fun `the screen's windows are read every half second, so the extension's own changes show`() = runBlocking {
        host.open(session, plugin) {}
        val status = TextView(activity).apply { text = "Loading" }
        host.adding(window(status), WindowManager.LayoutParams())
        idle(100)
        status.text = "Loaded"
        idle(600)
        assertEquals(listOf("Loaded"), texts(lastRoot()))
    }

    @Test
    fun `once a screen has ended (a restart, a crash), its extension's new windows are left alone`() = runBlocking {
        host.open(session, plugin) {}
        val first = window(TextView(activity))
        host.adding(first, WindowManager.LayoutParams())
        session.end("restart")
        // Its old window is still closing when the extension adds another.
        val later = WindowManager.LayoutParams()
        host.adding(window(TextView(activity)), later)
        assertFalse(Hiding.isHidden(later))
    }

    @Test
    fun `a window the extension makes focusable again is hidden again`() = runBlocking {
        host.open(session, plugin) {}
        val root = window(TextView(activity))
        host.adding(root, WindowManager.LayoutParams())
        val update = WindowManager.LayoutParams().apply { flags = 0 }
        host.updating(root, update)
        assertTrue(Hiding.isHidden(update))
    }

    @Test
    fun `closing backs each window, top first, then dismisses the ones that stay`() = runBlocking {
        host.open(session, plugin) {}
        val cancelable = Dialog(activity).apply { setContentView(TextView(activity).apply { text = "Bottom" }) }
        val stubborn = Dialog(activity).apply {
            setContentView(TextView(activity).apply { text = "Top" })
            setCancelable(false)
        }
        cancelable.show()
        stubborn.show()
        idle(10)
        host.adding(cancelable.window!!.decorView, cancelable.window!!.attributes)
        host.adding(stubborn.window!!.decorView, stubborn.window!!.attributes)
        host.close(session, force = false)
        idle(10)
        assertFalse(cancelable.isShowing, "Back closed the cancelable one")
        assertTrue(stubborn.window!!.decorView.isAttachedToWindow, "Back didn't close the other")
        idle(500)
        assertFalse(stubborn.window!!.decorView.isAttachedToWindow, "the one that stayed was dismissed")
    }

    @Test
    fun `on Android 16, where Back keys no longer reach a dialog, closing a window still backs it`() = runBlocking {
        predictiveBack()
        host.open(session, plugin) {}
        val alert = AlertDialog.Builder(activity).setMessage("Restart now?").setPositiveButton("Yes", null).show()
        val plain = Dialog(activity).apply { setContentView(TextView(activity).apply { text = "Plain" }) }
        plain.show()
        idle(10)
        host.adding(alert.window!!.decorView, alert.window!!.attributes)
        host.adding(plain.window!!.decorView, plain.window!!.attributes)
        idle(100)
        host.act(session, rootId(1), "close", null)
        idle(10)
        assertFalse(plain.isShowing, "Back closed the plain dialog")
        host.act(session, rootId(0), "close", null)
        idle(10)
        assertFalse(alert.isShowing, "Back closed AppCompat's alert")
    }

    @Test
    fun `a window that stays on Back is published as not cancelable, so the sheet shows it no close button`() = runBlocking {
        host.open(session, plugin) {}
        val stubborn = Dialog(activity).apply {
            setContentView(TextView(activity).apply { text = "Pick one" })
            setCancelable(false)
        }
        stubborn.show()
        idle(10)
        host.adding(stubborn.window!!.decorView, stubborn.window!!.attributes)
        idle(100)
        assertEquals(true, published.last().single()["cancelable"], "nothing says otherwise yet")
        host.act(session, rootId(), "close", null)
        idle(400)
        assertTrue(stubborn.isShowing)
        assertEquals(false, published.last().single()["cancelable"])
    }

    @Test
    fun `closing a dialog fragment's window backs it, so a cancelable one closes and one that isn't stays`() = runBlocking {
        predictiveBack()
        val host = AndroidUiHost(WindowOwners(pluginIn = { null }, pluginOf = { plugin }, activity = { activity }))
        host.open(session, plugin) {}
        val closes = ExtensionDialog()
        val stays = ExtensionDialog().apply { isCancelable = false }
        closes.show(activity.supportFragmentManager, "closes")
        stays.show(activity.supportFragmentManager, "stays")
        activity.supportFragmentManager.executePendingTransactions()
        idle(10)
        host.adding(closes.requireDialog().window!!.decorView, closes.requireDialog().window!!.attributes)
        host.adding(stays.requireDialog().window!!.decorView, stays.requireDialog().window!!.attributes)
        idle(100)
        assertEquals(listOf(true, false), published.last().map { it["cancelable"] })
        host.act(session, rootId(1), "close", null)
        idle(10)
        activity.supportFragmentManager.executePendingTransactions()
        assertTrue(stays.isAdded && stays.requireDialog().isShowing, "Back leaves a fragment that isn't cancelable")
        host.act(session, rootId(0), "close", null)
        idle(10)
        activity.supportFragmentManager.executePendingTransactions()
        assertFalse(closes.isAdded, "Back closed the cancelable one")
    }

    @Test
    fun `with no screen open, a window's owner isn't looked up`() {
        var lookups = 0
        val host = AndroidUiHost(WindowOwners(pluginIn = { lookups++; plugin }, pluginOf = { null }, activity = { activity }))
        host.adding(window(TextView(activity)), WindowManager.LayoutParams())
        assertEquals(0, lookups)
    }

    @Test
    fun `a window added off the main thread is left alone, and logged`() = runBlocking {
        host.open(session, plugin) {}
        val params = WindowManager.LayoutParams()
        val root = window(TextView(activity))
        val thread = Thread { host.adding(root, params) }
        thread.start()
        thread.join()
        idle(100)
        assertFalse(Hiding.isHidden(params))
        assertTrue(published.all { it.isEmpty() }, "nothing taken in")
        assertTrue(ShadowLog.getLogsForTag("cs3").any { it.msg.contains("off the main thread") })
    }

    @Test
    fun `a window no extension owns, added while a screen is open, is logged as escaping the sheet`() = runBlocking {
        val host = AndroidUiHost(WindowOwners(pluginIn = { null }, pluginOf = { null }, activity = { activity }))
        host.open(session, plugin) {}
        host.adding(window(TextView(activity)), WindowManager.LayoutParams())
        assertTrue(ShadowLog.getLogsForTag("cs3").any { it.msg.contains("no extension owns") })
    }

    @Test
    fun `settling waits until the main thread has run what the extension posted while opening`() {
        var shown = false
        Handler(Looper.getMainLooper()).post { shown = true }
        var settled = false
        CoroutineScope(Dispatchers.Unconfined).launch {
            host.settled(session)
            settled = true
        }
        assertFalse(settled, "not before the posted show has run")
        idle(10)
        assertTrue(shown && settled)
    }

    @Test
    fun `with the rules on, an extension's window with no screen open is hidden at once and kept for its Support button`() {
        rules()
        val params = WindowManager.LayoutParams()
        host.adding(window(TextView(activity).apply { text = "Support us" }, Button(activity).apply { text = "Donate" }), params)
        assertTrue(Hiding.isHidden(params), "hidden before it exists")
        idle(10)
        assertEquals(listOf("Support us"), titles())
        assertEquals(mapOf("plugin" to plugin.absolutePath, "title" to "Support us"), events.single { it.first == "popupKept" }.second)
        assertTrue(published.isEmpty(), "no screen: nothing published")
    }

    @Suppress("UNCHECKED_CAST")
    private fun kinds(node: Map<String, Any?>): List<String> =
        listOfNotNull(node["kind"] as String?) + (node["children"] as List<Map<String, Any?>>? ?: emptyList()).flatMap(::kinds)

    /** A dialog holding a page, added through the window hook as Android adds it; [width]×[height] if given. */
    private fun pageDialog(width: Int? = null, height: Int? = null, onCancel: () -> Unit = {}): Dialog {
        val page = Dialog(activity).apply {
            setContentView(WebView(activity))
            setOnCancelListener { onCancel() }
            if (width != null && height != null) window!!.setLayout(width, height)
        }
        page.show()
        idle(10)
        host.adding(page.window!!.decorView, page.window!!.attributes)
        return page
    }

    /** The extension's support dialog, shown and kept, as Home leaves it. */
    private fun keptDialog(words: String): Dialog {
        val dialog = Dialog(activity).apply { setContentView(TextView(activity).apply { text = words }) }
        dialog.show()
        idle(10)
        host.adding(dialog.window!!.decorView, dialog.window!!.attributes)
        idle(10)
        return dialog
    }

    @Test
    fun `closing Support puts its windows back behind it, the extension never told, and Support opens them again`() = runBlocking {
        // The spec's §7 (the owner, 2026-10-08).
        rules()
        var cancelled = false
        var dismissed = false
        val promo = keptDialog("Support us").apply {
            setOnCancelListener { cancelled = true }
            setOnDismissListener { dismissed = true }
        }
        assertEquals(listOf("Support us"), titles())
        assertTrue(host.openKept(session, plugin))
        idle(100)
        host.close(session, force = false)
        idle(500)
        // A parked dialog reads as not showing (Android's isShowing is its decor's visibility): its window is still there.
        assertTrue(promo.window!!.decorView.isAttachedToWindow, "still the extension's")
        assertFalse(cancelled || dismissed, "never told it closed")
        assertEquals(View.GONE, promo.window!!.decorView.visibility, "parked again: no drawing surface")
        assertEquals(listOf("Support us"), titles())
        assertEquals(listOf("closed"), ended)
        assertTrue(host.openKept(UiSession(2, plugin, listener), plugin), "Support opens it again")
        idle(100)
        @Suppress("UNCHECKED_CAST")
        assertEquals(listOf(listOf("Support us")), published.last().map { texts(it["root"] as Map<String, Any?>) })
    }

    @Test
    fun `closing Support's window, Force close included, puts it back too - Support never asks the extension`() = runBlocking {
        // Review Focus 3 and 5.
        rules()
        val promo = keptDialog("Support us")
        assertTrue(host.openKept(session, plugin))
        idle(100)
        host.act(session, rootId(), "close", "force")
        idle(500)
        assertEquals(listOf("Support us"), titles())
        assertTrue(promo.window!!.decorView.isAttachedToWindow, "still the extension's")
        assertEquals(listOf("closed"), ended)
    }

    @Test
    fun `a window that joins an open Support screen closes with it, as the person closes it, and isn't kept`() = runBlocking {
        // The final review (part 6): only what Support took goes back.
        rules()
        val promo = keptDialog("Support us")
        assertTrue(host.openKept(session, plugin))
        idle(100)
        var cancelled = false
        val check = Dialog(activity).apply {
            setContentView(TextView(activity).apply { text = "Verify you're human" })
            setOnCancelListener { cancelled = true }
        }
        check.show()
        idle(10)
        host.adding(check.window!!.decorView, check.window!!.attributes)
        idle(100)
        host.close(session, force = false)
        idle(500)
        assertTrue(cancelled, "closed as the person closes it")
        assertEquals(listOf("Support us"), titles())
        assertTrue(promo.window!!.decorView.isAttachedToWindow, "Support's own goes back")
    }

    @Test
    fun `a Support window its extension closes itself is gone, and its Support button with it`() = runBlocking {
        // Review Focus 2. A guard: it passes before this task, and must still pass after it.
        rules()
        val promo = keptDialog("Notice")
        assertTrue(host.openKept(session, plugin))
        idle(100)
        promo.dismiss()
        host.removed(promo.window!!.decorView)
        idle(400)
        assertEquals(emptyList(), titles())
        assertEquals(listOf("closed"), ended)
    }

    @Test
    fun `a background page a call of its extension still waits on is cancelled as if closed, after its sort`() = runBlocking {
        val ui = rules()
        var cancelled = false
        ui.call(plugin) {
            val page = pageDialog { cancelled = true }
            assertTrue(Hiding.isHidden(page.window!!.attributes), "hidden as it's added")
            idle(10)
            assertTrue(page.isShowing, "parked, not sorted yet")
            idle(150)
            assertTrue(cancelled)
            assertFalse(page.isShowing)
        }
        assertEquals(mapOf("plugin" to plugin.absolutePath, "reason" to "page"), events.single { it.first == "popupDropped" }.second)
    }

    @Test
    fun `a background page no call waits on is a promotion, kept and parked for Support`() {
        rules()
        val page = pageDialog()
        idle(150)
        assertEquals(listOf(plugin.nameWithoutExtension), titles())
        assertEquals(View.GONE, page.window!!.decorView.visibility, "parked: no drawing surface")
        assertTrue(events.none { it.first == "popupDropped" })
    }

    @Test
    fun `a parked page closed by its extension before it's sorted leaves nothing`() {
        rules()
        val page = pageDialog()
        page.dismiss()
        host.removed(page.window!!.decorView)
        idle(150)
        assertTrue(events.none { it.first == "popupKept" || it.first == "popups" || it.first == "popupDropped" })
    }

    @Test
    fun `a parked page whose extension's screen opened meanwhile goes into that screen`() = runBlocking {
        rules()
        val page = pageDialog()
        host.open(session, plugin) {}
        idle(150)
        assertTrue(page.isShowing)
        @Suppress("UNCHECKED_CAST")
        assertTrue(published.isNotEmpty() && published.last().any { "page" in kinds(it["root"] as Map<String, Any?>) }, "the page joined the screen")
        assertTrue(events.none { it.first == "popupKept" || it.first == "popupDropped" })
    }

    @Test
    fun `a window while the person waits on its extension opens a screen of its own`() {
        val ui = rules()
        val params = WindowManager.LayoutParams()
        runBlocking { ui.personCall(plugin) { host.adding(window(TextView(activity).apply { text = "Pick a server" }), params) } }
        assertTrue(Hiding.isHidden(params))
        idle(100)
        val opened = events.single { it.first == "uiOpened" }.second
        assertEquals("waiting", opened["why"])
        val screen = events.last { it.first == "ui" }.second
        assertEquals(opened["session"], screen["session"])
        @Suppress("UNCHECKED_CAST")
        val windows = screen["windows"] as List<Map<String, Any?>>
        @Suppress("UNCHECKED_CAST")
        assertEquals(listOf("Pick a server"), texts(windows.single()["root"] as Map<String, Any?>))
    }

    @Test
    fun `a page window while the person waits on its extension opens a screen of its own, page and all`() = runBlocking {
        val ui = rules()
        ui.personCall(plugin) {
            pageDialog()
            idle(10)
        }
        assertEquals(1, events.count { it.first == "uiOpened" })
    }

    @Test
    fun `a page window its extension made invisible, 1×1, isn't the person's while they wait - it's sorted as the background's`() = runBlocking {
        // Faselhd's link resolver and MyCima's cookie fetch (the final review).
        val ui = rules()
        var cancelled = false
        // Its links, as the engine runs them: a call the person waits on.
        ui.call(plugin) {
            ui.personCall(plugin) {
                pageDialog(1, 1) { cancelled = true }
                idle(10)
                assertTrue(events.none { it.first == "uiOpened" }, "no screen for a page no one can see")
                idle(150)
            }
        }
        assertTrue(cancelled, "its call still ran at the second sort: dropped, as a background bot check")
    }

    @Test
    fun `Support takes the kept windows into a screen, the oldest at the bottom, and they're no longer kept`() = runBlocking {
        rules()
        host.adding(window(TextView(activity).apply { text = "Old news" }), WindowManager.LayoutParams())
        idle(10)
        host.adding(window(TextView(activity).apply { text = "Support us" }), WindowManager.LayoutParams())
        idle(10)
        assertEquals(listOf("Support us", "Old news"), titles())
        assertTrue(host.openKept(session, plugin))
        idle(100)
        @Suppress("UNCHECKED_CAST")
        assertEquals(listOf(listOf("Old news"), listOf("Support us")), published.last().map { texts(it["root"] as Map<String, Any?>) })
        assertEquals(emptyList(), titles())
        assertFalse(host.openKept(session, plugin), "none left")
    }

    @Test
    fun `a kept window is parked with its root gone, no drawing surface, until Support shows it`() = runBlocking {
        // The spec's §3: parked windows have their root set to GONE while they wait.
        rules()
        val root = window(TextView(activity).apply { text = "Support us" })
        host.adding(root, WindowManager.LayoutParams())
        idle(10)
        assertEquals(listOf("Support us"), titles())
        assertEquals(View.GONE, root.visibility)
        assertTrue(host.openKept(session, plugin))
        idle(100)
        assertEquals(View.VISIBLE, root.visibility)
        @Suppress("UNCHECKED_CAST")
        assertEquals(listOf(listOf("Support us")), published.last().map { texts(it["root"] as Map<String, Any?>) })
    }

    @Test
    fun `a kept window its extension closes by itself takes its Support button with it`() {
        // Review Focus 2.
        rules()
        val root = window(TextView(activity).apply { text = "Notice" })
        host.adding(root, WindowManager.LayoutParams())
        idle(10)
        assertEquals(listOf("Notice"), titles())
        host.removed(root)
        idle(10)
        assertEquals(emptyList(), titles())
    }

    @Test
    fun `an extension unloading dismisses its kept windows`() = runBlocking {
        // Review Focus 3.
        rules()
        val promo = Dialog(activity).apply { setContentView(TextView(activity).apply { text = "Promo" }) }
        promo.show()
        idle(10)
        host.adding(promo.window!!.decorView, promo.window!!.attributes)
        idle(10)
        assertEquals(listOf("Promo"), titles())
        host.forgetKept(plugin)
        idle(10)
        assertFalse(promo.isShowing)
        assertEquals(emptyList(), titles())
    }

    @Test
    fun `a page parked for its sort goes when its extension unloads, never kept for an extension that's gone`() = runBlocking {
        // The spec's §7 (part 5's deferred minor).
        rules()
        val page = pageDialog()
        // Parked by its first sort, posted as it was added: the engine's unload reaches the main thread after it.
        idle(10)
        host.forgetKept(plugin)
        idle(150)
        // Dismissed: its window is gone (a parked or kept one stays attached; Android's isShowing reads only visibility).
        assertFalse(page.window!!.decorView.isAttachedToWindow)
        assertTrue(events.none { it.first == "popupKept" })
    }

    @Test
    fun `a window removed before it is sorted is never sorted`() {
        // Review Focus 4.
        rules()
        val root = window(TextView(activity).apply { text = "Gone" })
        host.adding(root, WindowManager.LayoutParams())
        host.removed(root)
        idle(10)
        assertTrue(events.none { it.first == "popups" || it.first == "popupKept" || it.first == "uiOpened" })
    }

    @Test
    fun `with the rules on, a window its extension makes visible again before or after sorting stays hidden`() {
        rules()
        val root = window(TextView(activity).apply { text = "Promo" })
        host.adding(root, WindowManager.LayoutParams())
        val early = WindowManager.LayoutParams()
        host.updating(root, early)
        assertTrue(Hiding.isHidden(early), "while it waits to be sorted")
        idle(10)
        val late = WindowManager.LayoutParams()
        host.updating(root, late)
        assertTrue(Hiding.isHidden(late), "kept")
    }

    @Test
    fun `with the rules on, an extension's window added off the main thread shows as Android draws it, and is reported`() {
        rules()
        val root = window(TextView(activity).apply { text = "Elsewhere" })
        val params = WindowManager.LayoutParams()
        thread { host.adding(root, params) }.join()
        assertFalse(Hiding.isHidden(params))
        assertEquals(mapOf("plugin" to plugin.absolutePath, "why" to "thread"), events.single { it.first == "popupEscaped" }.second)
    }

    @Test
    fun `with the rules on, a window no extension's code added is left alone, on the main thread or off it`() {
        // Review Focus 5: SkyStream's own windows (a page's dropdown in the check sheet) while extensions are loaded.
        val host = AndroidUiHost(WindowOwners(pluginIn = { null }, pluginOf = { null }, activity = { activity }))
        rules(host)
        val params = WindowManager.LayoutParams()
        host.adding(window(TextView(activity).apply { text = "SkyStream's own" }), params)
        val other = window(TextView(activity))
        val elsewhere = WindowManager.LayoutParams()
        thread { host.adding(other, elsewhere) }.join()
        idle(10)
        assertFalse(Hiding.isHidden(params) || Hiding.isHidden(elsewhere))
        assertTrue(events.isEmpty(), "nothing kept, dropped, opened or reported: $events")
    }

    @Test
    fun `a window that asks for the whole screen says so, and that it keeps the screen on, read again when it changes`() = runBlocking {
        // Phase 7c's §1: a …Fullscreen theme sets FLAG_FULLSCREEN, as Ayu's games' dialogs have it; Comix's reader sets the
        // flag itself, here after its window was added (updateViewLayout).
        host.open(session, plugin) {}
        val game = Dialog(activity, android.R.style.Theme_Black_NoTitleBar_Fullscreen).apply {
            window!!.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            setContentView(TextView(activity).apply { text = "Game" })
        }
        val reader = Dialog(activity).apply { setContentView(TextView(activity).apply { text = "Reader" }) }
        game.show()
        reader.show()
        idle(10)
        host.adding(game.window!!.decorView, game.window!!.attributes)
        host.adding(reader.window!!.decorView, reader.window!!.attributes)
        idle(100)
        assertEquals(true, published.last()[0]["fullScreen"], "the theme asked")
        assertEquals(true, published.last()[0]["keepScreenOn"])
        assertFalse("orientation" in published.last()[0], "Android's activity turns itself")
        assertFalse("fullScreen" in published.last()[1] || "keepScreenOn" in published.last()[1])
        val asked = WindowManager.LayoutParams().apply {
            copyFrom(reader.window!!.attributes)
            flags = flags or WindowManager.LayoutParams.FLAG_FULLSCREEN
        }
        host.updating(reader.window!!.decorView, asked)
        idle(600)
        assertEquals(true, published.last()[1]["fullScreen"], "read again once it changed")
    }

    @Test
    fun `Back reaches a dialog's own key listener first - one that takes it keeps its window, and stays cancelable`() = runBlocking {
        // Phase 7c's §3 and Review Focus 5, under Android 16's predictive back as SkyStream runs.
        predictiveBack()
        host.open(session, plugin) {}
        val zelda = Dialog(activity).apply {
            setContentView(TextView(activity).apply { text = "Zelda" })
            setOnKeyListener { _, code, event -> code == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_DOWN }
        }
        val pokemon = Dialog(activity).apply {
            setContentView(TextView(activity).apply { text = "Pokemon" })
            setOnKeyListener { _, code, event -> code == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP }
        }
        val plain = Dialog(activity).apply { setContentView(TextView(activity).apply { text = "Plain" }) }
        listOf(zelda, pokemon, plain).forEach { it.show() }
        idle(10)
        listOf(zelda, pokemon, plain).forEach { host.adding(it.window!!.decorView, it.window!!.attributes) }
        idle(100)
        val roots = (0..2).map { rootId(it) }
        roots.forEach { host.act(session, it, "close", null) }
        idle(400)
        assertTrue(zelda.window!!.decorView.isAttachedToWindow, "its listener took Back's down")
        assertTrue(pokemon.window!!.decorView.isAttachedToWindow, "its listener took Back's up")
        assertFalse(plain.window!!.decorView.isAttachedToWindow, "no listener: the dialog's own Back")
        assertEquals(listOf(true, true), published.last().take(2).map { it["cancelable"] }, "taking Back isn't staying on it")
    }

    @Test
    fun `Back's key events carry their times, as Android's own do`() = runBlocking {
        // Part 1's review: a listener that times its double Back with eventTime took the first Back as the second, as
        // every synthetic event said 0.
        predictiveBack()
        host.open(session, plugin) {}
        val heard = mutableListOf<Triple<Int, Long, Long>>()
        val game = Dialog(activity).apply {
            setContentView(TextView(activity).apply { text = "Game" })
            setOnKeyListener { _, code, event ->
                heard.add(Triple(event.action, event.downTime, event.eventTime))
                code == KeyEvent.KEYCODE_BACK
            }
        }
        game.show()
        idle(10)
        host.adding(game.window!!.decorView, game.window!!.attributes)
        idle(100)
        host.act(session, rootId(), "close", null)
        idle(10)
        assertEquals(2, heard.size)
        val (down, up) = heard
        assertEquals(KeyEvent.ACTION_DOWN, down.first)
        assertTrue(down.third > 0, "the down's eventTime: ${down.third}")
        assertEquals(down.third, down.second, "a down's downTime is its own eventTime")
        assertEquals(down.second, up.second, "the up's downTime is the down's")
        assertTrue(up.third >= down.third, "the up comes after the down")
    }

    @Test
    fun `a window closed by force goes through its own dialog, so its extension hears it closed`() = runBlocking {
        // Phase 7c's escape: a game that swallows Back is closed by force, and its Play call ends with its dismiss.
        host.open(session, plugin) {}
        var dismissed = false
        val stuck = Dialog(activity).apply {
            setContentView(TextView(activity).apply { text = "Stuck" })
            setOnKeyListener { _, code, _ -> code == KeyEvent.KEYCODE_BACK }
            setOnDismissListener { dismissed = true }
        }
        stuck.show()
        idle(10)
        host.adding(stuck.window!!.decorView, stuck.window!!.attributes)
        idle(100)
        host.act(session, rootId(), "close", "force")
        idle(10)
        assertTrue(dismissed, "its dismiss listener ran")
        assertFalse(stuck.window!!.decorView.isAttachedToWindow)
    }
}
