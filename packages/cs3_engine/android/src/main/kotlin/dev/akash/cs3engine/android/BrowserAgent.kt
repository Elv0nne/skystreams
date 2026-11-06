package dev.akash.cs3engine.android

import android.content.Context
import android.webkit.WebSettings

@Volatile
private var known: String? = null

/**
 * The agent Android's WebView sends on its own, which CloudStream's resolver read from the WebView it made
 * (`WebViewResolver.webViewUserAgent`); null when there's no WebView to ask. Asked once: the first call loads the
 * WebView provider, and its answer holds for the process.
 */
internal fun browserAgent(context: Context): String? =
    known ?: runCatching { WebSettings.getDefaultUserAgent(context) }.getOrNull()?.also { known = it }
