package dev.akash.cs3engine.android.ui

import android.content.Context
import android.os.SystemClock
import android.view.KeyEvent
import android.view.View
import android.webkit.WebView
import android.widget.FrameLayout

/**
 * Holds an extension's page while the sheet shows it, and reports where keyboard and D-pad focus leave it: when the
 * page has no more controls in a direction, Android searches for the next view from here, and Flutter moves its own
 * focus on instead ([exit] hears forward, backward, up, down, left or right). A remote's OK on a toggle is Space. The
 * full-screen view's page ([keepFocus]) keeps them: a game gets every arrow, and Back is its way out.
 */
internal class ExtensionPageContainer(
    context: Context,
    private val keepFocus: Boolean = false,
    private val exit: (String) -> Unit,
) : FrameLayout(context) {
    /** Flutter's focus is on the page: a layout that took Android's away (the keyboard resizing) gives it back. */
    var wantsFocus = false

    private var exiting: String? = null
    private var pendingFocus: Boolean? = null

    init {
        viewTreeObserver.addOnGlobalLayoutListener {
            val page = getChildAt(0) ?: return@addOnGlobalLayoutListener
            if (wantsFocus && !page.hasFocus() && page.isShown && page.width > 0 && page.height > 0) page.requestFocus()
            pendingFocus?.let { forward ->
                if (page.width > 0 && page.height > 0) {
                    pendingFocus = null
                    post { focusPage(forward) }
                }
            }
        }
    }

    private val page: WebView? get() = getChildAt(0) as? WebView

    /** Focus into the page, at its first control ([forward]) or its last. Before it has a size, once it has one. */
    fun focusPage(forward: Boolean) {
        val page = page ?: return
        if (page.width == 0 || page.height == 0) {
            pendingFocus = forward
            return
        }
        wantsFocus = true
        if (page.hasFocus()) return
        page.requestFocus(if (forward) View.FOCUS_DOWN else View.FOCUS_UP)
        // Outside touch mode WebView focuses the page's first control itself, inside frames too.
        if (!forward) page.evaluateJavascript(FOCUS_LAST, null) else if (page.isInTouchMode) page.evaluateJavascript(FOCUS_FIRST, null)
    }

    fun blurPage() {
        pendingFocus = null
        clearFocus()
    }

    override fun clearFocus() {
        if (isShown) wantsFocus = false
        super.clearFocus()
    }

    override fun requestChildFocus(child: View?, focused: View?) {
        wantsFocus = true
        super.requestChildFocus(child, focused)
    }

    override fun focusSearch(focused: View?, direction: Int): View? {
        val towards = when (direction) {
            View.FOCUS_FORWARD -> FORWARD
            View.FOCUS_BACKWARD -> BACKWARD
            View.FOCUS_UP -> UP
            View.FOCUS_DOWN -> DOWN
            View.FOCUS_LEFT -> LEFT
            View.FOCUS_RIGHT -> RIGHT
            else -> return super.focusSearch(focused, direction)
        }
        if (!keepFocus) focusLeft(towards)
        // Focus stays here until Flutter moves it.
        return focused
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_DPAD_CENTER || event.keyCode == KeyEvent.KEYCODE_BUTTON_A) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) press(event)
            return true
        }
        if (super.dispatchKeyEvent(event)) return true
        if (event.action == KeyEvent.ACTION_DOWN && event.keyCode == KeyEvent.KEYCODE_TAB) {
            if (!keepFocus) focusLeft(if (event.isShiftPressed) BACKWARD else FORWARD)
            return true
        }
        return false
    }

    /** A remote's OK: Space on a toggle (a challenge's checkbox), Enter elsewhere. Only the person's own key changes. */
    private fun press(ok: KeyEvent) {
        val page = page ?: return
        page.evaluateJavascript(TOGGLES) { toggles ->
            val key = if (toggles == "true") KeyEvent.KEYCODE_SPACE else ok.keyCode
            val time = SystemClock.uptimeMillis()
            page.dispatchKeyEvent(KeyEvent(time, time, KeyEvent.ACTION_DOWN, key, 0))
            page.dispatchKeyEvent(KeyEvent(time, time, KeyEvent.ACTION_UP, key, 0))
        }
    }

    /** Tab leaving makes WebView search twice in a row: one exit is reported, the more specific winning. */
    fun focusLeft(direction: String) {
        val first = exiting == null
        if (first || direction == FORWARD || direction == BACKWARD) exiting = direction
        if (!first) return
        post {
            val towards = exiting ?: return@post
            exiting = null
            wantsFocus = false
            exit(towards)
        }
    }

    companion object {
        const val FORWARD = "forward"
        const val BACKWARD = "backward"
        const val UP = "up"
        const val DOWN = "down"
        const val LEFT = "left"
        const val RIGHT = "right"

        private const val FOCUSABLE = "a[href],button,input,select,textarea,[tabindex]:not([tabindex=\\\"-1\\\"])"
        private const val FOCUS_FIRST = "(function(){var a=document.activeElement;if(a&&a!==document.body)return;" +
            "var e=document.querySelector('$FOCUSABLE');if(e)e.focus();})()"
        private const val FOCUS_LAST = "(function(){var e=document.querySelectorAll('$FOCUSABLE');" +
            "if(e.length)e[e.length-1].focus();})()"
        private const val TOGGLES = "(function(){var a=document.activeElement;" +
            "if(!a||a===document.body||a===document.documentElement||a.isContentEditable)return false;" +
            "var t=a.tagName;if(t==='A'||t==='TEXTAREA'||t==='SELECT')return false;" +
            "if(t==='INPUT')return /^(checkbox|radio|button|submit|reset|image)$/i.test(a.type);" +
            "return true;})()"
    }
}
