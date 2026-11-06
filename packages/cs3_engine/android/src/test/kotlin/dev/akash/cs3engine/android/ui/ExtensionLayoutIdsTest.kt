package dev.akash.cs3engine.android.ui

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.view.ContextThemeWrapper
import androidx.appcompat.widget.AppCompatTextView
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertSame

/** The app's activity as SkyStream's extends it, themed as the app is. */
class ThemedHost : com.lagradost.cloudstream3.MainActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(com.google.android.material.R.style.Theme_MaterialComponents_DayNight_NoActionBar)
        super.onCreate(savedInstanceState)
    }
}

@RunWith(RobolectricTestRunner::class)
class ExtensionLayoutIdsTest {
    private val activity = Robolectric.buildActivity(ThemedActivity::class.java).setup().get()

    /**
     * An extension's id that lands on an app resource which is itself a reference, as the test extension's
     * `picked` landed on AppCompat's abc_search_url_text_selected (@android:color/black) on a device.
     */
    private val aliased = androidx.appcompat.R.color.abc_search_url_text_selected
    private fun aliasedElement() =
        Robolectric.buildAttributeSet().addAttribute(android.R.attr.id, "@color/abc_search_url_text_selected").build()
    private fun plainElement() = Robolectric.buildAttributeSet().addAttribute(android.R.attr.id, "@+id/title").build()

    @Test
    fun `a layout's id that lands on an app resource pointing elsewhere is kept as the layout gives it`() {
        // Android follows the reference: the view takes the resource it points at, and findViewById misses it.
        assertNotEquals(aliased, TextView(activity, aliasedElement()).id)
        val keeping = ExtensionLayoutIds { _, _, context, attrs -> TextView(context, attrs) }
        assertEquals(aliased, keeping.onCreateView(null, "TextView", activity, aliasedElement())!!.id)
    }

    @Test
    fun `every other view comes out as it was made`() {
        val made = TextView(activity)
        val keeping = ExtensionLayoutIds { _, _, _, _ -> made }
        assertSame(made, keeping.onCreateView(null, "TextView", activity, plainElement()))
        assertEquals(View.NO_ID, made.id, "an id that resolves to itself is left to the view")
        assertSame(made, keeping.onCreateView(null, "TextView", activity, Robolectric.buildAttributeSet().build()))
    }

    @Test
    fun `a view nothing else makes is made as the inflater would, only when its id needs keeping`() {
        val none = ExtensionLayoutIds { _, _, _, _ -> null }
        val made = none.onCreateView(null, "LinearLayout", activity, aliasedElement())
        assertIs<LinearLayout>(made)
        assertEquals(aliased, made.id)
        assertNull(none.onCreateView(null, "LinearLayout", activity, plainElement()), "left to the inflater")
        assertNull(none.onCreateView(null, "fragment", activity, aliasedElement()), "fragments are the fragment manager's")
    }

    @Test
    fun `the host activity's views come through it, AppCompat's widgets kept, and so do its clones'`() {
        val host = Robolectric.buildActivity(ThemedHost::class.java).setup().get()
        val factory = LayoutInflater.from(host).factory2
        assertIs<ExtensionLayoutIds>(factory)
        val view = factory.onCreateView(null, "TextView", host, aliasedElement())
        assertIs<AppCompatTextView>(view)
        assertEquals(aliased, view.id)
        val dialog = ContextThemeWrapper(host, com.google.android.material.R.style.Theme_MaterialComponents_Dialog)
        assertIs<ExtensionLayoutIds>(LayoutInflater.from(dialog).factory2)
    }
}
