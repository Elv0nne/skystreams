package dev.akash.cs3engine.android.ui

import android.content.Context
import android.util.AttributeSet
import android.view.LayoutInflater
import android.view.View

/**
 * Keeps the ids an extension's layout gives its views. Android resolves a layout's attribute references through
 * the inflating context's resources, the app's (as CloudStream's do), so an extension's id that lands on an app
 * resource which is itself a reference takes that resource's id, and the extension's findViewById misses the view
 * (the test extension's `picked` landed on AppCompat's abc_search_url_text_selected, @android:color/black). Which
 * ids are hit moves with the app's own resources.
 *
 * The host activity installs it first on its inflater, and fragments' and dialogs' inflaters, cloned from it, keep
 * it. It makes each view through [create] (AppCompat's delegate, as AppCompat's own factory would), and gives one
 * whose id Android resolved elsewhere its layout's own. Every other view comes out as it was made.
 */
internal class ExtensionLayoutIds(private val create: (View?, String, Context, AttributeSet) -> View?) : LayoutInflater.Factory2 {
    override fun onCreateView(parent: View?, name: String, context: Context, attrs: AttributeSet): View? {
        val own = own(attrs)
        val keep = own != View.NO_ID && resolved(context, attrs) != own
        val view = create(parent, name, context, attrs) ?: if (keep && name != "fragment") make(name, context, attrs) else null
        if (keep && view != null) view.id = own
        return view
    }

    override fun onCreateView(name: String, context: Context, attrs: AttributeSet): View? = onCreateView(null, name, context, attrs)

    /**
     * The id the layout gives the view, as written: android:id's reference, unresolved. (getIdAttributeResourceValue
     * looks for an `id` without a namespace, so it never finds android:id.)
     */
    private fun own(attrs: AttributeSet): Int {
        for (i in 0 until attrs.attributeCount) {
            if (attrs.getAttributeNameResource(i) == android.R.attr.id) return attrs.getAttributeResourceValue(i, View.NO_ID)
        }
        return View.NO_ID
    }

    /** The id Android gives the view: its layout's, resolved through [context]'s resources as View's constructor does. */
    private fun resolved(context: Context, attrs: AttributeSet): Int {
        val values = context.obtainStyledAttributes(attrs, ID)
        try {
            return values.getResourceId(0, View.NO_ID)
        } finally {
            values.recycle()
        }
    }

    /**
     * [name]'s view, made as LayoutInflater makes one no factory made: a bare name from android.widget,
     * android.webkit, android.app or android.view. A fresh clone makes it with [context].
     */
    private fun make(name: String, context: Context, attrs: AttributeSet): View? {
        val inflater = LayoutInflater.from(context).cloneInContext(context)
        if ('.' in name) return inflater.createView(name, null, attrs)
        for (prefix in PREFIXES) {
            try {
                return inflater.createView(name, prefix, attrs)
            } catch (_: ClassNotFoundException) {
                // The next package.
            }
        }
        return null
    }

    private companion object {
        val ID = intArrayOf(android.R.attr.id)
        val PREFIXES = listOf("android.widget.", "android.webkit.", "android.app.", "android.view.")
    }
}
