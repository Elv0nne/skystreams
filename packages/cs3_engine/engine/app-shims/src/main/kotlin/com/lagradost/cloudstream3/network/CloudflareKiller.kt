// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.network

import dev.akash.cs3engine.host.ClearanceInterceptor
import dev.akash.cs3engine.host.WebClearanceStore
import okhttp3.Headers
import okhttp3.Interceptor
import okhttp3.Response
import java.net.URI

/**
 * Plugins add this interceptor to requests that may hit a Cloudflare challenge. It does what the
 * engine's [ClearanceInterceptor] does on CloudStream's shared clients, which carry that one too:
 * the host's browser solves the challenge and the request is sent again with its cookies and agent,
 * or from inside one of the site's pages when the site lets only the browser through. A host
 * without a browser gets the challenge back.
 */
class CloudflareKiller : Interceptor {
    companion object {
        fun parseCookieMap(cookie: String): Map<String, String> = cookie.split(";").associate {
            val split = it.split("=")
            (split.getOrNull(0)?.trim() ?: "") to (split.getOrNull(1)?.trim() ?: "")
        }.filter { it.key.isNotBlank() && it.value.isNotBlank() }
    }

    /** Clearance cookies per host, shared by every instance. */
    val savedCookies: MutableMap<String, Map<String, String>> get() = WebClearanceStore.cookies

    /** Headers that pass [url]'s challenge (cookies and User-Agent), for plugins' own requests. */
    fun getCookieHeaders(url: String): Headers = WebClearanceStore.headers(URI(url).host)

    override fun intercept(chain: Interceptor.Chain): Response = ClearanceInterceptor.interceptForKiller(chain)
}
