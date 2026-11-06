package dev.akash.cs3engine.stubs

import android.content.Context
import android.content.res.Resources
import android.view.InflateException
import android.view.LayoutInflater
import android.view.View
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.SeekBar
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import org.xmlpull.v1.XmlPullParser
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class InflaterTest {
    private val context = Context()
    private val res = Resources.of(Fixtures.cs3, InflaterTest::class.java.classLoader)
    private val inflater = LayoutInflater.from(context)

    private fun id(type: String, name: String) = res.getIdentifier(name, type, "dev.akash.cs3test")

    private inline fun <reified T : View> View.find(name: String): T = findViewById<View>(id("id", name)) as T

    @Test
    fun `a view's attributes are set as it's made, so a custom view sees them in its init, as on Android`() {
        val xml = res.getLayout(id("layout", "test_parts"))
        while (!(xml.eventType == XmlPullParser.START_TAG && xml.name == "TextView")) xml.next()
        val custom = object : TextView(context, xml) {
            val textInInit = text.toString()
            val idInInit = id
        }
        assertEquals(res.getString(id("string", "title")), custom.textInInit)
        assertEquals(id("id", "heading"), custom.idInInit)
    }

    @Test
    fun `the test settings layout inflates into the views it names`() {
        val root = inflater.inflate(res.getLayout(id("layout", "test_settings")), null, false) as LinearLayout
        assertEquals(LinearLayout.VERTICAL, root.orientation)
        val title = root.find<TextView>("title")
        assertEquals(40f, title.textSize, "20sp at density 2")
        assertEquals(1f, (title.layoutParams as LinearLayout.LayoutParams).weight)
        assertTrue(root.find<View>("close") is ImageButton)
        assertTrue(root.find<View>("second") is CheckBox)
        assertTrue(root.find<View>("dark") is Switch)
        assertEquals(0x81, root.find<EditText>("token").inputType)
        assertTrue(root.find<View>("quality") is Spinner)
        val mode = root.find<RadioGroup>("mode")
        assertEquals(2, mode.childCount)
        assertTrue(mode.getChildAt(1) is RadioButton)
        assertEquals(60, root.find<SeekBar>("timeout").max)
        assertTrue(root.find<View>("items") is RecyclerView)
        assertEquals(LinearLayout.HORIZONTAL, (root.find<View>("save").parent as LinearLayout).orientation)
    }

    @Test
    fun `a layout attaches to its root, or takes the root's params without attaching`() {
        val layout = id("layout", "test_settings")
        val root = LinearLayout(context)
        assertSame(root, inflater.inflate(res.getLayout(layout), root, true))
        assertEquals(1, root.childCount)
        val alone = inflater.inflate(res.getLayout(layout), root, false)
        assertNull(alone.parent)
        assertTrue(alone.layoutParams is LinearLayout.LayoutParams)
        assertEquals(1, root.childCount)
    }

    @Test
    fun `a merge needs a root to attach to, as on Android`() {
        assertFailsWith<InflateException> { inflater.inflate(res.getLayout(id("layout", "test_merge")), null) }
        val root = LinearLayout(context)
        inflater.inflate(res.getLayout(id("layout", "test_merge")), root, true)
        assertEquals(2, root.childCount, "its children go straight into the root")
    }

    @Test
    fun `the app's context has no extension layouts, and a class no one has stands in empty, its children kept`() {
        assertFailsWith<Resources.NotFoundException> { inflater.inflate(id("layout", "test_settings"), null) }
        // Material's and AndroidX's classes come from the engine's framework loader, which these tests don't have.
        val parts = inflater.inflate(res.getLayout(id("layout", "test_parts")), null)
        assertEquals(View::class.java, parts.find<View>("unknown").javaClass)
        assertEquals<Class<*>>(android.widget.FrameLayout::class.java, parts.find<View>("card").javaClass, "a stand-in that keeps the include inside it")
        assertTrue(parts.find<View>("merged_icon") is ImageButton, "the include's views are there")
    }
}
