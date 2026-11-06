// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.utils

import android.content.Context

/** Text for the app to show. Upstream can also name one of its string resources; SkyStream has none of them. */
sealed class UiText {
    data class DynamicString(val value: String) : UiText() {
        override fun toString(): String = value
    }

    fun asStringNull(context: Context?): String? = asString(context ?: return null)

    fun asString(context: Context): String = when (this) {
        is DynamicString -> value
    }
}

fun txt(value: String): UiText = UiText.DynamicString(value)

@JvmName("txtNull")
fun txt(value: String?): UiText? = UiText.DynamicString(value ?: return null)
