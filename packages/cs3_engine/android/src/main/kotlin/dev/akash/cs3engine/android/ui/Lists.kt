package dev.akash.cs3engine.android.ui

import android.view.View
import android.view.ViewGroup
import android.widget.AbsListView
import androidx.recyclerview.widget.RecyclerView
import java.util.WeakHashMap

/**
 * Lists in hidden extension windows, made as tall as all their items. A RecyclerView or ListView binds
 * only what fits, and SkyStream's sheet shows every item. Nobody sees the list either way, and its item
 * views then stay bound for the session, so an action reaches the item it was aimed at. Main thread only.
 */
internal object Lists {
    /** The most items a list is made tall for (the longest seen held 50); the rest stay unbound. */
    private const val MAX_ITEMS = 500

    /** The tallest a list is measured to. */
    private const val MAX_HEIGHT = 1 shl 20

    /** Each list made tall, with the item count it was made tall for. */
    private val tall = WeakHashMap<View, Int>()

    /** Makes each list under [root] tall enough for its items; true when one changed (read again after the next layout). */
    fun makeTall(root: View): Boolean {
        var changed = false
        for (list in lists(root)) {
            val count = when (list) {
                is RecyclerView -> list.adapter?.itemCount ?: 0
                is AbsListView -> list.adapter?.count ?: 0
                else -> 0
            }
            if (count == 0 || tall[list] == count || list.width <= 0) continue
            val limit = if (count <= MAX_ITEMS) MAX_HEIGHT else (pitch(list) * MAX_ITEMS).toInt().coerceIn(1, MAX_HEIGHT)
            list.measure(
                View.MeasureSpec.makeMeasureSpec(list.width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(limit, View.MeasureSpec.AT_MOST),
            )
            val height = list.measuredHeight
            tall[list] = count
            if (height <= list.height) continue
            list.layoutParams = list.layoutParams.apply { this.height = height }
            (list as? RecyclerView)?.isNestedScrollingEnabled = false
            changed = true
        }
        return changed
    }

    /** The height each item takes, from the ones laid out (with their gaps); 0 before any are. */
    private fun pitch(list: ViewGroup): Double {
        if (list.childCount == 0) return 0.0
        val first = list.getChildAt(0)
        val last = list.getChildAt(list.childCount - 1)
        return (last.bottom - first.top).toDouble() / list.childCount
    }

    private fun lists(view: View): List<ViewGroup> = when (view) {
        is RecyclerView, is AbsListView -> listOf(view as ViewGroup)
        is ViewGroup -> (0 until view.childCount).flatMap { index -> view.getChildAt(index)?.let(::lists).orEmpty() }
        else -> emptyList()
    }
}
