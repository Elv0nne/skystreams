package dev.akash.cs3engine.android.ui

import android.app.Activity
import android.os.IBinder
import android.view.View
import android.view.WindowManager
import androidx.fragment.app.DialogFragment
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentManager
import java.io.File

/** Which extension, if any, a window being added belongs to. Main thread. */
internal class WindowOwners(
    private val pluginIn: (Throwable) -> File?,
    private val pluginOf: (Class<*>) -> File?,
    private val activity: () -> Activity?,
) {
    /** [plugin] owns the window; [fragment] is the DialogFragment whose dialog it is, if it's one. */
    class Owner(val plugin: File, val fragment: DialogFragment?)

    /**
     * The window's owner. A popup (a dropdown, a menu) is its parent window's ([capturedOwner] finds that
     * from the parent's token). A dialog of a DialogFragment is the fragment's extension's: the fragment
     * manager shows it, with no extension code on the stack. Anything else is the extension whose code is
     * adding it.
     */
    fun ownerOf(root: View, params: WindowManager.LayoutParams, capturedOwner: (IBinder?) -> File?): Owner? {
        if (params.type in WindowManager.LayoutParams.FIRST_SUB_WINDOW..WindowManager.LayoutParams.LAST_SUB_WINDOW) {
            capturedOwner(params.token)?.let { return Owner(it, null) }
        }
        val fragments = (activity() as? FragmentActivity)?.supportFragmentManager
        if (fragments != null) {
            dialogFragment(fragments, root)?.let { fragment -> pluginOf(fragment.javaClass)?.let { return Owner(it, fragment) } }
        }
        return pluginIn(Throwable())?.let { Owner(it, null) }
    }

    /** The extension whose code is running now, if any. Any thread: it looks at no fragments or captured windows. */
    fun onStack(): File? = pluginIn(Throwable())

    private fun dialogFragment(fragments: FragmentManager, root: View): DialogFragment? {
        for (fragment in fragments.fragments) {
            if (fragment is DialogFragment && fragment.dialog?.window?.peekDecorView() === root) return fragment
            if (!fragment.isAdded) continue
            runCatching { dialogFragment(fragment.childFragmentManager, root) }.getOrNull()?.let { return it }
        }
        return null
    }
}
