package dev.akash.challenge_browser

import android.content.Context
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** Creates the platform view that shows a page: `ChallengeBrowserView` on the Dart side. */
internal class PageViewFactory(
    private val pages: (Long) -> Page?,
    private val host: () -> ViewGroup?,
    private val exit: (Long, FocusDirection) -> Unit,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as Map<*, *>
        val pageId = (params["pageId"] as Number).toLong()
        val container = PageContainer(context) { exit(pageId, it) }
        container.dpadInTabOrder = params["dpadInTabOrder"] == true
        return PageView(container, pages(pageId), host)
    }
}

/** Adopts the page's WebView while it shows, and hands it back to the hidden host afterwards. */
private class PageView(
    private val container: PageContainer,
    private val page: Page?,
    private val host: () -> ViewGroup?,
) : PlatformView {
    init {
        page?.show(container)
    }

    override fun getView(): View = container

    override fun dispose() {
        val host = host() ?: return
        page?.hide(container, host)
    }
}

/**
 * Holds a shown page and reports where keyboard and D-pad focus leave it: when the page has no more
 * controls in a direction, Android searches for the next view from here, and Flutter moves its own
 * focus on instead.
 */
internal class PageContainer(context: Context, private val exit: (FocusDirection) -> Unit) : FrameLayout(context) {
    /**
     * Flutter's focus is on the page. A layout pass that gives the WebView no size for a moment (the
     * on-screen keyboard resizing the window) takes Android's focus away; it is put back afterwards,
     * where the page left it, or keys would reach nothing.
     */
    var wantsFocus = false

    init {
        viewTreeObserver.addOnGlobalLayoutListener {
            val page = getChildAt(0) ?: return@addOnGlobalLayoutListener
            if (wantsFocus && !page.hasFocus() && page.isShown && page.width > 0 && page.height > 0) page.requestFocus()
        }
    }

    /** Where focus is leaving the page, while the WebView is still asking. */
    private var exiting: FocusDirection? = null

    /**
     * The D-pad moves through the page's controls in their focus order, as Tab and Shift+Tab do,
     * rather than to the nearest control in its direction. WebView's movement by position skips
     * controls inside a closed shadow root, such as Cloudflare's checkbox.
     */
    var dpadInTabOrder = false

    /**
     * Flutter's focus left the page. Not when Flutter hides the view for a frame, which clears
     * Android's focus too: focus comes back after the next layout, once the view shows again.
     */
    override fun clearFocus() {
        if (isShown) wantsFocus = false
        super.clearFocus()
    }

    /** The page took focus, by a touch as much as by Flutter. */
    override fun requestChildFocus(child: View?, focused: View?) {
        wantsFocus = true
        super.requestChildFocus(child, focused)
    }

    override fun focusSearch(focused: View?, direction: Int): View? {
        val towards = when (direction) {
            View.FOCUS_FORWARD -> FocusDirection.FORWARD
            View.FOCUS_BACKWARD -> FocusDirection.BACKWARD
            View.FOCUS_UP -> FocusDirection.UP
            View.FOCUS_DOWN -> FocusDirection.DOWN
            View.FOCUS_LEFT -> FocusDirection.LEFT
            View.FOCUS_RIGHT -> FocusDirection.RIGHT
            else -> return super.focusSearch(focused, direction)
        }
        leave(towards)
        // Focus stays here until Flutter moves it.
        return focused
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_DPAD_CENTER || event.keyCode == KeyEvent.KEYCODE_BUTTON_A) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) press(event)
            return true
        }
        if (dpadInTabOrder) {
            val back = event.keyCode == KeyEvent.KEYCODE_DPAD_UP || event.keyCode == KeyEvent.KEYCODE_DPAD_LEFT
            val ahead = event.keyCode == KeyEvent.KEYCODE_DPAD_DOWN || event.keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
            if (back || ahead) {
                val tab = KeyEvent(
                    event.downTime, event.eventTime, event.action, KeyEvent.KEYCODE_TAB, event.repeatCount,
                    if (back) KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON else 0,
                )
                return dispatchKeyEvent(tab)
            }
        }
        if (super.dispatchKeyEvent(event)) return true
        // Keys the page didn't use. Arrow keys at the page's edge arrive through focusSearch; Tab
        // may not, so it is handled here.
        if (event.action == KeyEvent.ACTION_DOWN && event.keyCode == KeyEvent.KEYCODE_TAB) {
            leave(if (event.isShiftPressed) FocusDirection.BACKWARD else FocusDirection.FORWARD)
            return true
        }
        return false
    }

    /**
     * A remote's OK, pressed on the page. WebView turns it into Enter, which ticks no checkbox (HTML
     * ticks on Space), so a challenge's checkbox couldn't be ticked from a remote. OK stays Enter on
     * links, text fields and lists, where Enter is what acts, and with nothing focused; everywhere
     * else it becomes Space. That includes a frame, and a closed shadow root, whose focused control the
     * page can't see: Cloudflare's checkbox is both. Only the person's own key changes: nothing is
     * clicked.
     */
    private fun press(ok: KeyEvent) {
        val page = getChildAt(0) as? android.webkit.WebView ?: return
        page.evaluateJavascript(TOGGLES) { toggles ->
            val key = if (toggles == "true") KeyEvent.KEYCODE_SPACE else ok.keyCode
            val time = android.os.SystemClock.uptimeMillis()
            page.dispatchKeyEvent(KeyEvent(time, time, KeyEvent.ACTION_DOWN, key, 0))
            page.dispatchKeyEvent(KeyEvent(time, time, KeyEvent.ACTION_UP, key, 0))
        }
    }

    private companion object {
        /** False where OK should stay Enter: a link, a text field, a list, or nothing focused. */
        const val TOGGLES = "(function(){var a=document.activeElement;" +
            "if(!a||a===document.body||a===document.documentElement||a.isContentEditable)return false;" +
            "var t=a.tagName;if(t==='A'||t==='TEXTAREA'||t==='SELECT')return false;" +
            "if(t==='INPUT')return /^(checkbox|radio|button|submit|reset|image)$/i.test(a.type);" +
            "return true;})()"
    }

    /**
     * Tab leaving the page makes WebView search twice in a row, to the side and then forward (or
     * backward): one exit is reported, the more specific direction winning.
     */
    private fun leave(direction: FocusDirection) {
        val first = exiting == null
        if (first || direction == FocusDirection.FORWARD || direction == FocusDirection.BACKWARD) exiting = direction
        if (!first) return
        post {
            val towards = exiting ?: return@post
            exiting = null
            wantsFocus = false
            exit(towards)
        }
    }
}
