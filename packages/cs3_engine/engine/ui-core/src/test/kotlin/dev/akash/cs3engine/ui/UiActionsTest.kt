package dev.akash.cs3engine.ui

import android.content.Context
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ListView
import android.widget.SeekBar
import android.widget.Spinner
import dev.akash.cs3engine.stubs.Ui
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Part 1's Android UiActionsTest, on the stand-ins. */
class UiActionsTest {
    private val context = Context()

    @Test
    fun `a click runs the view's listener, and a toggle's click toggles it first`() {
        var heard: Boolean? = null
        val box = CheckBox(context).apply { setOnClickListener { heard = (it as CheckBox).isChecked } }
        UiActions.apply(box, "click", null)
        assertTrue(box.isChecked)
        assertEquals(true, heard)
    }

    @Test
    fun `check taps a toggle only when its state must change`() {
        var taps = 0
        val box = CheckBox(context).apply { setOnClickListener { taps++ } }
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
        val field = EditText(context).apply {
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
        val field = EditText(context).apply {
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
        // A stand-in Spinner tells its listener after the main thread's current task, as Android's does.
        val picked = CompletableFuture<Int>()
        val spinner = Spinner(context).apply {
            adapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, listOf("480p", "720p", "1080p"))
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                    if (position == 2) picked.complete(position)
                }

                override fun onNothingSelected(parent: AdapterView<*>?) {}
            }
        }
        UiActions.apply(spinner, "select", 2)
        assertEquals(2, picked.get(5, TimeUnit.SECONDS))
    }

    @Test
    fun `slide moves a slider, so its listener hears it as the person's`() {
        // A stand-in has no size to drag across: the change is the person's because the action runs as theirs
        // (Ui.acting, as the engine's host runs every action).
        var heard: Pair<Int, Boolean>? = null
        val bar = SeekBar(context).apply {
            max = 60
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                    heard = progress to fromUser
                }

                override fun onStartTrackingTouch(seekBar: SeekBar) {}
                override fun onStopTrackingTouch(seekBar: SeekBar) {}
            })
        }
        Ui.acting { UiActions.apply(bar, "slide", 30) }
        assertEquals(30, bar.progress)
        assertEquals(true, heard?.second)
    }

    @Test
    fun `a click on a list's item without a listener of its own is the list's item click`() {
        var clicked = -1
        val list = ListView(context).apply {
            adapter = ArrayAdapter(context, android.R.layout.simple_list_item_1, listOf("One", "Two", "Three"))
            setOnItemClickListener { _, _, position, _ -> clicked = position }
        }
        UiActions.apply(list.getChildAt(2), "click", null)
        assertEquals(2, clicked)
    }

    @Test
    fun `unknown actions, and actions on the wrong kind of view, fail clearly`() {
        assertFailsWith<IllegalArgumentException> { UiActions.apply(CheckBox(context), "fly", null) }
        assertFailsWith<IllegalArgumentException> { UiActions.apply(View(context), "check", true) }
        assertFailsWith<IllegalArgumentException> { UiActions.apply(View(context), "select", 1) }
    }
}
