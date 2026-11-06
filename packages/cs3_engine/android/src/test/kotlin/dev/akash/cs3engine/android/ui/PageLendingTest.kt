package dev.akash.cs3engine.android.ui

import android.os.Looper
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.WebView
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import dev.akash.cs3engine.host.BrokerClock
import dev.akash.cs3engine.ui.ExtensionUi
import dev.akash.cs3engine.ui.UiSession
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.io.File
import java.time.Duration
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** The extension's own WebView, lent to the sheet's platform view and given back (the spec's §9, Android). */
@RunWith(RobolectricTestRunner::class)
class PageLendingTest {
    private val activity = Robolectric.buildActivity(ThemedActivity::class.java).setup().get()
    private val plugin = File("/plugins/Test.cs3")
    private val published = mutableListOf<List<Map<String, Any?>>>()
    private val exits = mutableListOf<Pair<Int, String>>()
    private val listener = object : UiSession.Listener {
        override fun published(session: UiSession, windows: List<Map<String, Any?>>) {
            published += windows
        }

        override fun ended(session: UiSession, reason: String) = Unit

        override fun pageFocusLeft(session: UiSession, node: Int, direction: String) {
            exits += node to direction
        }
    }
    private val session = UiSession(1, plugin, listener)
    private val host = AndroidUiHost(WindowOwners(pluginIn = { plugin }, pluginOf = { null }, activity = { activity }))
    private val page = WebView(activity)
    private val params = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 900)
    private val column = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        addView(TextView(activity).apply { text = "Sign in" })
        addView(page, params)
        addView(TextView(activity).apply { text = "Below" })
    }

    private fun idle(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))

    @Suppress("UNCHECKED_CAST")
    private fun nodes(node: Map<String, Any?>): List<Map<String, Any?>> =
        listOf(node) + (node["children"] as List<Map<String, Any?>>? ?: emptyList()).flatMap(::nodes)

    @Suppress("UNCHECKED_CAST")
    private fun pageNode(): Int = nodes(published.last().single()["root"] as Map<String, Any?>).single { it["kind"] == "page" }["id"] as Int

    private fun opened(): Int = runBlocking {
        host.open(session, plugin) {}
        host.adding(column, WindowManager.LayoutParams())
        idle(100)
        pageNode()
    }

    @Test
    fun `a lent page leaves a stand-in in its slot, and the tree keeps its node`() {
        val node = opened()
        val before = published.last()
        val container = FrameLayout(activity)
        assertTrue(host.lendPage(1, node, container))
        assertSame(container, page.parent)
        val standIn = column.getChildAt(1)
        assertTrue(standIn is PageSlot.StandIn)
        assertSame(params, standIn.layoutParams, "the slot keeps its layout")
        idle(600)
        assertEquals(before, published.last(), "the same tree: the page node keeps its number")
        assertEquals(node, pageNode())
    }

    @Test
    fun `Support's page promotion goes back to its slot as Support closes, and is lent again when Support reopens`() = runBlocking {
        // Review Focus 1: the spec's §7 and §9 (the owner, 2026-10-08).
        ExtensionUi(host, { _, _ -> }, callClock = BrokerClock(), pageSortMs = 100)
        host.adding(column, WindowManager.LayoutParams())
        idle(150)
        assertEquals(View.GONE, column.visibility, "kept for Support: no call waited on it")
        assertTrue(host.openKept(session, plugin))
        idle(100)
        val container = FrameLayout(activity)
        assertTrue(host.lendPage(1, pageNode(), container))
        host.close(session, force = false)
        idle(500)
        assertSame(column, page.parent, "back in its slot")
        assertEquals(1, column.indexOfChild(page))
        assertEquals(0, container.childCount)
        assertEquals(View.GONE, column.visibility, "kept again")
        assertTrue(host.openKept(UiSession(2, plugin, listener), plugin))
        idle(100)
        assertTrue(host.lendPage(2, pageNode(), FrameLayout(activity)), "lent again")
    }

    @Test
    fun `a page given back goes into its slot, as it was`() {
        val node = opened()
        val container = FrameLayout(activity)
        host.lendPage(1, node, container)
        host.returnPage(container)
        assertSame(column, page.parent)
        assertEquals(1, column.indexOfChild(page))
        assertSame(params, page.layoutParams)
        assertEquals(3, column.childCount)
        assertEquals(0, container.childCount)
    }

    @Test
    fun `a page lent again, to a new view before the old one went, moves there and still goes back once`() {
        val node = opened()
        val first = FrameLayout(activity)
        val second = FrameLayout(activity)
        host.lendPage(1, node, first)
        assertTrue(host.lendPage(1, node, second))
        assertSame(second, page.parent)
        host.returnPage(first)
        assertSame(second, page.parent, "the old view's going leaves the page where it shows now")
        host.returnPage(second)
        assertSame(column, page.parent)
        assertEquals(3, column.childCount)
    }

    @Test
    fun `a page whose slot the extension emptied isn't put back anywhere`() {
        val node = opened()
        val container = FrameLayout(activity)
        host.lendPage(1, node, container)
        // StreamPlay's sign-in swaps its dialog's content in place.
        column.removeAllViews()
        host.returnPage(container)
        assertEquals(null, page.parent)
        assertEquals(0, column.childCount)
    }

    @Test
    fun `no page to lend - an unknown node, a node that isn't a page, a closed screen`() {
        val node = opened()
        val container = FrameLayout(activity)
        assertFalse(host.lendPage(1, 9_999, container))
        @Suppress("UNCHECKED_CAST")
        val text = nodes(published.last().single()["root"] as Map<String, Any?>).first { it["kind"] == "text" }["id"] as Int
        assertFalse(host.lendPage(1, text, container))
        assertFalse(host.lendPage(2, node, container))
        assertEquals(0, container.childCount)
    }

    @Test
    fun `focus waits for a lent page's layout, blur drops it, and focus leaving it is told with its node and way`() = runBlocking {
        val node = opened()
        // Built as ExtensionPageFactory builds it.
        lateinit var container: ExtensionPageContainer
        container = ExtensionPageContainer(activity) { direction -> host.pageFocusLeft(container, direction) }
        activity.setContentView(container)
        assertTrue(host.lendPage(1, node, container), "lent")
        assertSame(container, page.parent)
        // Robolectric's WebView takes no size, even laid out by hand: focus waits for its first layout, as on a device
        // a WebView focused before it has a size never sets up the D-pad's start. The TV run covers focus entering it.
        host.act(session, node, "focus", true)
        idle(100)
        assertFalse(container.wantsFocus, "no size yet: focus waits")
        host.act(session, node, "blur", null)
        assertFalse(container.wantsFocus)
        container.focusLeft(ExtensionPageContainer.DOWN)
        idle(10)
        assertEquals(listOf(node to "down"), exits)
    }

    @Test
    fun `a page in the full-screen view keeps the D-pad and the keyboard - focus never leaves it, so a game gets every arrow`() {
        val exits = mutableListOf<String>()
        // Built as ExtensionPageFactory builds them: the full-screen view's page, and the sheet's.
        val game = ExtensionPageContainer(activity, keepFocus = true) { exits += it }
        val sheet = ExtensionPageContainer(activity) { exits += it }
        val gamePage = WebView(activity)
        val sheetPage = WebView(activity)
        game.addView(gamePage)
        sheet.addView(sheetPage)
        activity.setContentView(LinearLayout(activity).apply { addView(game); addView(sheet) })
        val ways = listOf(View.FOCUS_UP, View.FOCUS_DOWN, View.FOCUS_LEFT, View.FOCUS_RIGHT, View.FOCUS_FORWARD, View.FOCUS_BACKWARD)
        for (way in ways) assertSame(gamePage, game.focusSearch(gamePage, way))
        assertTrue(game.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB)), "Tab stays in the page")
        idle(10)
        assertEquals(emptyList(), exits, "the full-screen page's focus goes nowhere: Back is its way out")
        // The sheet's page still lets focus go on to the sheet's own controls.
        sheet.focusSearch(sheetPage, View.FOCUS_RIGHT)
        idle(10)
        assertEquals(listOf("right"), exits)
    }

    @Test
    fun `the factory makes the full-screen view's page keep focus when the app asks, and the sheet's let it go`() {
        val node = opened()
        val factory = ExtensionPageFactory { host }
        val lent = factory.create(activity, 1, mapOf("session" to 1, "node" to node, "keepFocus" to true))
        activity.setContentView(lent.view)
        (lent.view as ExtensionPageContainer).focusSearch(page, View.FOCUS_RIGHT)
        idle(10)
        assertEquals(emptyList(), exits, "the full-screen view's page keeps focus")
        lent.dispose()
        val inSheet = factory.create(activity, 2, mapOf("session" to 1, "node" to node))
        activity.setContentView(inSheet.view)
        (inSheet.view as ExtensionPageContainer).focusSearch(page, View.FOCUS_RIGHT)
        idle(10)
        assertEquals(listOf(node to "right"), exits)
        inSheet.dispose()
    }

    @Test
    fun `Back closes a window whose only content is its page, while the page is lent`() = runBlocking {
        // A page-only dialog (Dialog.setContentView(webView)): its tree's root is the page node itself, which the
        // sheet's Back and X close by.
        host.open(session, plugin) {}
        val lone = WebView(activity)
        val dialog = android.app.Dialog(activity).apply { setContentView(lone) }
        dialog.show()
        idle(10)
        host.adding(dialog.window!!.decorView, dialog.window!!.attributes)
        idle(100)
        @Suppress("UNCHECKED_CAST")
        val root = published.last().single()["root"] as Map<String, Any?>
        assertEquals("page", root["kind"], "the window's root is its page")
        val node = root["id"] as Int
        assertTrue(host.lendPage(1, node, FrameLayout(activity)))
        host.act(session, node, "close", null)
        idle(400)
        assertFalse(dialog.isShowing, "closed by Back while its page is lent")
    }
}
