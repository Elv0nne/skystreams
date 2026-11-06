package dev.akash.cs3engine.stubs

import android.content.Context
import android.graphics.Typeface
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.SeekBar
import android.widget.Space
import android.widget.TextView
import android.view.View
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class WidgetsTest {
    private val context = Context()

    @Test
    fun `a text view keeps its words, size and style, and its watchers hear each change`() {
        val text = TextView(context)
        assertEquals(28f, text.textSize, "Android's default 14sp, at density 2")
        text.textSize = 20f
        assertEquals(40f, text.textSize)
        text.setTypeface(null, Typeface.BOLD)
        assertTrue(text.typeface.isBold)
        val heard = mutableListOf<String>()
        text.addTextChangedListener(
            object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence, start: Int, count: Int, after: Int) {
                    heard += "before $s"
                }

                override fun onTextChanged(s: CharSequence, start: Int, before: Int, count: Int) {
                    heard += "on $s"
                }

                override fun afterTextChanged(s: Editable) {
                    heard += "after $s"
                }
            },
        )
        text.text = "Hello"
        assertEquals(listOf("before ", "on Hello", "after Hello"), heard)
        assertTrue(text.text is Editable, "with watchers, as on Android, the text is editable")
        text.append(", world")
        assertEquals("Hello, world", text.text.toString())
        text.setText(0x7f010001)
        assertEquals("", text.text.toString(), "an id the app doesn't have reads empty")
    }

    @Test
    fun `a field is editable, multi-line text until told otherwise, as on Android`() {
        val field = EditText(context)
        assertEquals(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE, field.inputType)
        field.setSingleLine()
        assertEquals(InputType.TYPE_CLASS_TEXT, field.inputType)
        field.setText("abc")
        val first = field.text
        assertEquals("abc", first.toString())
        field.setText(first)
        assertTrue(field.text !== first, "a new editable each time")
        field.setSelection(3)
        assertEquals(3, field.selectionStart)
        assertFailsWith<IndexOutOfBoundsException> { field.setSelection(9) }
        field.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        assertEquals(0x81, field.inputType)
    }

    @Test
    fun `a toggle flips on a tap, then clicks, and tells its listener once per change`() {
        val box = CheckBox(context)
        val changes = mutableListOf<Boolean>()
        var clicks = 0
        box.setOnCheckedChangeListener { _, checked ->
            changes += checked
            // An extension undoing the change from its listener: no recursion, as on Android.
            if (changes.size == 1) box.isChecked = false
        }
        box.setOnClickListener { clicks++ }
        assertTrue(box.performClick())
        assertEquals(listOf(true), changes)
        assertFalse(box.isChecked)
        assertEquals(1, clicks)
        box.isChecked = false
        assertEquals(1, changes.size, "the same state tells no one")
    }

    @Test
    fun `a radio group keeps one radio checked, by tap or by id`() {
        val group = RadioGroup(context)
        val fast = RadioButton(context).apply { id = 0x7f0a0011 }
        val careful = RadioButton(context)
        group.addView(fast)
        group.addView(careful)
        assertTrue(careful.id != View.NO_ID, "a radio without an id gets one")
        val heard = mutableListOf<Int>()
        group.setOnCheckedChangeListener { _, id -> heard += id }
        group.check(0x7f0a0011)
        assertTrue(fast.isChecked)
        careful.performClick()
        assertTrue(careful.isChecked)
        assertFalse(fast.isChecked)
        assertEquals(careful.id, group.checkedRadioButtonId)
        assertEquals(listOf(0x7f0a0011, careful.id), heard)
        careful.performClick()
        assertTrue(careful.isChecked, "a tap never unchecks a radio")
        group.clearCheck()
        assertEquals(View.NO_ID, group.checkedRadioButtonId)
    }

    @Test
    fun `a slider tells its listener whether the person moved it`() {
        val bar = SeekBar(context)
        assertFalse(bar.isIndeterminate)
        bar.max = 60
        val heard = mutableListOf<String>()
        bar.setOnSeekBarChangeListener(
            object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                    heard += "$progress $fromUser"
                }

                override fun onStartTrackingTouch(seekBar: SeekBar) {
                    heard += "start"
                }

                override fun onStopTrackingTouch(seekBar: SeekBar) {
                    heard += "stop"
                }
            },
        )
        bar.progress = 30
        Ui.acting { bar.progress = 90 }
        assertEquals(listOf("30 false", "start", "60 true", "stop"), heard, "clamped to max")
        assertTrue(ProgressBar(context).isIndeterminate, "Android's default progress bar spins")
    }

    @Test
    fun `layouts give their children the params Android gives`() {
        val row = LinearLayout(context)
        assertEquals(LinearLayout.HORIZONTAL, row.orientation)
        row.addView(View(context))
        assertEquals(ViewGroup.LayoutParams.WRAP_CONTENT, row.getChildAt(0).layoutParams.width)
        val column = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        column.addView(View(context))
        assertEquals(ViewGroup.LayoutParams.MATCH_PARENT, column.getChildAt(0).layoutParams.width)
        assertTrue(column.getChildAt(0).layoutParams is LinearLayout.LayoutParams)
        val weighted = View(context)
        row.addView(weighted, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        assertEquals(1f, (weighted.layoutParams as LinearLayout.LayoutParams).weight)
        val frame = FrameLayout(context)
        frame.addView(View(context), ViewGroup.LayoutParams(5, 6))
        assertTrue(frame.getChildAt(0).layoutParams is FrameLayout.LayoutParams, "params a group can't use are made its own")
        assertEquals(5, frame.getChildAt(0).layoutParams.width)
        assertEquals(View.INVISIBLE, Space(context).visibility)
    }

    @Test
    fun `a field inside a TextInputLayout takes its hint, as Material's does`() {
        val layout = TextInputLayout(context)
        val inner = FrameLayout(context)
        val field = TextInputEditText(context)
        inner.addView(field)
        layout.addView(inner)
        layout.hint = "Token"
        assertSame(field, layout.editText)
        assertEquals("Token", field.hint)
        val plain = TextInputEditText(context).apply { hint = "Own" }
        assertEquals("Own", plain.hint)
    }

    @Test
    fun `an image keeps its drawable and scale type`() {
        val image = ImageView(context)
        assertEquals(ImageView.ScaleType.FIT_CENTER, image.scaleType)
        image.scaleType = ImageView.ScaleType.CENTER_CROP
        image.setImageResource(0x01080038)
        assertEquals(ImageView.ScaleType.CENTER_CROP, image.scaleType)
        assertNull(image.drawable)
        assertEquals(listOf("MATRIX", "FIT_XY", "FIT_START", "FIT_CENTER", "FIT_END", "CENTER", "CENTER_CROP", "CENTER_INSIDE"), ImageView.ScaleType.values().map { it.name })
    }

    @Test
    fun `a web view keeps its page and clients, and answers scripts with null for now`() {
        val page = WebView(context)
        page.settings.javaScriptEnabled = true
        page.loadUrl("https://example.com/sign-in")
        assertEquals("https://example.com/sign-in", page.url)
        assertTrue(page.settings.javaScriptEnabled)
        val answered = CountDownLatch(1)
        var answer: String? = "unset"
        onMain {
            page.evaluateJavascript("document.title") {
                answer = it
                answered.countDown()
            }
        }
        assertTrue(answered.await(5, TimeUnit.SECONDS))
        assertEquals("null", answer)
    }
}
