package dev.akash.cs3engine.ui

import android.view.View
import java.lang.ref.WeakReference
import java.util.WeakHashMap

/**
 * Numbers an open screen's views, so the app's actions can name them: a view keeps its number while it
 * lives. Main thread only.
 */
class NodeIds {
    private val ids = WeakHashMap<View, Int>()
    private val views = HashMap<Int, WeakReference<View>>()
    private var next = 1

    /** [view]'s number; a [PageStandIn]'s is its page's. */
    fun of(view: View): Int {
        if (view is PageStandIn) return of(view.page)
        return ids.getOrPut(view) { (next++).also { views[it] = WeakReference(view) } }
    }

    fun view(id: Int): View? = views[id]?.get()
}
