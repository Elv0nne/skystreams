package dev.akash.cs3engine.jvm

import android.app.Activity
import android.content.Context
import android.widget.ImageView
import com.lagradost.cloudstream3.utils.ImageLoader
import com.lagradost.cloudstream3.utils.UIHelper
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * CloudStream app classes on the stand-ins as shipped (filled, or made from the framework index), called as
 * extensions' settings screens call them.
 */
class AppClassesTest {
    private val colorPrimary = 0x01010433 // android.R.attr.colorPrimary

    @Test
    fun `UIHelper reads a colour off an activity's theme as Android reads an unset one — FStream's settings`() {
        assertEquals(0, with(UIHelper) { Activity().colorFromAttribute(colorPrimary) })
    }

    @Test
    fun `themed contexts made from the framework index have a theme too`() {
        val framework = FrameworkClassLoader(javaClass.classLoader)
        for (name in listOf("android.view.ContextThemeWrapper", "androidx.appcompat.view.ContextThemeWrapper")) {
            val made = framework.loadClass(name).getConstructor(Context::class.java, Int::class.java)
            assertNotNull((made.newInstance(Activity(), 0) as Context).theme, name)
        }
    }

    @Test
    fun `ImageLoader loads nothing into an image view — StreamCenter's settings icons`() {
        val view = ImageView(Activity())
        with(ImageLoader) { view.loadImage("https://example.com/icon.png") }
        assertNull(view.drawable)
    }
}
