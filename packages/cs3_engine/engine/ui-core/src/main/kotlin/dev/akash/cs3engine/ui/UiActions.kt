package dev.akash.cs3engine.ui

import android.os.Build
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.AdapterView
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.SeekBar
import android.widget.Spinner
import android.widget.TextView

/** The person's actions, applied to an extension's views as a tap or an edit would be. Main thread only. */
object UiActions {
    fun apply(view: View, action: String, value: Any?) {
        when (action) {
            "click" -> click(view)
            "longClick" -> view.performLongClick()
            "check" -> {
                val toggle = view as? CompoundButton ?: throw IllegalArgumentException("node ${view.javaClass.simpleName} is no toggle")
                if (toggle.isChecked != (value == true)) toggle.performClick()
            }
            "text" -> {
                val field = view as? TextView ?: throw IllegalArgumentException("node ${view.javaClass.simpleName} holds no text")
                field.text = value?.toString().orEmpty()
                if (field is EditText) field.setSelection(field.text.length)
            }
            "submit" -> {
                val field = view as? TextView ?: throw IllegalArgumentException("node ${view.javaClass.simpleName} holds no text")
                val own = field.imeOptions and EditorInfo.IME_MASK_ACTION
                field.onEditorAction(if (own == EditorInfo.IME_ACTION_UNSPECIFIED || own == EditorInfo.IME_ACTION_NONE) EditorInfo.IME_ACTION_DONE else own)
            }
            "select" -> {
                val dropdown = view as? Spinner ?: throw IllegalArgumentException("node ${view.javaClass.simpleName} is no dropdown")
                dropdown.setSelection((value as? Number)?.toInt() ?: throw IllegalArgumentException("select needs an index"))
            }
            "slide" -> {
                val bar = view as? SeekBar ?: throw IllegalArgumentException("node ${view.javaClass.simpleName} is no slider")
                slide(bar, (value as? Number)?.toInt() ?: throw IllegalArgumentException("slide needs a value"))
            }
            else -> throw IllegalArgumentException("unknown action '$action'")
        }
    }

    /** A tap: the view's own click, or, for a list's item without a listener of its own, the list's item click. */
    private fun click(view: View) {
        val list = view.parent as? AdapterView<*>
        if (list != null && list !is Spinner && !view.hasOnClickListeners()) {
            val position = list.getPositionForView(view)
            if (position != AdapterView.INVALID_POSITION) {
                list.performItemClick(view, position, list.getItemIdAtPosition(position))
                return
            }
        }
        view.performClick()
    }

    /** A tap at [progress]'s place on the bar, so the extension's listener hears it as the person's (fromUser). */
    private fun slide(bar: SeekBar, progress: Int) {
        val min = if (Build.VERSION.SDK_INT >= 26) bar.min else 0
        val target = progress.coerceIn(min, bar.max)
        val width = bar.width - bar.paddingLeft - bar.paddingRight
        if (width > 0) {
            val x = bar.paddingLeft + width * (target - min).toFloat() / (bar.max - min).coerceAtLeast(1)
            val y = bar.height / 2f
            val down = SystemClock.uptimeMillis()
            for ((index, type) in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP).withIndex()) {
                val event = MotionEvent.obtain(down, down + index * 10L, type, x, y, 0)
                bar.dispatchTouchEvent(event)
                event.recycle()
            }
        }
        // Rounding on a narrow bar can land a step off: the value the person chose is the one that counts.
        if (bar.progress != target) bar.progress = target
    }
}
