package dev.akash.cs3engine.ui

import android.app.Activity
import android.os.Looper
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.SeekBar
import android.widget.Spinner
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
class UiActionsTest {
    private val activity: Activity = Robolectric.buildActivity(Activity::class.java).setup().get()

    private fun show(view: View): View {
        activity.setContentView(LinearLayout(activity).apply { addView(view, 600, 600) })
        shadowOf(Looper.getMainLooper()).idle()
        return view
    }

    @Test
    fun `a click runs the view's listener, and a toggle's click toggles it first`() {
        var heard: Boolean? = null
        val box = CheckBox(activity).apply { setOnClickListener { heard = (it as CheckBox).isChecked } }
        UiActions.apply(box, "click", null)
        assertTrue(box.isChecked)
        assertEquals(true, heard)
    }

    @Test
    fun `check taps a toggle only when its state must change`() {
        var taps = 0
        val box = CheckBox(activity).apply { setOnClickListener { taps++ } }
        UiActions.apply(box, "check", true)
        UiActions.apply(box, "check", true)
        assertTrue(box.isChecked)
        assertEquals(1, taps)
        UiActions.apply(box, "check", false)
        assertFalse(box.isChecked)
    }

    @Test
    fun `text reaches the field's watchers`() {
        val seen = mutableListOf<String>()
        val field = EditText(activity).apply {
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    seen += s.toString()
                }
            })
        }
        UiActions.apply(field, "text", "abc123")
        assertEquals("abc123", field.text.toString())
        assertEquals(listOf("abc123"), seen)
    }

    @Test
    fun `submit runs the field's keyboard action`() {
        var action = -1
        val field = EditText(activity).apply {
            setOnEditorActionListener { _, id, _ ->
                action = id
                true
            }
        }
        UiActions.apply(field, "submit", null)
        assertEquals(EditorInfo.IME_ACTION_DONE, action)
    }

    @Test
    fun `select picks a dropdown option, which its listener hears`() {
        var picked = -1
        val spinner = Spinner(activity).apply {
            adapter = ArrayAdapter(activity, android.R.layout.simple_spinner_item, listOf("480p", "720p", "1080p"))
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                    picked = position
                }

                override fun onNothingSelected(parent: AdapterView<*>?) {}
            }
        }
        show(spinner)
        UiActions.apply(spinner, "select", 2)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(2, picked)
    }

    @Test
    fun `slide drags a slider, so its listener hears it as the person's`() {
        var heard: Pair<Int, Boolean>? = null
        val bar = SeekBar(activity).apply {
            max = 60
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                    heard = progress to fromUser
                }

                override fun onStartTrackingTouch(seekBar: SeekBar) {}
                override fun onStopTrackingTouch(seekBar: SeekBar) {}
            })
        }
        show(bar)
        UiActions.apply(bar, "slide", 30)
        assertEquals(30, bar.progress)
        assertEquals(true, heard?.second)
    }

    @Test
    fun `a click on a list's item without a listener of its own is the list's item click`() {
        var clicked = -1
        val list = ListView(activity).apply {
            adapter = ArrayAdapter(activity, android.R.layout.simple_list_item_1, listOf("One", "Two", "Three"))
            setOnItemClickListener { _, _, position, _ -> clicked = position }
        }
        show(list)
        UiActions.apply(list.getChildAt(2), "click", null)
        assertEquals(2, clicked)
    }

    @Test
    fun `unknown actions, and actions on the wrong kind of view, fail clearly`() {
        assertFailsWith<IllegalArgumentException> { UiActions.apply(CheckBox(activity), "fly", null) }
        assertFailsWith<IllegalArgumentException> { UiActions.apply(View(activity), "check", true) }
        assertFailsWith<IllegalArgumentException> { UiActions.apply(View(activity), "select", 1) }
    }
}
