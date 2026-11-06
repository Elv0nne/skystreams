package dev.akash.cs3engine.stubs

import android.content.res.ColorStateList
import android.content.res.Configuration
import android.content.res.TypedArray
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.text.Editable
import android.text.InputType
import android.text.SpannableString
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextPaint
import android.util.DisplayMetrics
import android.util.TypedValue
import android.view.inputmethod.EditorInfo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class ValuesTest {
    @Test
    fun `typefaces say bold as Android does, by style or by weight`() {
        assertFalse(Typeface.DEFAULT.isBold)
        assertTrue(Typeface.DEFAULT_BOLD.isBold)
        assertEquals(Typeface.BOLD, Typeface.create(Typeface.DEFAULT, Typeface.BOLD).style)
        assertTrue(Typeface.create(Typeface.DEFAULT, Typeface.BOLD_ITALIC).isItalic)
        assertTrue(Typeface.create(Typeface.DEFAULT, 700, false).isBold)
        assertFalse(Typeface.create("sans-serif-medium", Typeface.NORMAL).isBold)
    }

    @Test
    fun `paint keeps its flags, fake bold and underline among them`() {
        val paint = TextPaint()
        paint.isFakeBoldText = true
        paint.flags = paint.flags or Paint.UNDERLINE_TEXT_FLAG
        assertTrue(paint.isFakeBoldText)
        assertEquals(Paint.FAKE_BOLD_TEXT_FLAG or Paint.UNDERLINE_TEXT_FLAG, paint.flags)
        paint.textSize = 28f
        assertEquals(28f, Paint(paint).textSize, "a copy keeps the size")
    }

    @Test
    fun `colours parse and build as Android's do`() {
        assertEquals(0x80FF0000.toInt(), Color.parseColor("#80FF0000"))
        assertEquals(0xFF336699.toInt(), Color.parseColor("#336699"))
        assertEquals(0xFF008080.toInt(), Color.parseColor("teal"))
        assertFailsWith<IllegalArgumentException> { Color.parseColor("#123") }
        assertFailsWith<IllegalArgumentException> { Color.parseColor("chartreuse-ish") }
        assertEquals(0xFF102030.toInt(), Color.rgb(0x10, 0x20, 0x30))
        assertEquals(0x40, Color.alpha(Color.argb(0x40, 1, 2, 3)))
        assertEquals(0x20, Color.green(0xFF102030.toInt()))
        assertEquals(Color.RED, ColorDrawable(Color.RED).color)
        assertEquals(Color.BLUE, ColorStateList.valueOf(Color.BLUE).defaultColor)
    }

    @Test
    fun `dimensions convert at the stand-ins' density`() {
        val metrics = DisplayMetrics()
        assertEquals(32f, TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 16f, metrics))
        assertEquals(40f, TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 20f, metrics))
        assertEquals(5f, TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_PX, 5f, metrics))
        val sixteenDp = (16 shl 8) or TypedValue.COMPLEX_UNIT_DIP
        assertEquals(16f, TypedValue.complexToFloat(sixteenDp))
        assertEquals(32, TypedValue.complexToDimensionPixelSize(sixteenDp, metrics))
        val quarter = (32 shl 8) or (1 shl 4) // 0.25 px: mantissa 32 at radix 16p7 (1/128)
        assertEquals(0.25f, TypedValue.complexToFloat(quarter))
        assertEquals(1, TypedValue.complexToDimensionPixelSize(quarter, metrics), "a size under a pixel is still one, as Android's")
    }

    @Test
    fun `the configuration is dark and portrait, in the app's language`() {
        val config = Configuration()
        assertTrue(config.isNightModeActive)
        assertEquals(Configuration.UI_MODE_NIGHT_YES, config.uiMode and Configuration.UI_MODE_NIGHT_MASK)
        assertEquals(Configuration.UI_MODE_TYPE_NORMAL, config.uiMode and Configuration.UI_MODE_TYPE_MASK)
        assertEquals(Configuration.ORIENTATION_PORTRAIT, config.orientation)
        assertEquals(1f, config.fontScale)
        val before = System.getProperty("cs3.language")
        try {
            System.setProperty("cs3.language", "hi")
            assertEquals("hi", Configuration().locales[0].language)
            assertEquals("hi", Configuration().locale.language)
        } finally {
            if (before == null) System.clearProperty("cs3.language") else System.setProperty("cs3.language", before)
        }
        assertEquals("en", Configuration().locales[0].language, "English until the app says")
    }

    @Test
    fun `a typed array gives the defaults Android gives for attributes that aren't set`() {
        val array = TypedArray(3)
        assertEquals(3, array.length())
        assertFalse(array.hasValue(0))
        assertEquals(7, array.getInt(1, 7))
        assertEquals(true, array.getBoolean(2, true))
        assertEquals(4.5f, array.getDimension(0, 4.5f))
        assertNull(array.getString(0))
        assertEquals(-1, array.getResourceId(0, -1))
        array.recycle()
    }

    @Test
    fun `an editable edits in place, and keeps no spans`() {
        val text: Editable = SpannableStringBuilder("Hello")
        text.append(", world").insert(0, ">> ").replace(0, 3, "")
        assertEquals("Hello, world", text.toString())
        text.delete(5, text.length)
        assertEquals("Hello", text.toString())
        text.setSpan(Any(), 0, 2, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        assertEquals(0, text.getSpans(0, text.length, Any::class.java).size)
        assertEquals("ell", text.subSequence(1, 4).toString())
        text.clear()
        assertEquals(0, text.length)
        val fixed = SpannableString.valueOf("Fixed")
        assertEquals("Fixed", fixed.toString())
        assertSame(fixed, SpannableString.valueOf(fixed))
    }

    @Test
    fun `input types and editor actions have Android's numbers`() {
        assertEquals(0x81, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        assertEquals(6, EditorInfo.IME_ACTION_DONE)
        assertEquals(0xff, EditorInfo.IME_MASK_ACTION)
    }
}
