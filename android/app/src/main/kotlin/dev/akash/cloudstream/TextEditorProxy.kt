package dev.akash.skystream

import android.content.Context
import android.content.res.Resources
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection

/**
 * The text editor some televisions want to see before they give a keyboard a session.
 *
 * Android builds for low-memory televisions - Chromecast with Google TV among them - set
 * `config_preventImeStartupUnlessTextEditor`, and then start a keyboard's session only for a
 * focused view that calls itself a text editor. Flutter's view never does
 * (flutter/flutter#177360; the fix, flutter/flutter#193074, is not released yet). Its keyboard
 * still opens, but without a session the remote's D-pad is never offered to it: the arrows fall
 * through to Flutter, and nothing can be typed.
 *
 * So while a Flutter text field has focus, this view - one pixel, drawing nothing, the first child
 * of Flutter's - holds Android's focus in its place and says what Flutter's will not. The keyboard
 * is handed Flutter's own connection from [host], and the calls Flutter makes to the keyboard
 * about [host] are vouched for here. Flutter still sees every key first: [host] is this view's
 * parent, and a key goes through the parent on its way to the focused child.
 */
internal class TextEditorProxy private constructor(
    context: Context,
    private val host: ViewGroup,
) : View(context) {
    /** How [host] ordered its own focus against its children's before editing began. */
    private val hostFocusability = host.descendantFocusability

    /** Whether a Flutter text field has focus. */
    var editing = false
        set(value) {
            if (field == value) return
            field = value
            if (value) take() else giveBack()
        }

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        isFocusable = false
        isFocusableInTouchMode = false
    }

    override fun onCheckIsTextEditor(): Boolean = editing

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? =
        if (editing) host.onCreateInputConnection(outAttrs) else null

    /**
     * Whether a keyboard connection [view] made is one this view speaks for: [host]'s, or one
     * [host] speaks for in turn. Null, which the input method manager can pass, is no view.
     */
    override fun checkInputConnectionProxy(view: View?): Boolean =
        view != null && (view === host || host.checkInputConnectionProxy(view))

    private fun take() {
        isFocusable = true
        isFocusableInTouchMode = true
        // Flutter asks its view for focus each time it shows the keyboard. With the children
        // asked first, that request comes here instead of taking the editor away again.
        host.descendantFocusability = ViewGroup.FOCUS_AFTER_DESCENDANTS
        requestFocus()
    }

    private fun giveBack() {
        val hadFocus = isFocused
        host.descendantFocusability = hostFocusability
        // Only from here: a page in a platform view may hold the focus by now, typing into a
        // field of its own.
        if (hadFocus) host.requestFocus()
        isFocusable = false
        isFocusableInTouchMode = false
    }

    companion object {
        /** Puts a proxy into [host], Flutter's view, ahead of anything else in it. */
        fun installIn(host: ViewGroup): TextEditorProxy =
            TextEditorProxy(host.context, host).also {
                host.addView(it, 0, ViewGroup.LayoutParams(1, 1))
            }

        /** Whether this device gives a keyboard a session only for a text editor. */
        fun neededOn(resources: Resources): Boolean {
            val id = resources.getIdentifier(
                "config_preventImeStartupUnlessTextEditor",
                "bool",
                "android",
            )
            return id != 0 && resources.getBoolean(id)
        }
    }
}

/**
 * What android_text_editing.dart's calls on `dev.akash.skystream/text_input` do: say whether this
 * device needs a [TextEditorProxy], and keep the one in Flutter's view editing while a Flutter text
 * field has focus.
 */
internal class TextEditingReports(
    private val resources: Resources,
    /** Flutter's view, or null while there is none. */
    private val flutterView: () -> ViewGroup?,
) {
    /**
     * Put into Flutter's view the first time a field takes focus, which is only reported on a
     * device that needs one.
     */
    private var proxy: TextEditorProxy? = null

    /**
     * Dart's first call, each time it starts. It starts from no field focused, so the proxy does
     * too: after a debug hot restart it would otherwise go on editing for a field that has gone,
     * until one next took the focus and lost it.
     */
    fun needed(): Boolean {
        proxy?.editing = false
        return TextEditorProxy.neededOn(resources)
    }

    /** Whether a Flutter text field has focus. */
    fun editing(editing: Boolean) {
        if (editing || proxy != null) proxyInFlutterView()?.editing = editing
    }

    /**
     * The proxy in Flutter's view. Matched against the view rather than trusted, so a view built
     * again gets one of its own; a restore needs no such care, as it brings a new activity, and
     * with it new reports.
     */
    private fun proxyInFlutterView(): TextEditorProxy? {
        val view = flutterView() ?: return null
        proxy?.takeIf { it.parent === view }?.let { return it }
        return TextEditorProxy.installIn(view).also { proxy = it }
    }
}
