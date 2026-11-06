package dev.akash.cs3engine.jvm

import android.content.Context
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.widget.SwitchCompat
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class GeneratedWidgetsTest {
    private val framework = FrameworkClassLoader(javaClass.classLoader)
    private val context = Context()

    private inline fun <reified T : View> make(name: String): T =
        framework.loadClass(name).getConstructor(Context::class.java).newInstance(context) as T

    @Test
    fun `Material's and AppCompat's widgets behave as the stand-ins they extend`() {
        val button = make<Button>("com.google.android.material.button.MaterialButton")
        var clicks = 0
        button.setOnClickListener { clicks++ }
        button.text = "Save"
        assertTrue(button.performClick())
        assertEquals(1, clicks)
        assertEquals("Save", button.text.toString())

        for (name in listOf("com.google.android.material.switchmaterial.SwitchMaterial", "com.google.android.material.materialswitch.MaterialSwitch")) {
            val switch = make<SwitchCompat>(name)
            switch.performClick()
            assertTrue(switch.isChecked, name)
        }

        val box = make<CheckBox>("com.google.android.material.checkbox.MaterialCheckBox")
        var heard = false
        box.setOnCheckedChangeListener { _, checked -> heard = checked }
        box.performClick()
        assertTrue(heard)

        val chip = make<CompoundButton>("com.google.android.material.chip.Chip")
        chip.isChecked = true
        assertTrue(chip.isChecked, "the stand-in's setChecked, not a no-op over it")

        val field = make<EditText>("androidx.appcompat.widget.AppCompatEditText")
        field.setText("token")
        assertEquals("token", field.text.toString())
        make<TextView>("com.google.android.material.textview.MaterialTextView").text = "Words"
        assertTrue(make<View>("com.google.android.material.card.MaterialCardView") is FrameLayout)
    }
}
