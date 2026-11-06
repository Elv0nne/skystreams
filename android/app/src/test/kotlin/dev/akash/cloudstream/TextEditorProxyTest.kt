package dev.akash.skystream

import android.app.Activity
import android.content.Context
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.widget.FrameLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/** Flutter's view, as far as the proxy needs it: a focusable parent with a keyboard connection to hand out. */
private class FakeFlutterView(context: Context) : FrameLayout(context) {
    val connection = BaseInputConnection(this, true)

    /** A view this one vouches for, as Flutter's does for a platform view typing through it. */
    val vouchedFor = View(context)

    init {
        isFocusable = true
        isFocusableInTouchMode = true
    }

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection = connection

    override fun checkInputConnectionProxy(view: View?): Boolean = view === vouchedFor
}

@RunWith(RobolectricTestRunner::class)
class TextEditorProxyTest {
    private lateinit var activity: Activity
    private lateinit var host: FakeFlutterView
    private lateinit var proxy: TextEditorProxy

    @Before
    fun setUp() {
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        host = FakeFlutterView(activity)
        activity.setContentView(host)
        proxy = TextEditorProxy.installIn(host)
        host.requestFocus()
    }

    @Test
    fun `is a text editor only while a Flutter field is being edited`() {
        assertFalse(proxy.onCheckIsTextEditor())
        proxy.editing = true
        assertTrue(proxy.onCheckIsTextEditor())
        proxy.editing = false
        assertFalse(proxy.onCheckIsTextEditor())
    }

    @Test
    fun `hands the keyboard Flutter's own connection, and only while editing`() {
        assertNull(proxy.onCreateInputConnection(EditorInfo()))
        proxy.editing = true
        assertSame(host.connection, proxy.onCreateInputConnection(EditorInfo()))
    }

    @Test
    fun `vouches for Flutter's view and nothing else`() {
        assertTrue(proxy.checkInputConnectionProxy(host))
        assertFalse(proxy.checkInputConnectionProxy(View(host.context)))
    }

    @Test
    fun `vouches for what Flutter's view vouches for`() {
        assertTrue(proxy.checkInputConnectionProxy(host.vouchedFor))
    }

    @Test
    fun `answers no view with no, rather than throwing`() {
        // The input method manager can pass null. Asked through View, as the framework asks.
        val asView: View = proxy
        assertFalse(asView.checkInputConnectionProxy(null))
    }

    @Test
    fun `takes the focus while editing, even when Flutter asks for it again`() {
        proxy.editing = true
        assertTrue(proxy.isFocused)
        // Flutter's TextInputPlugin asks its view for focus each time it shows the keyboard.
        host.requestFocus()
        assertTrue(proxy.isFocused)
        assertFalse(host.isFocused)
    }

    @Test
    fun `gives the focus back to Flutter's view when editing ends`() {
        proxy.editing = true
        proxy.editing = false
        assertTrue(host.isFocused)
        assertFalse(proxy.isFocusable)
    }

    @Test
    fun `leaves alone a focus it does not hold`() {
        val page = View(host.context).apply {
            isFocusable = true
            isFocusableInTouchMode = true
        }
        host.addView(page)
        proxy.editing = true
        // A page in a platform view took the focus to type into its own field.
        page.requestFocus()
        proxy.editing = false
        assertTrue(page.isFocused)
    }

    @Test
    fun `stays out of accessibility and draws nothing`() {
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO, proxy.importantForAccessibility)
        val params = proxy.layoutParams
        assertTrue(params.width == 1 && params.height == 1)
        assertEquals(0, host.indexOfChild(proxy))
    }

    @Test
    fun `restores the focus order Flutter's view had`() {
        val before = host.descendantFocusability
        proxy.editing = true
        assertEquals(ViewGroup.FOCUS_AFTER_DESCENDANTS, host.descendantFocusability)
        proxy.editing = false
        assertEquals(before, host.descendantFocusability)
    }

    @Test
    fun `stops editing when Dart starts over`() {
        val view = FakeFlutterView(activity).also { activity.setContentView(it) }
        val reports = TextEditingReports(activity.resources) { view }
        reports.editing(true)
        val installed = view.getChildAt(0) as TextEditorProxy
        assertTrue(installed.onCheckIsTextEditor())

        // A debug hot restart: Dart starts again with no field focused, and asks first whether a
        // proxy is needed at all.
        reports.needed()

        assertFalse(installed.onCheckIsTextEditor())
        assertTrue(view.isFocused)
    }
}
