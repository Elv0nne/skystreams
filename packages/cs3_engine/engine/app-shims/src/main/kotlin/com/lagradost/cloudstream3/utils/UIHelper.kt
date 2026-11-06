// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.utils

import android.content.Context
import android.util.TypedValue

/**
 * The part of CloudStream's UIHelper extensions call: FStream's settings colour their views with it. Off
 * Android the theme resolves no attributes, so the colour reads 0, as an unset one does on Android.
 */
object UIHelper {
    /** The colour [attribute] (a theme attribute, such as `colorPrimary`) resolves to in this context's theme. */
    fun Context.colorFromAttribute(attribute: Int): Int {
        val value = TypedValue()
        theme.resolveAttribute(attribute, value, true)
        return value.data
    }
}
