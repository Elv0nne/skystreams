package dev.akash.cs3engine.ui

import android.graphics.Typeface
import android.text.InputType
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.AbsListView
import android.widget.AdapterView
import android.widget.Button
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.RadioButton
import android.widget.SeekBar
import android.widget.Space
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import androidx.appcompat.widget.SwitchCompat
import androidx.recyclerview.widget.RecyclerView

/**
 * An extension's window as the tree SkyStream's sheet draws (the spec's "The protocol"): meaning only
 * (text, controls, structure), never sizes or colours. Every platform reads its views with it: Android
 * the real ones, the JVM its stand-ins. Main thread only. [references] gives the extension's own words for
 * one of its resource ids: Android leaves a layout's reference to them as "@id" when the app's theme can't
 * resolve it (AnimeUnity's icon buttons), which the sheet would otherwise show.
 */
class UiTree(val ids: NodeIds, private val references: (Int) -> CharSequence? = { null }) {
    /**
     * One window: its [id] and [kind] as the host names them, and its [root]'s tree. [fullScreen]: it asks for the whole
     * screen; [keepScreenOn]: that the screen stays on; [orientation]: what its extension asked of the activity while it
     * shows, as Android's `SCREEN_ORIENTATION_*` (Phase 7c's §1 and §5). Each key only when it says something.
     */
    fun window(
        id: String,
        kind: String,
        title: String?,
        cancelable: Boolean,
        root: View,
        hidden: Boolean?,
        fullScreen: Boolean = false,
        keepScreenOn: Boolean = false,
        orientation: Int? = null,
    ): Map<String, Any?> {
        val window = linkedMapOf<String, Any?>("id" to id, "kind" to kind, "cancelable" to cancelable)
        if (title != null) window["title"] = title
        if (hidden != null) window["hidden"] = hidden
        if (fullScreen) window["fullScreen"] = true
        if (keepScreenOn) window["keepScreenOn"] = true
        if (orientation != null) window["orientation"] = orientation
        window["root"] = node(root) ?: linkedMapOf("id" to ids.of(root), "kind" to "column", "children" to emptyList<Any>())
        return window
    }

    /** [view]'s node: null when it's hidden, a bare view or space, or a container with nothing to show. */
    fun node(view: View): Map<String, Any?>? {
        if (view.visibility != View.VISIBLE) return null
        val kind = kind(view)
        if (kind == "other" && (view.javaClass == View::class.java || view is Space)) return null
        if (view is ViewGroup && kind in CONTAINERS) return container(view, kind)
        return leaf(view, kind)
    }

    /** [root]'s words in reading order, its texts' and labels': what a kept window is told by, the first its title. */
    fun wordsOf(root: View): List<String> {
        val words = mutableListOf<String>()
        fun walk(node: Map<String, Any?>) {
            (node["text"] as? String)?.takeIf { it.isNotBlank() }?.let(words::add)
            (node["label"] as? String)?.takeIf { it.isNotBlank() }?.let(words::add)
            @Suppress("UNCHECKED_CAST")
            (node["children"] as? List<Map<String, Any?>>)?.forEach(::walk)
        }
        node(root)?.let(::walk)
        return words
    }

    private fun container(group: ViewGroup, kind: String): Map<String, Any?>? {
        val children = childrenOf(group).mapNotNull(::node)
        val tappable = group.hasOnClickListeners()
        if (kind != "list") {
            if (children.isEmpty() && !tappable) return null
            // A wrapper (a dialog's frames, a lone card): one child and no tap of its own gives way to it.
            if (children.size == 1 && !tappable) return children[0]
        }
        val node = linkedMapOf<String, Any?>("id" to ids.of(group), "kind" to kind)
        if (tappable) node["tappable"] = true
        if (!group.isEnabled) node["enabled"] = false
        words(group.contentDescription)?.takeIf { it.isNotBlank() }?.let { node["label"] = it }
        if (kind == "list") node["items"] = itemCount(group)
        weight(group)?.let { node["weight"] = it }
        node["children"] = children
        return node
    }

    private fun leaf(view: View, kind: String): Map<String, Any?> {
        val node = linkedMapOf<String, Any?>("id" to ids.of(view), "kind" to kind)
        if (!view.isEnabled) node["enabled"] = false
        if (view.hasOnClickListeners() || view is CompoundButton || view is Button) node["tappable"] = true
        words(view.contentDescription)?.takeIf { it.isNotBlank() }?.let { node["label"] = it }
        when (view) {
            is TextView -> {
                node["text"] = words(view.text).orEmpty()
                when {
                    view is EditText -> {
                        words(view.hint)?.let { node["hint"] = it }
                        node["input"] = inputKind(view.inputType)
                    }
                    view is CompoundButton -> node["checked"] = view.isChecked
                    view !is Button && isHeading(view) -> node["heading"] = true
                }
            }
            is Spinner -> {
                val adapter = view.adapter
                node["options"] = (0 until minOf(adapter?.count ?: 0, MAX_OPTIONS)).map { adapter.getItem(it)?.toString().orEmpty() }
                node["selected"] = view.selectedItemPosition
            }
            is ProgressBar -> if (view is SeekBar || !view.isIndeterminate) {
                node["value"] = view.progress
                node["max"] = view.max
            }
        }
        weight(view)?.let { node["weight"] = it }
        return node
    }

    /** [text] as a string, with an extension's raw resource reference ("@2130968613") read as its words when it has them. */
    private fun words(text: CharSequence?): String? {
        val string = text?.toString() ?: return null
        val id = RAW_REFERENCE.matchEntire(string)?.groupValues?.get(1)?.toLongOrNull() ?: return string
        if (id !in EXTENSION_IDS) return string
        return runCatching { references(id.toInt()) }.getOrNull()?.toString() ?: string
    }

    companion object {
        private val CONTAINERS = setOf("column", "row", "list")
        private const val MAX_OPTIONS = 200
        private val RAW_REFERENCE = Regex("@(\\d+)")

        /** An extension's own resources: package 0x7f, as Android numbers an app's. */
        private val EXTENSION_IDS = 0x7F000000L..0x7FFFFFFFL

        /** The node kind of [view]'s class. Order matters: a RadioButton is a CompoundButton is a Button is a TextView. */
        fun kind(view: View): String = when {
            view is WebView || view is PageStandIn -> "page"
            view is RadioButton -> "radio"
            view is Switch || view is SwitchCompat -> "switch"
            view is CompoundButton -> "checkbox"
            view is EditText -> "field"
            view is Button -> "button"
            view is TextView -> "text"
            view is ImageButton -> "iconButton"
            view is ImageView -> "image"
            view is Spinner -> "dropdown"
            view is SeekBar -> "slider"
            view is ProgressBar -> "progress"
            view is RecyclerView || view is AbsListView -> "list"
            view is LinearLayout && view.orientation == LinearLayout.HORIZONTAL -> "row"
            view is ViewGroup -> "column"
            else -> "other"
        }

        /** A list's items in item order; any other group's children as laid out. */
        private fun childrenOf(group: ViewGroup): List<View> {
            val children = (0 until group.childCount).mapNotNull { group.getChildAt(it) }
            return if (group is RecyclerView) children.sortedBy { group.getChildAdapterPosition(it) } else children
        }

        private fun itemCount(list: ViewGroup): Int = when (list) {
            is RecyclerView -> list.adapter?.itemCount ?: 0
            is AdapterView<*> -> list.adapter?.count ?: 0
            else -> list.childCount
        }

        private fun isHeading(text: TextView): Boolean {
            val resources = text.resources
            val sp = text.textSize / (resources.displayMetrics.density * resources.configuration.fontScale)
            // Bold by weight (isBold), by style (textStyle="bold"; Robolectric keeps only this), or, for a
            // font without a bold face, by the paint.
            val typeface = text.typeface
            val bold = typeface != null && (typeface.isBold || typeface.style and Typeface.BOLD != 0)
            return sp >= 18f || bold || text.paint.isFakeBoldText
        }

        private fun inputKind(type: Int): String {
            val cls = type and InputType.TYPE_MASK_CLASS
            val variation = type and InputType.TYPE_MASK_VARIATION
            return when {
                cls == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD -> "password"
                cls == InputType.TYPE_CLASS_NUMBER || cls == InputType.TYPE_CLASS_PHONE -> "number"
                cls == InputType.TYPE_CLASS_TEXT && variation in PASSWORDS -> "password"
                cls == InputType.TYPE_CLASS_TEXT && variation in EMAILS -> "email"
                cls == InputType.TYPE_CLASS_TEXT && variation == InputType.TYPE_TEXT_VARIATION_URI -> "url"
                type and InputType.TYPE_TEXT_FLAG_MULTI_LINE != 0 -> "multiline"
                else -> "text"
            }
        }

        private val PASSWORDS = setOf(
            InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
        )
        private val EMAILS = setOf(InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS, InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS)

        private fun weight(view: View): Float? = (view.layoutParams as? LinearLayout.LayoutParams)?.weight?.takeIf { it > 0f }
    }
}
