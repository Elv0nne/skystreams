package dev.akash.cs3engine.android

import android.util.TypedValue
import android.view.ContextThemeWrapper
import android.widget.ImageView
import androidx.test.core.app.ApplicationProvider
import com.lagradost.cloudstream3.utils.ImageLoader
import com.lagradost.cloudstream3.utils.UIHelper
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import kotlin.test.assertEquals
import kotlin.test.assertNull

@RunWith(RobolectricTestRunner::class)
class AppClassesTest {
    private val context = ContextThemeWrapper(
        ApplicationProvider.getApplicationContext(),
        com.google.android.material.R.style.Theme_MaterialComponents_DayNight_NoActionBar,
    )

    @Test
    fun `FStream colours its settings with a theme attribute`() {
        val expected = TypedValue().also { context.theme.resolveAttribute(androidx.appcompat.R.attr.colorPrimary, it, true) }.data
        with(UIHelper) { assertEquals(expected, context.colorFromAttribute(androidx.appcompat.R.attr.colorPrimary)) }
    }

    @Test
    fun `StreamCenter's icon loading is there with its default arguments, and does nothing`() {
        // What StreamCenter's code calls: the static default-arguments form of the extension function.
        val method = ImageLoader::class.java.getDeclaredMethod(
            "loadImage\$default",
            ImageLoader::class.java,
            ImageView::class.java,
            String::class.java,
            Map::class.java,
            Function1::class.java,
            Int::class.javaPrimitiveType,
            Any::class.java,
        )
        val view = ImageView(context)
        method.invoke(null, ImageLoader, view, "https://example.invalid/icon.png", null, null, 0b110, null)
        assertNull(view.drawable)
    }
}
