package dev.akash.cs3engine.android.ui

import android.os.Binder
import android.os.Bundle
import android.os.Looper
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.DialogFragment
import com.google.android.material.bottomsheet.BottomSheetDialog
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** An AppCompat activity, themed as SkyStream's will be. */
class ThemedActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(com.google.android.material.R.style.Theme_MaterialComponents_DayNight_NoActionBar)
        super.onCreate(savedInstanceState)
    }
}

/** Stands for an extension's settings fragment. */
class ExtensionDialog : DialogFragment()

@RunWith(RobolectricTestRunner::class)
class WindowsTest {
    private val activity = Robolectric.buildActivity(ThemedActivity::class.java).setup().get()
    private val plugin = File("/plugins/Test.cs3")

    @Test
    fun `hiding makes a window invisible, untouchable, unfocusable, undimmed and unanimated`() {
        val params = WindowManager.LayoutParams().apply {
            flags = WindowManager.LayoutParams.FLAG_DIM_BEHIND
            dimAmount = 0.6f
            windowAnimations = 42
        }
        assertFalse(Hiding.isHidden(params))
        Hiding.hide(params)
        assertEquals(0f, params.alpha)
        assertEquals(0f, params.dimAmount)
        assertEquals(0, params.flags and WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        assertEquals(0, params.windowAnimations)
        assertTrue(Hiding.isHidden(params))
        params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
        assertFalse(Hiding.isHidden(params), "a window made focusable again isn't hidden any more")
    }

    @Test
    fun `a window's kind comes from its type and content`() {
        val popup = WindowManager.LayoutParams(WindowManager.LayoutParams.TYPE_APPLICATION_PANEL)
        assertEquals("popup", Kinds.of(FrameLayout(activity), popup))
        val sheet = BottomSheetDialog(activity).apply { setContentView(View(activity)) }
        assertEquals("sheet", Kinds.of(sheet.window!!.decorView, WindowManager.LayoutParams()))
        val alert = FrameLayout(activity).apply { addView(Button(activity).apply { id = android.R.id.button1 }) }
        assertEquals("alert", Kinds.of(alert, WindowManager.LayoutParams()))
        assertEquals("dialog", Kinds.of(FrameLayout(activity), WindowManager.LayoutParams()))
    }

    @Test
    fun `an extension's dialog fragment owns its dialog's window`() {
        val fragment = ExtensionDialog()
        fragment.show(activity.supportFragmentManager, "settings")
        activity.supportFragmentManager.executePendingTransactions()
        shadowOf(Looper.getMainLooper()).idle()
        val owners = WindowOwners(pluginIn = { null }, pluginOf = { if (it == ExtensionDialog::class.java) plugin else null }, activity = { activity })
        val owner = owners.ownerOf(fragment.dialog!!.window!!.decorView, WindowManager.LayoutParams()) { null }
        assertEquals(plugin, owner?.plugin)
        assertSame(fragment, owner?.fragment)
    }

    @Test
    fun `an extension's code on the stack owns a plain dialog, and a popup belongs to its window's owner`() {
        val owners = WindowOwners(pluginIn = { plugin }, pluginOf = { null }, activity = { activity })
        assertEquals(plugin, owners.ownerOf(FrameLayout(activity), WindowManager.LayoutParams()) { null }?.plugin)
        val token = Binder()
        val popup = WindowManager.LayoutParams(WindowManager.LayoutParams.TYPE_APPLICATION_PANEL).apply { this.token = token }
        val other = File("/plugins/Other.cs3")
        val nobody = WindowOwners(pluginIn = { null }, pluginOf = { null }, activity = { activity })
        assertEquals(other, nobody.ownerOf(FrameLayout(activity), popup) { if (it === token) other else null }?.plugin)
    }

    @Test
    fun `a window no extension made has no owner`() {
        val owners = WindowOwners(pluginIn = { null }, pluginOf = { null }, activity = { activity })
        assertNull(owners.ownerOf(FrameLayout(activity), WindowManager.LayoutParams()) { null })
    }

    @Test
    fun `the hook's lists tell their listener of each window before it's added, and of updates and removals`() {
        val calls = mutableListOf<String>()
        val roots = mutableListOf<View>()
        val listener = object : WindowHook.Listener {
            override fun adding(root: View, params: WindowManager.LayoutParams) {
                calls += "adding ${roots.contains(root)}"
                params.alpha = 0f
            }

            override fun updating(root: View, params: WindowManager.LayoutParams) {
                calls += "updating"
            }

            override fun removed(root: View) {
                calls += "removed"
            }
        }
        val views = WindowHook.Roots(emptyList()) { listener }
        val params = WindowHook.Params(emptyList(), views) { listener }
        val root = FrameLayout(activity).apply { layoutParams = WindowManager.LayoutParams() }
        views.add(root)
        roots += views
        params.add(root.layoutParams as WindowManager.LayoutParams)
        assertEquals(0f, (root.layoutParams as WindowManager.LayoutParams).alpha, "the listener changed the params before the window existed")
        // WindowManagerGlobal.updateViewLayout: remove(index), then add(index, params).
        params.removeAt(0)
        params.add(0, WindowManager.LayoutParams())
        views.removeAt(0)
        assertEquals(listOf("adding false", "updating", "removed"), calls)
    }
}
