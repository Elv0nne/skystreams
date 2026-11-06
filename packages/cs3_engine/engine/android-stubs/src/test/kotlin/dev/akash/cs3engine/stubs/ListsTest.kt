package dev.akash.cs3engine.stubs

import android.content.Context
import android.view.View
import android.view.ViewGroup
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.ListView
import android.widget.Spinner
import android.widget.TextView
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertSame
import kotlin.test.assertTrue

class ListsTest {
    private val context = Context()

    private class Holder(val text: TextView) : RecyclerView.ViewHolder(text)

    /** [count] items, "Item 1"…; a tap reports the holder's position, as the test extension's do. */
    private inner class Items(var count: Int, val picked: (Int) -> Unit = {}) : RecyclerView.Adapter<Holder>() {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = Holder(TextView(parent.context))

        override fun onBindViewHolder(holder: Holder, position: Int) {
            holder.text.text = "Item ${position + 1}"
            holder.text.setOnClickListener { picked(holder.bindingAdapterPosition) }
        }

        override fun getItemCount() = count
    }

    @Test
    fun `a recycler view binds every item in order, and keeps their views across changes`() {
        val list = RecyclerView(context)
        val items = Items(40)
        list.adapter = items
        assertEquals(0, list.childCount, "no layout manager, nothing laid out, as on Android")
        list.layoutManager = LinearLayoutManager(context)
        assertEquals(40, list.childCount)
        assertEquals("Item 30", (list.getChildAt(29) as TextView).text.toString())
        assertEquals(29, list.getChildAdapterPosition(list.getChildAt(29)))
        val before = list.getChildAt(5)
        items.count = 45
        items.notifyItemRangeInserted(40, 5)
        assertEquals(45, list.childCount)
        assertSame(before, list.getChildAt(5), "the same view: a tap aimed at it lands")
        assertSame(list.getChildViewHolder(before), list.findViewHolderForAdapterPosition(5))
        assertFailsWith<IllegalArgumentException> { list.getChildViewHolder(TextView(context)) }
    }

    @Test
    fun `a recycler view binds at most 500 items, and a tap reaches the item's position`() {
        val list = RecyclerView(context)
        var picked = -1
        list.layoutManager = LinearLayoutManager(context)
        list.adapter = Items(1000) { picked = it }
        assertEquals(500, list.childCount)
        list.getChildAt(29).performClick()
        assertEquals(29, picked)
    }

    @Test
    fun `a list view binds its adapter's views, and hears item clicks by position`() {
        val list = ListView(context)
        val adapter = ArrayAdapter(context, android.R.layout.simple_list_item_1, mutableListOf("a", "b", "c"))
        list.adapter = adapter
        assertEquals(3, list.childCount)
        assertEquals("b", (list.getChildAt(1) as TextView).text.toString())
        var clicked = -1L
        list.setOnItemClickListener { _, _, position, id -> clicked = position * 10L + id }
        val row = list.getChildAt(1)
        val position = list.getPositionForView(row)
        assertTrue(list.performItemClick(row, position, list.getItemIdAtPosition(position)))
        assertEquals(11L, clicked)
        adapter.add("d")
        assertEquals(4, list.childCount, "a change rebinds")
        assertEquals(AdapterView.INVALID_POSITION, list.getPositionForView(TextView(context)))
        assertFailsWith<UnsupportedOperationException> { list.addView(View(context)) }
    }

    @Test
    fun `a dropdown selects by index, and its listener hears the settled choice after the current task`() {
        val heard = mutableListOf<Int>()
        onMain {
            val dropdown = Spinner(context)
            dropdown.adapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, arrayOf("480p", "720p", "1080p"))
            assertEquals(0, dropdown.selectedItemPosition)
            dropdown.setSelection(2)
            dropdown.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(parent: AdapterView<*>, view: View?, position: Int, id: Long) {
                    heard += position
                }

                override fun onNothingSelected(parent: AdapterView<*>) {
                    heard += -1
                }
            }
        }
        drainMain()
        assertEquals(listOf(2), heard, "once, the settled choice")
    }

    @Test
    fun `a dropdown's listener gets the selected item's view, as Android's does, so a non-null parameter holds`() {
        val heard = mutableListOf<String>()
        lateinit var dropdown: Spinner
        onMain {
            dropdown = Spinner(context)
            dropdown.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                // Non-null, as some extensions' Kotlin listeners declare it: a null view would throw here.
                override fun onItemSelected(parent: AdapterView<*>, view: View, position: Int, id: Long) {
                    heard += (view as TextView).text.toString()
                }

                override fun onNothingSelected(parent: AdapterView<*>) {}
            }
            dropdown.adapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, arrayOf("480p", "720p"))
        }
        drainMain()
        onMain { dropdown.setSelection(1) }
        drainMain()
        assertEquals(listOf("480p", "720p"), heard)
        assertEquals("720p", (dropdown.selectedView as TextView).text.toString())
    }

    @Test
    fun `an array adapter from an array is fixed in size, as Android's`() {
        val adapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, arrayOf("a"))
        assertFailsWith<UnsupportedOperationException> { adapter.add("b") }
        assertEquals("a", adapter.getItem(0))
        assertEquals(0L, adapter.getItemId(0))
    }

    @Test
    fun `a list adapter's submitted list rebinds at once and runs its callback`() {
        val list = RecyclerView(context)
        list.layoutManager = LinearLayoutManager(context)
        val adapter = object : ListAdapter<String, Holder>(
            object : DiffUtil.ItemCallback<String>() {
                override fun areItemsTheSame(oldItem: String, newItem: String) = oldItem == newItem

                override fun areContentsTheSame(oldItem: String, newItem: String) = oldItem == newItem
            },
        ) {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = Holder(TextView(parent.context))

            override fun onBindViewHolder(holder: Holder, position: Int) {
                holder.text.text = getItem(position)
            }
        }
        list.adapter = adapter
        var committed = false
        adapter.submitList(listOf("x", "y")) { committed = true }
        assertTrue(committed)
        assertEquals(listOf("x", "y"), adapter.currentList)
        assertEquals("y", (list.getChildAt(1) as TextView).text.toString())
    }

    @Test
    fun `DiffUtil's result updates the adapter`() {
        val list = RecyclerView(context)
        list.layoutManager = LinearLayoutManager(context)
        val items = Items(2)
        list.adapter = items
        items.count = 3
        val result = DiffUtil.calculateDiff(
            object : DiffUtil.Callback() {
                override fun getOldListSize() = 2

                override fun getNewListSize() = 3

                override fun areItemsTheSame(oldItemPosition: Int, newItemPosition: Int) = oldItemPosition == newItemPosition

                override fun areContentsTheSame(oldItemPosition: Int, newItemPosition: Int) = true
            },
        )
        result.dispatchUpdatesTo(items)
        assertEquals(3, list.childCount)
    }
}
