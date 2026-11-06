package dev.akash.cs3engine.ui

import android.content.Context
import android.graphics.Typeface
import android.text.InputType
import android.util.TypedValue
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
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** Part 1's Android UiTreeTest, on the stand-ins. */
class UiTreeTest {
    private val context = Context()
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

    @Test
    fun `words Android left as a raw reference read as the extension's own — AnimeUnity's icon buttons`() {
        val words = mapOf(0x7f040025 to "Salva")
        val tree = UiTree(NodeIds()) { id -> words[id] }
        val save = ImageButton(context).apply { contentDescription = "@${0x7f040025}" }
        assertEquals("Salva", tree.node(save)!!["label"])
        val field = EditText(context).apply { hint = "@${0x7f040025}" }
        assertEquals("Salva", tree.node(field)!!["hint"])
        // Words that only look like one, or name nothing the extension has, stay as they are.
        assertEquals("@2024", tree.node(TextView(context).apply { text = "@2024" })!!["text"])
        val unknown = ImageButton(context).apply { contentDescription = "@${0x7f040026}" }
        assertEquals("@${0x7f040026}", tree.node(unknown)!!["label"])
    }

    @Test
    fun `a window's words are its texts and labels in reading order, blank and hidden ones left out`() {
        val window = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(TextView(context).apply { text = "Support us" })
            addView(TextView(context).apply { text = "  " })
            addView(ImageButton(context).apply { contentDescription = "Close" })
            addView(TextView(context).apply { text = "Hidden"; visibility = View.GONE })
            addView(Button(context).apply { text = "Donate" })
        }
        assertEquals(listOf("Support us", "Close", "Donate"), UiTree(NodeIds()).wordsOf(window))
    }

    @Test
    fun `a page's stand-in reads as that page, with the page's number`() {
        val ids = NodeIds()
        val tree = UiTree(ids)
        val page = WebView(context)
        val column = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(TextView(context).apply { text = "Sign in" })
            addView(page)
        }
        val before = tree.window("w1", "dialog", null, true, column, null)
        val number = ids.of(page)
        // Android lends the page to the sheet: a stand-in takes its slot meanwhile.
        val standIn = object : View(context), PageStandIn {
            override val page: View = page
        }
        column.removeView(page)
        column.addView(standIn, 1)
        assertEquals(before, tree.window("w1", "dialog", null, true, column, null), "the same tree, the same page node")
        assertEquals(number, ids.of(standIn))
        assertSame(page, ids.view(number), "its number still names the page itself")
    }

    @Test
    fun `a window says when it asks for the whole screen, the screen kept on, or an orientation`() {
        // Phase 7c's §1 and §5: the keys come only when asked for, so every other window reads as before.
        val root = TextView(context).apply { text = "Game" }
        val plain = tree.window("w1", "dialog", null, true, root, null)
        assertFalse("fullScreen" in plain || "keepScreenOn" in plain || "orientation" in plain)
        val game = tree.window("w2", "dialog", null, true, root, null, fullScreen = true, keepScreenOn = true, orientation = 6)
        assertEquals(true, game["fullScreen"])
        assertEquals(true, game["keepScreenOn"])
        assertEquals(6, game["orientation"])
    }
}
