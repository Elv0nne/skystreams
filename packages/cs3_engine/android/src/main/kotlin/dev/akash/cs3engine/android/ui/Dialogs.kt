package dev.akash.cs3engine.android.ui

import android.annotation.SuppressLint
import android.app.Dialog
import android.content.DialogInterface
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.Window
import androidx.appcompat.view.WindowCallbackWrapper
import java.lang.reflect.Field

/** The [Dialog] a captured window belongs to, for closing it as Back does. */
internal object Dialogs {
    /** A decor view's window: not in the SDK, but open to apps (greylisted) on every Android since 7. */
    private val decorWindow: Field? by lazy(LazyThreadSafetyMode.NONE) {
        runCatching {
            Class.forName("com.android.internal.policy.DecorView").getDeclaredField("mWindow").apply { isAccessible = true }
        }.getOrNull()
    }

    /** A dialog's key listener: Dialog keeps it private (the hidden-API "unsupported" list, as [decorWindow]). */
    private val keyListener: Field? by lazy(LazyThreadSafetyMode.NONE) {
        runCatching { Dialog::class.java.getDeclaredField("mOnKeyListener").apply { isAccessible = true } }
            .onFailure { Log.w("cs3", "a dialog's key listener can't be read, so Back goes to the dialog itself: $it") }
            .getOrNull()
    }

    /**
     * Back as Android's Back key reaches [dialog] without predictive back (Phase 7c's §3): its key listener gets Back's
     * down and up. True when it took either: the dialog's own Back is then left alone.
     */
    fun keyBack(dialog: Dialog): Boolean {
        val listener = runCatching { keyListener?.get(dialog) as? DialogInterface.OnKeyListener }.getOrNull() ?: return false
        val (down, up) = backKeys()
        val tookDown = listener.onKey(dialog, KeyEvent.KEYCODE_BACK, down)
        val tookUp = listener.onKey(dialog, KeyEvent.KEYCODE_BACK, up)
        return tookDown || tookUp
    }

    /**
     * Back's down and up as the device's own Back key makes them: timed now, the up's downTime its down's. A listener
     * that times its double Back from eventTime would take a Back timed 0 for its second.
     */
    fun backKeys(): Pair<KeyEvent, KeyEvent> {
        val now = SystemClock.uptimeMillis()
        return KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK, 0) to
            KeyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK, 0)
    }

    /** The dialog whose window [root] is: the window calls back to it, through AppCompat's wrapper if it has one. */
    @SuppressLint("RestrictedApi")
    fun of(root: View): Dialog? {
        val field = decorWindow?.takeIf { it.declaringClass.isInstance(root) } ?: return null
        var callback = runCatching { (field.get(root) as? Window)?.callback }.getOrNull()
        while (callback is WindowCallbackWrapper) callback = callback.wrapped
        return callback as? Dialog
    }
}
