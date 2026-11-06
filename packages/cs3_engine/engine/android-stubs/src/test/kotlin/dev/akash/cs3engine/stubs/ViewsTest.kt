package dev.akash.cs3engine.stubs

import android.content.Context
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** A plain group: ViewGroup is abstract, as Android's. */
class Group(context: Context) : ViewGroup(context) {
    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {}
}

class ViewsTest {
    private val context = Context()
    private val platform = RecordingPlatform()

    @BeforeTest
    fun install() = Platform.install(platform)

    @AfterTest
    fun uninstall() {
        Platform.install(null)
        Ui.setListener(null)
        Ui.windows().forEach { Ui.dismissed(it.owner) }
    }

    @Test
    fun `a view keeps its state and calls its listeners`() {
        val view = View(context)
        view.id = 42
        view.contentDescription = "Close"
        view.tag = "t"
        view.setTag(7, "seven")
        view.isEnabled = false
        assertEquals(42, view.id)
        assertEquals("Close", view.contentDescription)
        assertEquals("seven", view.getTag(7))
        assertFalse(view.isEnabled)
        assertFalse(view.performClick(), "no listener: nothing handled the tap")
        val clicks = AtomicInteger()
        view.setOnClickListener { clicks.incrementAndGet() }
        assertTrue(view.isClickable && view.hasOnClickListeners())
        assertTrue(view.performClick())
        assertEquals(1, clicks.get())
        view.setOnLongClickListener { true }
        assertTrue(view.performLongClick())
        view.setOnTouchListener { _, event -> event.action == MotionEvent.ACTION_DOWN }
        val down = MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, 1f, 1f, 0)
        assertFalse(view.dispatchTouchEvent(down), "a disabled view's touch listener isn't called, as on Android")
        view.isEnabled = true
        assertTrue(view.dispatchTouchEvent(down))
        view.setOnKeyListener { _, code, _ -> code == KeyEvent.KEYCODE_ENTER }
        assertTrue(view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)))
        assertEquals(0, view.width, "nothing is measured")
    }

    @Test
    fun `a group holds its children in order, finds them by id, and refuses a second parent`() {
        val root = Group(context)
        val inner = Group(context).apply { id = 2 }
        val leaf = View(context).apply { id = 3 }
        root.addView(inner)
        inner.addView(leaf)
        root.addView(View(context), 0)
        assertEquals(2, root.childCount)
        assertSame(inner, root.getChildAt(1))
        assertNull(root.getChildAt(5))
        assertSame(leaf, root.findViewById<View>(3))
        assertSame(root, leaf.rootView)
        assertEquals(ViewGroup.LayoutParams.WRAP_CONTENT, leaf.layoutParams.width, "a default size")
        assertFailsWith<IllegalStateException> { root.addView(leaf) }
        inner.removeView(leaf)
        assertNull(leaf.parent)
        root.addView(leaf)
        assertSame(root, leaf.parent)
        assertSame(leaf, root.requireViewById<View>(3))
        assertFailsWith<IllegalArgumentException> { root.requireViewById<View>(99) }
    }

    @Test
    fun `setters mark the screen changed, and reading doesn't`() {
        val view = View(context)
        Ui.takeDirty()
        view.visibility
        view.isEnabled
        assertFalse(Ui.takeDirty())
        view.visibility = View.GONE
        assertTrue(Ui.takeDirty())
        view.visibility = View.GONE
        assertFalse(Ui.takeDirty(), "the same value changes nothing")
        Group(context).addView(view)
        assertTrue(Ui.takeDirty())
    }

    @Test
    fun `fluent calls survive — the observer, the animator, the handler and the root are never null`() {
        val root = Group(context)
        val view = View(context)
        root.addView(view)
        val layouts = AtomicInteger()
        onMain {
            view.viewTreeObserver.addOnGlobalLayoutListener { layouts.incrementAndGet() }
            // An extension dividing by a size the stand-ins don't have: logged, never the screen's end.
            view.viewTreeObserver.addOnGlobalLayoutListener { 10 / view.width }
            view.viewTreeObserver.addOnPreDrawListener { true }
        }
        drainMain()
        assertEquals(1, layouts.get(), "heard once, after the task that added it")
        assertTrue(platform.uncaught.isEmpty())
        val ended = AtomicInteger()
        onMain { view.animate().alpha(0f).setDuration(200).withEndAction { ended.incrementAndGet() }.start() }
        assertEquals(0f, view.alpha)
        assertEquals(1, ended.get())
        onMain { view.animate().translationY(12f) }
        drainMain()
        assertEquals(12f, view.translationY, "an animation nobody starts starts by itself")
        val posted = CountDownLatch(2)
        view.handler.post { posted.countDown() }
        view.post { posted.countDown() }
        assertTrue(posted.await(5, TimeUnit.SECONDS))
        assertSame(root, view.rootView)
        assertFalse(view.isShown, "not in a window")
    }

    @Test
    fun `a change made off the main thread wakes the main thread to read it`() {
        val view = View(context)
        val read = CountDownLatch(1)
        MainThread.setAfterTask { if (Ui.takeDirty()) read.countDown() }
        try {
            drainMain()
            thread { view.contentDescription = "from a background thread" }.join()
            assertTrue(read.await(5, TimeUnit.SECONDS))
        } finally {
            MainThread.setAfterTask(null)
        }
    }

    @Test
    fun `windows register when shown and leave when dismissed, heard on the main thread`() {
        val heard = mutableListOf<String>()
        val on = AtomicReference<String>()
        Ui.setListener(
            object : Ui.Listener {
                override fun shown(window: Ui.Window) {
                    synchronized(heard) { heard += "shown ${window.kind}" }
                    on.set(Thread.currentThread().name)
                }

                override fun dismissed(window: Ui.Window) {
                    synchronized(heard) { heard += "dismissed" }
                }
            },
        )
        val owner = Any()
        val root = Group(context)
        val child = View(context).also(root::addView)
        thread { Ui.shown(Ui.Window(owner, root, "dialog", null)) }.join()
        assertTrue(Ui.isShowing(root))
        assertTrue(child.isShown && child.isAttachedToWindow)
        drainMain()
        assertEquals("cs3-main", on.get())
        Ui.dismissed(owner)
        drainMain()
        assertFalse(Ui.isShowing(root))
        assertEquals(listOf("shown dialog", "dismissed"), synchronized(heard) { heard.toList() })
        assertTrue(Ui.windows().isEmpty())
    }

    @Test
    fun `the person's actions are told apart from the extension's`() {
        assertFalse(Ui.personActing())
        var during = false
        Ui.acting { during = Ui.personActing() }
        assertTrue(during)
        assertFalse(Ui.personActing())
        val dialog = Any()
        val fragment = Any()
        Ui.own(dialog, fragment)
        assertSame(fragment, Ui.fragmentOf(dialog))
    }

    @Test
    fun `layout params copy, default and keep margins`() {
        val margins = ViewGroup.MarginLayoutParams(ViewGroup.LayoutParams(10, ViewGroup.LayoutParams.MATCH_PARENT))
        assertEquals(10, margins.width)
        assertEquals(ViewGroup.LayoutParams.MATCH_PARENT, margins.height)
        margins.setMargins(1, 2, 3, 4)
        assertEquals(4, margins.bottomMargin)
        val view = View(context)
        view.layoutParams = margins
        assertSame(margins, view.layoutParams)
        assertFailsWith<NullPointerException> { view.layoutParams = null }
    }
}
