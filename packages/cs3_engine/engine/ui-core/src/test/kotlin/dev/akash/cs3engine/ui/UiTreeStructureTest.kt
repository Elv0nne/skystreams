package dev.akash.cs3engine.ui

import android.content.Context
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Part 1's Android UiTreeStructureTest, on the stand-ins. */
class UiTreeStructureTest {
    private val context = Context()
    private val ids = NodeIds()
    private val tree = UiTree(ids)

    private fun text(words: String) = TextView(context).apply { text = words }

    @Suppress("UNCHECKED_CAST")
    private fun Map<String, Any?>.children() = this["children"] as List<Map<String, Any?>>

    @Test
    fun `wrappers with one child and no tap give way to it`() {
        val words = text("Hi")
        val root = FrameLayout(context).apply { addView(LinearLayout(context).apply { addView(FrameLayout(context).apply { addView(words) }) }) }
        assertEquals(ids.of(words), tree.node(root)!!["id"])
    }

    @Test
    fun `a tappable group stays, with its tap`() {
        val card = LinearLayout(context).apply {
            setOnClickListener {}
            addView(text("Febbox Login"))
        }
        val node = tree.node(card)!!
        assertEquals(true, node["tappable"])
        assertEquals("Febbox Login", node.children().single()["text"])
    }

    @Test
    fun `an empty container is left out, but an empty list stays`() {
        assertNull(tree.node(LinearLayout(context)))
        val list = RecyclerView(context)
        assertEquals("list", tree.node(list)!!["kind"])
        assertEquals(0, tree.node(list)!!["items"])
    }

    @Test
    fun `a horizontal layout is a row, with its children's weights`() {
        val left = text("Left").apply { layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 2f) }
        val right = text("Right").apply { layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f) }
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(left)
            addView(right)
        }
        val node = tree.node(row)!!
        assertEquals("row", node["kind"])
        assertEquals(listOf(2f, 1f), node.children().map { it["weight"] })
    }

    @Test
    fun `a list carries its item count, and its bound items in item order`() {
        // Android's version measures and lays the list out first; a stand-in list binds every item as it's set.
        val list = RecyclerView(context).apply {
            layoutManager = LinearLayoutManager(context)
            adapter = object : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
                override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = object : RecyclerView.ViewHolder(TextView(parent.context)) {}

                override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
                    (holder.itemView as TextView).text = "Item ${position + 1}"
                }

                override fun getItemCount() = 5
            }
        }
        val node = tree.node(list)!!
        assertEquals(5, node["items"])
        assertEquals((1..5).map { "Item $it" }, node.children().map { it["text"] })
    }

    @Test
    fun `a window carries its id, kind, title, whether it cancels and is hidden, and its root`() {
        val words = text("Settings")
        val window = tree.window("w1", "sheet", "Title", cancelable = false, root = FrameLayout(context).apply { addView(words) }, hidden = true)
        assertEquals("w1", window["id"])
        assertEquals("sheet", window["kind"])
        assertEquals("Title", window["title"])
        assertEquals(false, window["cancelable"])
        assertEquals(true, window["hidden"])
        @Suppress("UNCHECKED_CAST")
        assertEquals(ids.of(words), (window["root"] as Map<String, Any?>)["id"])
    }

    @Test
    fun `a window with nothing to show has an empty column for root`() {
        @Suppress("UNCHECKED_CAST")
        val root = tree.window("w1", "dialog", null, true, FrameLayout(context), null)["root"] as Map<String, Any?>
        assertEquals("column", root["kind"])
        assertEquals(emptyList<Any>(), root["children"])
    }
}
