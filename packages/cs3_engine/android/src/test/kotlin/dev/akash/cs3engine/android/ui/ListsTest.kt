package dev.akash.cs3engine.android.ui

import android.app.Activity
import android.os.Looper
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
class ListsTest {
    private val activity: Activity = Robolectric.buildActivity(Activity::class.java).setup().get()

    private class Items(var count: Int) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = object : RecyclerView.ViewHolder(
            TextView(parent.context).apply { layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 50) },
        ) {}

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            (holder.itemView as TextView).text = "Item ${position + 1}"
        }

        override fun getItemCount() = count
    }

    @Test
    fun `a list shorter than its items is made as tall as all of them, once`() {
        val items = Items(40)
        val list = RecyclerView(activity).apply {
            layoutManager = LinearLayoutManager(activity)
            adapter = items
        }
        val root = FrameLayout(activity).apply { addView(list, ViewGroup.LayoutParams.MATCH_PARENT, 300) }
        activity.setContentView(root)
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(list.childCount < 40, "the list binds only what fits")

        assertTrue(Lists.makeTall(root))
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(40, list.childCount)
        assertFalse(Lists.makeTall(root), "a list already tall enough stays")

        items.count = 45
        items.notifyItemRangeInserted(40, 5)
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(Lists.makeTall(root), "a list that grew is made taller")
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(45, list.childCount)
    }

    @Test
    fun `a list not laid out yet waits for the next read`() {
        val list = RecyclerView(activity).apply {
            layoutManager = LinearLayoutManager(activity)
            adapter = Items(10)
        }
        assertFalse(Lists.makeTall(FrameLayout(activity).apply { addView(list) }))
    }

    @Test
    fun `a list of more than 500 items is made tall for its first 500`() {
        val list = RecyclerView(activity).apply {
            layoutManager = LinearLayoutManager(activity)
            adapter = Items(2000)
        }
        val root = FrameLayout(activity).apply { addView(list, ViewGroup.LayoutParams.MATCH_PARENT, 300) }
        activity.setContentView(root)
        shadowOf(Looper.getMainLooper()).idle()

        assertTrue(Lists.makeTall(root))
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(500 * 50, list.height)
        assertEquals(500, list.childCount)
    }
}
