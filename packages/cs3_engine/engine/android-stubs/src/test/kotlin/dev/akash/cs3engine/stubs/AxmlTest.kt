package dev.akash.cs3engine.stubs

import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AxmlTest {
    private val ns = Axml.ANDROID
    private val table = ResourceTable(Arsc.read(Fixtures.arsc), "en")
    private fun layout() = Axml(Fixtures.entry("res/layout/test_settings.xml"))

    /** Moves [parser] to the start tag whose android:id is [name]'s. */
    private fun Axml.toId(name: String): Axml {
        val id = table.identifier("id", name)
        while (next() != XmlPullParser.END_DOCUMENT) {
            if (eventType == XmlPullParser.START_TAG && getAttributeResourceValue(ns, "id", 0) == id) return this
        }
        throw AssertionError("no element with id $name")
    }

    @Test
    fun `the test layout reads as Android compiled it`() {
        val parser = layout()
        assertEquals(XmlPullParser.START_DOCUMENT, parser.eventType)
        assertEquals(XmlPullParser.START_TAG, parser.nextTag())
        assertEquals("LinearLayout", parser.name)
        assertEquals(1, parser.depth)
        assertEquals(1, parser.getAttributeIntValue(ns, "orientation", -1), "vertical")
        assertEquals(-1, parser.getAttributeIntValue(ns, "layout_width", 0), "match_parent")
        assertEquals("16.0dip", parser.getAttributeValue(ns, "padding"))
        parser.toId("title")
        assertEquals("TextView", parser.name)
        val size = parser.attribute(ns, "textSize")!!
        assertEquals(Arsc.TYPE_DIMENSION, size.type)
        assertEquals(20f, Arsc.complexToFloat(size.data))
        assertEquals(2, size.data and 0xf, "sp")
        parser.toId("close")
        assertEquals(0x01, parser.getAttributeResourceValue(ns, "src", 0) ushr 24, "one of Android's own drawables")
        parser.toId("token")
        assertEquals(0x81, parser.getAttributeIntValue(ns, "inputType", 0), "textPassword")
        parser.toId("timeout")
        assertEquals(60, parser.getAttributeIntValue(ns, "max", 0))
        parser.toId("items")
        assertEquals("androidx.recyclerview.widget.RecyclerView", parser.name)
    }

    @Test
    fun `start and end tags pair up, at their depths, to the end of the document`() {
        val parser = layout()
        var starts = 0
        var ends = 0
        val open = ArrayDeque<Pair<String, Int>>()
        while (parser.next() != XmlPullParser.END_DOCUMENT) {
            when (parser.eventType) {
                XmlPullParser.START_TAG -> {
                    starts++
                    open.addLast(parser.name to parser.depth)
                }
                XmlPullParser.END_TAG -> {
                    ends++
                    assertEquals(open.removeLast(), parser.name to parser.depth)
                }
            }
        }
        assertEquals(starts, ends)
        assertEquals(21, starts, "the layout's 5 containers and 16 controls")
        assertEquals(XmlPullParser.END_DOCUMENT, parser.next(), "it stays at the end")
    }

    @Test
    fun `attributes read by index, typed and as text`() {
        val parser = layout().toId("second_label")
        val clickable = (0 until parser.attributeCount).single { parser.getAttributeName(it) == "clickable" }
        assertEquals(ns, parser.getAttributeNamespace(clickable))
        assertEquals("true", parser.getAttributeValue(clickable))
        assertTrue(parser.getAttributeBooleanValue(clickable, false))
        assertTrue(parser.getAttributeNameResource(clickable) ushr 24 == 0x01, "android:clickable's id")
        assertNull(parser.getAttributeValue(ns, "missing"))
        assertEquals(5, parser.getAttributeIntValue(ns, "missing", 5))
    }

    @Test
    fun `require and nextText behave as XmlPull says`() {
        val parser = layout()
        parser.nextTag()
        parser.require(XmlPullParser.START_TAG, null, "LinearLayout")
        assertFailsWith<XmlPullParserException> { parser.require(XmlPullParser.END_TAG, null, "LinearLayout") }
        parser.toId("token")
        assertEquals("", parser.nextText(), "an element with no text")
        assertEquals(XmlPullParser.END_TAG, parser.eventType)
    }
}
