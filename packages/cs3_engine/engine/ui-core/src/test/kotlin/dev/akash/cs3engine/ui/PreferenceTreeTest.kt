package dev.akash.cs3engine.ui

import android.content.Context
import android.graphics.drawable.ColorDrawable
import androidx.preference.Preference
import androidx.preference.PreferenceCategory
import androidx.preference.PreferenceGroupAdapter
import androidx.preference.PreferenceManager
import androidx.preference.SeekBarPreference
import androidx.preference.SwitchPreferenceCompat
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import kotlin.test.Test
import kotlin.test.assertEquals

class PreferenceTreeTest {
    private val context = Context()

    /** [node] without its ids: what the corpus compares. */
    @Suppress("UNCHECKED_CAST")
    private fun shape(node: Map<String, Any?>): Map<String, Any?> = node.filterKeys { it != "id" }.mapValues { (key, value) ->
        if (key == "children") (value as List<Map<String, Any?>>).map(::shape) else value
    }

    private fun text(words: String, enabled: Boolean = true): Map<String, Any?> =
        if (enabled) mapOf("kind" to "text", "text" to words) else mapOf("kind" to "text", "enabled" to false, "text" to words)

    private fun row(vararg children: Map<String, Any?>, enabled: Boolean = true): Map<String, Any?> =
        if (enabled) mapOf("kind" to "row", "tappable" to true, "children" to children.toList())
        else mapOf("kind" to "row", "tappable" to true, "enabled" to false, "children" to children.toList())

    private fun titleAndSummary(title: String, summary: String, enabled: Boolean = true): Map<String, Any?> {
        val words = listOf(text(title, enabled), text(summary, enabled))
        return if (enabled) mapOf("kind" to "column", "weight" to 1f, "children" to words)
        else mapOf("kind" to "column", "enabled" to false, "weight" to 1f, "children" to words)
    }

    @Test
    fun `a preference screen reads as Android's does, rows of titles, summaries and widgets`() {
        // The shapes of the Android corpus' preference screens (Cinemana, Replaymatch, YouTube).
        val screen = PreferenceManager(context).createPreferenceScreen(context)
        val general = PreferenceCategory(context).apply { title = "General" }
        screen.addPreference(general)
        general.addPreference(SwitchPreferenceCompat(context).apply { title = "Banner"; setDefaultValue(true) })
        general.addPreference(Preference(context).apply { title = "Clear cache"; summary = "Tap to refresh" })
        general.addPreference(Preference(context).apply { title = "Account"; summary = "Not signed in"; isEnabled = false })
        general.addPreference(
            SeekBarPreference(context).apply {
                title = "Pages"
                summary = "Pages fetched"
                min = 1
                max = 50
                value = 6
                showSeekBarValue = true
            },
        )
        general.addPreference(Preference(context).apply { title = "Channels"; summary = "Edit your channels"; icon = ColorDrawable(0) })
        val list = RecyclerView(context).apply {
            layoutManager = LinearLayoutManager(context)
            adapter = PreferenceGroupAdapter(screen)
        }
        val slider = mapOf("kind" to "slider", "value" to 5, "max" to 49, "weight" to 1f)
        assertEquals(
            mapOf(
                "kind" to "list",
                "items" to 6,
                "children" to listOf(
                    row(text("General")),
                    row(text("Banner"), mapOf("kind" to "switch", "tappable" to true, "text" to "", "checked" to true)),
                    row(titleAndSummary("Clear cache", "Tap to refresh")),
                    row(titleAndSummary("Account", "Not signed in", enabled = false), enabled = false),
                    row(
                        mapOf(
                            "kind" to "column",
                            "children" to listOf(
                                titleAndSummary("Pages", "Pages fetched"),
                                mapOf("kind" to "row", "children" to listOf(slider, text("6"))),
                            ),
                        ),
                    ),
                    row(mapOf("kind" to "image"), titleAndSummary("Channels", "Edit your channels")),
                ),
            ),
            shape(UiTree(NodeIds()).node(list)!!),
        )
    }
}
