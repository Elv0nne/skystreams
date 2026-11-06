package dev.akash.cs3engine.host

import com.lagradost.cloudstream3.network.WebViewResolver
import com.lagradost.cloudstream3.network.WebViewResolverHost
import com.lagradost.nicehttp.requestCreator
import okhttp3.Request
import java.util.Collections
import java.util.concurrent.atomic.AtomicReference

/**
 * CloudStream's `WebViewResolver`, on every platform, in the app's browser: the page loads hidden
 * there, within its page budget, and each request it makes comes back here to be matched with the
 * extension's own patterns, in the order CloudStream's Android resolver matches them. On Android it
 * takes the place of CloudStream's own WebView, whose renderer ending took the app down with it.
 *
 * What differs from CloudStream's Android resolver:
 * - the page keeps the browser's own agent (the resolver's `userAgent` isn't applied), which `webViewUserAgent` holds
 *   where the host knows it ([HostHooks.browserAgent]: Android's WebView default, as CloudStream's);
 * - the page loads everything itself (`useOkhttp`, and the skipped images and media, don't apply);
 * - a request comes back with its address and method only.
 */
object PageResolver : WebViewResolverHost.Resolver {
    override suspend fun resolve(
        resolver: WebViewResolver,
        request: Request,
        requestCallBack: (Request) -> Boolean,
    ): Pair<Request?, List<Request>> {
        val host = HostHooks.webView ?: return null to emptyList()
        // As CloudStream's Android resolver sets it from the WebView it makes: extensions read it for their own requests.
        HostHooks.browserAgent()?.let { WebViewResolver.webViewUserAgent = it }
        val found = AtomicReference<Request?>()
        val extra = Collections.synchronizedList(mutableListOf<Request>())
        host.resolvePage(
            url = request.url.toString(),
            headers = request.headers.toMap(),
            script = resolver.script,
            timeoutMs = resolver.timeout,
            onScript = { result -> resolver.scriptCallback?.invoke(result) },
        ) { url, method ->
            // A data: or blob: address isn't a request OkHttp can make, as on Android.
            val made = runCatching { requestCreator(method ?: "GET", url) }.getOrNull() ?: return@resolvePage false
            when {
                resolver.interceptUrl.containsMatchIn(url) -> {
                    found.set(made)
                    requestCallBack(made)
                    true
                }
                resolver.additionalUrls.any { it.containsMatchIn(url) } -> {
                    extra += made
                    requestCallBack(made)
                }
                else -> false
            }
        }
        return found.get() to extra.toList()
    }
}
