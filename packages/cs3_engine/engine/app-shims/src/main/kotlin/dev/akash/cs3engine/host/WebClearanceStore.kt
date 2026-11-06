package dev.akash.cs3engine.host

import android.webkit.CookieManager
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import java.util.concurrent.ConcurrentHashMap

/**
 * Bot-check clearances, reused for later requests. The app's store is the source: it pushes every
 * site's clearance here ([setSites]), and a solve the engine asks for lands here too ([put]).
 */
object WebClearanceStore {
    /** Clearance cookies per host. Plugins see this map as `CloudflareKiller.savedCookies`. */
    val cookies = ConcurrentHashMap<String, Map<String, String>>()
    private val userAgents = ConcurrentHashMap<String, String>()

    /** Per site (a registrable domain, as the app keys them): its cookies and the agent they hold under. */
    private val sites = ConcurrentHashMap<String, WebClearance>()

    /**
     * Hosts an earned clearance didn't get through from here, or whose page got past a refusal: their site lets only
     * the browser through.
     */
    private val browserOnlyHosts = ConcurrentHashMap.newKeySet<String>()

    /**
     * Hosts that moved, to the origin they moved to: the app's list ([setMoves]), keyed by host.
     * Another host of the same site may live elsewhere.
     */
    private val moves = ConcurrentHashMap<String, HttpUrl>()

    /** Replaces the moves with the app's. */
    fun setMoves(moved: Map<String, String>) {
        moves.clear()
        for ((host, origin) in moved) origin.toHttpUrlOrNull()?.let { moves[host.lowercase()] = it }
    }

    /** [request] sent to where its host moved, path and query kept; as it is when it didn't. */
    fun followMove(request: Request): Request {
        val to = moves[request.url.host.lowercase()] ?: return request
        val url = request.url.newBuilder().scheme(to.scheme).host(to.host).port(to.port).build()
        return request.newBuilder().url(url).build()
    }

    /** [host]'s new domain stopped answering: its requests go to its own address again. */
    fun forgetMove(host: String) {
        moves.remove(host.lowercase())
    }

    /** Whether [host]'s requests go from inside its site's pages: found here, or told by the app. */
    fun isBrowserOnly(host: String): Boolean = host in browserOnlyHosts || siteOf(host)?.browserOnly == true

    fun markBrowserOnly(host: String) {
        browserOnlyHosts += host
    }

    /** Forgets every clearance and mark (tests). */
    internal fun clear() {
        cookies.clear()
        userAgents.clear()
        sites.clear()
        browserOnlyHosts.clear()
        moves.clear()
    }

    fun has(host: String): Boolean = cookies.containsKey(host) || siteOf(host) != null

    fun put(host: String, clearance: WebClearance) {
        cookies[host] = clearance.cookies
        userAgents[host] = clearance.userAgent
        // Plugins also read the browser's cookies through CookieManager, as on Android.
        val jar = CookieManager.getInstance()
        for ((name, value) in clearance.cookies) jar.setCookie("https://$host/", "$name=$value")
    }

    /** Replaces the sites' clearances with the app's. */
    fun setSites(clearances: Map<String, WebClearance>) {
        sites.clear()
        sites.putAll(clearances)
        val jar = CookieManager.getInstance()
        for ((site, clearance) in clearances) {
            for ((name, value) in clearance.cookies) jar.setCookie("https://$site/", "$name=$value; Domain=.$site")
        }
    }

    /** The clearance for [host]: its own, else its site's. */
    fun clearanceFor(host: String): WebClearance? {
        val own = cookies[host]
        if (own != null) return WebClearance(own, userAgents[host] ?: return siteOf(host))
        return siteOf(host)
    }

    private fun siteOf(host: String): WebClearance? {
        var name = host.lowercase()
        while (true) {
            sites[name]?.let { return it }
            val dot = name.indexOf('.')
            if (dot < 0) return null
            name = name.substring(dot + 1)
        }
    }

    /** The clearance only holds with the exact User-Agent the browser used. */
    fun headers(host: String): Headers {
        val builder = Headers.Builder()
        val clearance = clearanceFor(host) ?: return builder.build()
        builder.add("User-Agent", clearance.userAgent)
        if (clearance.cookies.isNotEmpty()) {
            builder.add("Cookie", clearance.cookies.entries.joinToString("; ") { "${it.key}=${it.value}" })
        }
        return builder.build()
    }

    /** [request] with its host's clearance: the cookies merged into its own (the clearance's winning), and the agent. */
    fun apply(request: Request): Request {
        val clearance = clearanceFor(request.url.host) ?: return request
        val merged = cookiesIn(request)
        merged.putAll(clearance.cookies)
        val builder = request.newBuilder().header("User-Agent", clearance.userAgent)
        if (merged.isNotEmpty()) builder.header("Cookie", merged.entries.joinToString("; ") { "${it.key}=${it.value}" })
        return builder.build()
    }

    /** [request]'s host's clearance, when the request carries every cookie of it. */
    fun carriedBy(request: Request): WebClearance? {
        val clearance = clearanceFor(request.url.host) ?: return null
        val sent = cookiesIn(request)
        return clearance.takeIf { it.cookies.isNotEmpty() && it.cookies.all { (name, value) -> sent[name] == value } }
    }

    private fun cookiesIn(request: Request): LinkedHashMap<String, String> {
        val cookies = LinkedHashMap<String, String>()
        request.header("Cookie")?.split(";")?.forEach { pair ->
            val at = pair.indexOf('=')
            if (at > 0) cookies[pair.substring(0, at).trim()] = pair.substring(at + 1).trim()
        }
        return cookies
    }
}
