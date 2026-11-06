package dev.akash.cs3engine.jvm

import android.content.Context
import android.content.res.Resources
import android.view.LayoutInflater
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.Spinner
import android.widget.TextView
import androidx.appcompat.widget.SwitchCompat
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class InflaterPartsTest {
    private val fixture = File(javaClass.getResource("/SkyStreamTest.cs3")!!.toURI())
    private val res = Resources.of(fixture, FrameworkClassLoader(javaClass.classLoader))
    private fun id(type: String, name: String) = res.getIdentifier(name, type, "dev.akash.cs3test")

    private inline fun <reified T : View> View.find(name: String): T = findViewById<View>(id("id", name)) as T

    @Test
    fun `every kind of element extensions use inflates, with its meaning, include and merge too`() {
        val parts = LayoutInflater.from(Context()).inflate(res.getLayout(id("layout", "test_parts")), null)
        val heading = parts.find<TextView>("heading")
        assertEquals("SkyStream test settings", heading.text.toString(), "the extension's own string")
        assertTrue(heading.typeface.isBold)
        assertEquals(40f, heading.textSize)

        val layout = parts.find<TextInputLayout>("token_layout")
        val field = parts.find<TextInputEditText>("token_field")
        assertEquals("Paste a token", field.hint.toString(), "the layout's hint is the field's")
        assertEquals(0x11, field.inputType, "textUri")
        assertTrue(layout.editText === field)

        val save = parts.find<View>("material_save")
        assertEquals("com.google.android.material.button.MaterialButton", save.javaClass.name)
        assertTrue(save is Button)
        assertEquals("Save", save.text.toString())
        assertEquals(2f, (save.layoutParams as LinearLayout.LayoutParams).weight)

        val loading = parts.find<ProgressBar>("loading")
        assertFalse(loading.isIndeterminate, "the horizontal style")
        assertEquals(10, loading.max)
        assertEquals(4, loading.progress)

        assertEquals(3, parts.find<Spinner>("choices").adapter.count)
        val agree = parts.find<CheckBox>("agree")
        assertTrue(agree.isChecked)
        assertFalse(agree.isEnabled)
        assertEquals("OK", agree.text.toString(), "Android's common string")
        assertEquals(View.GONE, parts.find<View>("gone").visibility)

        val card = parts.find<View>("card")
        assertTrue(card is FrameLayout, "CardView is a frame")
        val merged = parts.find<SwitchCompat>("merged_switch")
        assertEquals("Dark posters", merged.text.toString())
        assertTrue(merged.parent === card, "a merge's children go where the include stands")
        assertEquals("Close", parts.find<ImageButton>("merged_icon").contentDescription)
        assertEquals(View::class.java, parts.find<View>("unknown").javaClass, "a class no one has stands in empty")
    }
}
