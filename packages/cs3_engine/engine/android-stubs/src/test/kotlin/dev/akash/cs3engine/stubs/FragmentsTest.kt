package dev.akash.cs3engine.stubs

import android.app.Dialog
import android.content.Context
import android.content.DialogInterface
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentDialog
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.DialogFragment
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentContainerView
import androidx.fragment.app.FragmentManager
import androidx.lifecycle.Lifecycle
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.bottomsheet.BottomSheetDialogFragment
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** A settings screen as extensions write one: a bottom sheet whose view is built in onCreateView. */
class SheetSettings : BottomSheetDialogFragment() {
    val heard = mutableListOf<String>()

    override fun onAttach(context: Context) {
        super.onAttach(context)
        heard += "attach"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        heard += "create"
    }

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
        heard += "createView"
        return LinearLayout(requireContext()).apply {
            orientation = LinearLayout.VERTICAL
            addView(TextView(context).apply { text = "Provider settings" })
        }
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        heard += "viewCreated ${viewLifecycleOwner.lifecycle.currentState}"
    }

    override fun onStart() {
        super.onStart()
        heard += "start"
    }

    override fun onResume() {
        super.onResume()
        heard += "resume"
    }

    override fun onPause() {
        super.onPause()
        heard += "pause"
    }

    override fun onStop() {
        super.onStop()
        heard += "stop"
    }

    override fun onDestroyView() {
        super.onDestroyView()
        heard += "destroyView"
    }

    override fun onDestroy() {
        super.onDestroy()
        heard += "destroy"
    }

    override fun onDetach() {
        super.onDetach()
        heard += "detach"
    }

    override fun onCancel(dialog: DialogInterface) {
        super.onCancel(dialog)
        heard += "cancel"
    }

    override fun onDismiss(dialog: DialogInterface) {
        super.onDismiss(dialog)
        heard += "dismiss"
    }
}

/** An alert from onCreateDialog, the other common shape. */
class Confirm : DialogFragment() {
    override fun onCreateDialog(savedInstanceState: Bundle?): Dialog =
        AlertDialog.Builder(requireContext()).setTitle("Restart required").setPositiveButton("Yes", null).create()
}

/** A page of words. */
class Page(private val label: String) : Fragment() {
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View =
        TextView(requireContext()).apply { text = label }
}

/** A fragment whose view holds a container for its children. */
class Host : Fragment() {
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View =
        LinearLayout(requireContext()).apply { addView(FragmentContainerView(context).apply { id = CONTAINER }) }

    companion object {
        const val CONTAINER = 0x7f0a0042
    }
}

class FragmentsTest {
    private val activity = AppCompatActivity()
    private val manager: FragmentManager get() = activity.supportFragmentManager

    @AfterTest
    fun clear() {
        Ui.windows().forEach { Ui.dismissed(it.owner) }
    }

    @Test
    fun `a bottom sheet fragment shown through the activity's manager shows its dialog as its own window`() {
        val settings = SheetSettings()
        settings.show(manager, "settings")
        drainMain()
        val window = Ui.windows().single()
        assertEquals("sheet", window.kind)
        assertSame(settings, window.fragment, "the window says whose it is")
        assertSame(settings.dialog, window.owner)
        assertTrue(settings.dialog is BottomSheetDialog)
        assertEquals(listOf("Provider settings"), texts(window.root))
        assertSame(settings, manager.findFragmentByTag("settings"))
        assertTrue(settings.isAdded && settings.isResumed)
        assertEquals(Lifecycle.State.RESUMED, settings.lifecycle.currentState)
    }

    @Test
    fun `a fragment goes up and down in Android's order, and dismissing it takes it and its window away`() {
        val settings = SheetSettings()
        settings.show(manager, "settings")
        drainMain()
        onMain { settings.dismiss() }
        drainMain()
        assertEquals(
            listOf(
                "attach", "create", "createView", "viewCreated INITIALIZED", "start", "resume",
                "dismiss", "pause", "stop", "destroyView", "destroy", "detach",
            ),
            settings.heard,
        )
        assertTrue(Ui.windows().isEmpty())
        assertNull(manager.findFragmentByTag("settings"))
        assertFalse(settings.isAdded)
        assertFailsWith<IllegalStateException> { settings.viewLifecycleOwner }
    }

    @Test
    fun `fluent calls on a fragment, its dialog and its activity keep going`() {
        // Review Focus 1: none of these may return a no-op's null.
        val settings = SheetSettings()
        settings.show(manager, "settings")
        drainMain()
        onMain {
            settings.requireDialog().window!!.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            (settings.dialog as BottomSheetDialog).behavior.state = BottomSheetBehavior.STATE_EXPANDED
            assertEquals(Lifecycle.State.RESUMED, settings.viewLifecycleOwner.lifecycle.currentState)
            assertSame(settings, settings.parentFragmentManager.findFragmentByTag("settings"))
            assertEquals(emptyList(), settings.childFragmentManager.fragments)
            assertSame(activity, settings.requireActivity())
            assertNotNull(settings.requireActivity().window)
            assertNotNull(settings.layoutInflater)
            assertFalse(settings.parentFragmentManager.isDestroyed)
            settings.requireComponentDialog().onBackPressedDispatcher.addCallback(
                settings,
                object : OnBackPressedCallback(true) {
                    override fun handleOnBackPressed() {}
                },
            )
        }
    }

    @Test
    fun `Back goes to a dialog's callback first, then cancels the dialog, which removes its fragment`() {
        val settings = SheetSettings()
        settings.show(manager, "settings")
        drainMain()
        var handled = 0
        val callback = object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                handled++
            }
        }
        onMain {
            val dialog = settings.requireComponentDialog()
            dialog.onBackPressedDispatcher.addCallback(callback)
            dialog.onBackPressed()
            assertEquals(1, handled)
            assertTrue(dialog.isShowing)
            callback.remove()
            dialog.onBackPressed()
            assertFalse(dialog.isShowing)
        }
        drainMain()
        assertEquals(listOf("cancel", "dismiss"), settings.heard.filter { it == "cancel" || it == "dismiss" })
        assertNull(manager.findFragmentByTag("settings"))
        assertTrue(Ui.windows().isEmpty())
    }

    @Test
    fun `an alert from onCreateDialog is the fragment's window, and its button removes the fragment`() {
        val confirm = Confirm()
        onMain { confirm.showNow(manager, "confirm") }
        val window = Ui.windows().single()
        assertEquals("alert", window.kind)
        assertSame(confirm, window.fragment)
        assertTrue(confirm.requireDialog() is ComponentDialog)
        assertEquals(listOf("Restart required", "Yes"), texts(window.root))
        onMain { (confirm.dialog as AlertDialog).getButton(DialogInterface.BUTTON_POSITIVE).performClick() }
        drainMain()
        assertNull(manager.findFragmentByTag("confirm"), "the button closed the alert, which removed its fragment")
        assertTrue(Ui.windows().isEmpty())
    }

    @Test
    fun `transactions replace, pop and hide children in their container, and a missing container fails as on Android`() {
        val host = Host()
        val first = Page("first")
        val second = Page("second")
        onMain {
            manager.beginTransaction().add(host, "host").commitNow()
            val children = host.childFragmentManager
            children.beginTransaction().replace(Host.CONTAINER, first).commitNow()
            children.beginTransaction().replace(Host.CONTAINER, second, "second").addToBackStack(null).commit()
            children.executePendingTransactions()
            val container = host.requireView().findViewById<ViewGroup>(Host.CONTAINER)
            assertEquals(listOf("second"), texts(container))
            assertEquals(1, children.backStackEntryCount)
            assertEquals(Lifecycle.State.CREATED, first.lifecycle.currentState, "kept by the back stack, without its view")
            assertTrue(children.popBackStackImmediate())
            assertEquals(listOf("first"), texts(container))
            assertSame(first, children.findFragmentById(Host.CONTAINER))
            assertNull(children.findFragmentByTag("second"))
            children.beginTransaction().hide(first).commitNow()
            assertEquals(View.GONE, first.requireView().visibility)
            assertTrue(first.isHidden)
            val error = assertFailsWith<IllegalArgumentException> {
                children.beginTransaction().add(0x7f0a0099, Page("lost")).commitNow()
            }
            assertContains(error.message.orEmpty(), "No view found for id 0x7f0a0099")
        }
    }

    @Test
    fun `lifecycle callbacks hear a manager's fragments, and recursive ones its children's too`() {
        val started = mutableListOf<String>()
        manager.registerFragmentLifecycleCallbacks(
            object : FragmentManager.FragmentLifecycleCallbacks() {
                override fun onFragmentStarted(fm: FragmentManager, f: Fragment) {
                    started += f.tag.orEmpty()
                }
            },
            true,
        )
        val host = Host()
        onMain {
            manager.beginTransaction().add(host, "host").commitNow()
            host.childFragmentManager.beginTransaction().add(Host.CONTAINER, Page("child"), "child").commitNow()
        }
        assertEquals(listOf("host", "child"), started)
    }
}
