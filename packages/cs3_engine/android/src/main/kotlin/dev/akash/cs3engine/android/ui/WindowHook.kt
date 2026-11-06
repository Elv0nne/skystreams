package dev.akash.cs3engine.android.ui

import android.view.View
import android.view.WindowManager
import dev.akash.cs3engine.host.HostHooks

/**
 * Sees every window the app adds, before it exists, and every change to its parameters (as Square's
 * Curtains does): WindowManagerGlobal's `mViews` and `mParams` lists, swapped for lists that tell a
 * [Listener]. Both fields are on Android's "unsupported" hidden-API list, allowed at targetSdk 37
 * (API 36). A plain wrapped WindowManager can't do this: `Window.setWindowManager` casts it to the
 * final `WindowManagerImpl`. The calls come on the thread adding the window (the main thread), under
 * WindowManagerGlobal's lock: a listener must be quick, and must not add or remove windows.
 */
internal object WindowHook {
    interface Listener {
        /** [root]'s window is about to be added with [params], which can still change. */
        fun adding(root: View, params: WindowManager.LayoutParams)

        /** [root]'s window is about to take [params] (an `updateViewLayout`). */
        fun updating(root: View, params: WindowManager.LayoutParams)

        fun removed(root: View)
    }

    @Volatile
    private var listener: Listener? = null

    @Volatile
    var installed: Boolean = false
        private set

    /** Installs the hook once for the process; true when it's in place. */
    @Synchronized
    fun install(listener: Listener): Boolean {
        this.listener = listener
        if (installed) return true
        installed = try {
            val global = Class.forName("android.view.WindowManagerGlobal")
            val instance = global.getMethod("getInstance").invoke(null)
            val views = global.getDeclaredField("mViews").apply { isAccessible = true }
            val params = global.getDeclaredField("mParams").apply { isAccessible = true }
            val lock = runCatching { global.getDeclaredField("mLock").apply { isAccessible = true }.get(instance) }.getOrNull() ?: this
            synchronized(lock) {
                @Suppress("UNCHECKED_CAST")
                val roots = Roots(views.get(instance) as List<View>) { this.listener }
                @Suppress("UNCHECKED_CAST")
                val all = Params(params.get(instance) as List<WindowManager.LayoutParams>, roots) { this.listener }
                views.set(instance, roots)
                params.set(instance, all)
            }
            true.also { HostHooks.log("window hook installed: extension windows are hidden as they're added") }
        } catch (t: Throwable) {
            HostHooks.log("window hook unavailable, extension windows show as Android draws them: $t")
            false
        }
        return installed
    }

    /** The windows' roots, in WindowManagerGlobal's order. */
    internal class Roots(old: List<View>, private val listener: () -> Listener?) : ArrayList<View>(old) {
        override fun add(element: View): Boolean {
            (element.layoutParams as? WindowManager.LayoutParams)?.let { params ->
                runCatching { listener()?.adding(element, params) }
            }
            return super.add(element)
        }

        override fun removeAt(index: Int): View = super.removeAt(index).also { root -> runCatching { listener()?.removed(root) } }

        override fun remove(element: View): Boolean = super.remove(element).also { removed ->
            if (removed) runCatching { listener()?.removed(element) }
        }
    }

    /** The windows' parameters, index for index with [roots]: an update replaces one in place. */
    internal class Params(
        old: List<WindowManager.LayoutParams>,
        private val roots: List<View>,
        private val listener: () -> Listener?,
    ) : ArrayList<WindowManager.LayoutParams>(old) {
        override fun add(index: Int, element: WindowManager.LayoutParams) {
            roots.getOrNull(index)?.let { root -> runCatching { listener()?.updating(root, element) } }
            super.add(index, element)
        }
    }
}
