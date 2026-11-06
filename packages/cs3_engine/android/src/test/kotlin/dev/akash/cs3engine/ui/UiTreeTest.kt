package dev.akash.cs3engine.ui

import android.content.Context
import android.graphics.Typeface
import android.text.InputType
import android.util.TypedValue
import android.view.ContextThemeWrapper
import android.view.View
import android.webkit.WebView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ProgressBar
import android.widget.RadioButton
import android.widget.SeekBar
import android.widget.Space
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import androidx.appcompat.widget.SwitchCompat
import androidx.recyclerview.widget.RecyclerView
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
class UiTreeTest {
    private val context: Context = ContextThemeWrapper(
        ApplicationProvider.getApplicationContext(),
        com.google.android.material.R.style.Theme_MaterialComponents_DayNight_NoActionBar,
    )
    private val ids = NodeIds()
    private val tree = UiTree(ids)

    @Test
    fun `each view's class gives its kind`() {
        val kinds = listOf(
            RadioButton(context) to "radio",
            Switch(context) to "switch",
            SwitchCompat(context) to "switch",
            CheckBox(context) to "checkbox",
            EditText(context) to "field",
            Button(context) to "button",
            TextView(context) to "text",
            ImageButton(context) to "iconButton",
            ImageView(context) to "image",
            Spinner(context) to "dropdown",
            SeekBar(context) to "slider",
            ProgressBar(context) to "progress",
            RecyclerView(context) to "list",
            ListView(context) to "list",
            WebView(context) to "page",
            LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL } to "row",
            LinearLayout(context).apply { orientation = LinearLayout.VERTICAL } to "column",
            FrameLayout(context) to "column",
            object : View(context) {} to "other",
        )
        for ((view, kind) in kinds) assertEquals(kind, UiTree.kind(view), view.javaClass.name)
    }

    @Test
    fun `a checkbox carries its words, its state and its tap`() {
        val box = CheckBox(context).apply {
            text = "Disney"
            isChecked = true
        }
        assertEquals(
            mapOf("id" to ids.of(box), "kind" to "checkbox", "tappable" to true, "text" to "Disney", "checked" to true),
            tree.node(box),
        )
    }

    @Test
    fun `a field carries its text, its hint and what it takes`() {
        val field = EditText(context).apply {
            setText("abc")
            hint = "Paste a token"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        val node = tree.node(field)!!
        assertEquals("abc", node["text"])
        assertEquals("Paste a token", node["hint"])
        assertEquals("password", node["input"])
        fun input(type: Int) = tree.node(EditText(context).apply { inputType = type })!!["input"]
        assertEquals("number", input(InputType.TYPE_CLASS_NUMBER))
        assertEquals("email", input(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS))
        assertEquals("url", input(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI))
        assertEquals("multiline", input(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE))
        assertEquals("text", input(InputType.TYPE_CLASS_TEXT))
    }

    @Test
    fun `large or bold text is a heading, and a button's text never is`() {
        fun text(sp: Float, bold: Boolean = false) = TextView(context).apply {
            text = "Words"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
            if (bold) setTypeface(typeface, Typeface.BOLD)
        }
        assertEquals(true, tree.node(text(20f))!!["heading"])
        assertEquals(true, tree.node(text(14f, bold = true))!!["heading"])
        assertNull(tree.node(text(14f))!!["heading"])
        val button = Button(context).apply {
            text = "Save"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
        }
        assertNull(tree.node(button)!!["heading"])
    }

    @Test
    fun `a dropdown carries its options and its selection`() {
        val spinner = Spinner(context).apply {
            adapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, listOf("480p", "720p", "1080p"))
            setSelection(2)
        }
        val node = tree.node(spinner)!!
        assertEquals(listOf("480p", "720p", "1080p"), node["options"])
        assertEquals(2, node["selected"])
    }

    @Test
    fun `a slider carries its value and range, and an indeterminate progress bar neither`() {
        val slider = SeekBar(context).apply {
            max = 60
            progress = 30
        }
        assertEquals(30, tree.node(slider)!!["value"])
        assertEquals(60, tree.node(slider)!!["max"])
        val spinning = ProgressBar(context).apply { isIndeterminate = true }
        assertNull(tree.node(spinning)!!["value"])
    }

    @Test
    fun `a disabled view says so, and a content description is its label`() {
        val button = ImageButton(context).apply {
            contentDescription = "Save settings"
            isEnabled = false
            setOnClickListener {}
        }
        val node = tree.node(button)!!
        assertEquals(false, node["enabled"])
        assertEquals("Save settings", node["label"])
        assertEquals(true, node["tappable"])
    }

    @Test
    fun `hidden views, bare views and spaces are left out`() {
        assertNull(tree.node(View(context)))
        assertNull(tree.node(Space(context)))
        assertNull(tree.node(TextView(context).apply { text = "gone"; visibility = View.GONE }))
        assertNull(tree.node(TextView(context).apply { text = "invisible"; visibility = View.INVISIBLE }))
    }

    @Test
    fun `a view keeps its number for the session`() {
        val box = CheckBox(context)
        val id = ids.of(box)
        assertEquals(id, ids.of(box))
        assertSame(box, ids.view(id))
        assertTrue(ids.of(CheckBox(context)) != id)
    }
}
