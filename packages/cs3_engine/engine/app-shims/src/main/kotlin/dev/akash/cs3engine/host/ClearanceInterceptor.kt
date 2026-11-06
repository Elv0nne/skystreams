package dev.akash.cs3engine.host

import com.fasterxml.jackson.databind.ObjectMapper
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.io.IOException

/**
 * On CloudStream's shared clients (`app` and `insecureApp`), so every extension request is
 * covered, and behind `CloudflareKiller` where an extension adds that:
 * - a cleared site's requests carry its clearance;
 * - a challenge is solved by the host's browser and the request sent again, the clearance it met
 *   the check with named, so the app doesn't hand that one back; one the app hands back that meets
 *   the check again is named in a second ask;
 * - a site that challenges even a clearance the browser just earned lets only the browser through:
 *   the request is sent from inside one of its pages, and so are its later ones. Behind
 *   `CloudflareKiller`, a 403 with none of a check's marks counts only if one of the site's pages
 *   gets past it.
 *
 * Block pages are left alone: no check clears them.
 *
 * What counts as a check: on the shared clients, what the app's triage recognises
 * ([isChallenge]); behind `CloudflareKiller`, which an extension adds, also any 403 from
 * Cloudflare that isn't a block page ([isRefusal]), as CloudStream's own `CloudflareKiller` treats
 * them.
 */
object ClearanceInterceptor : Interceptor {
    /** Bytes of a 403, 429 or 503 read to tell a check from a block page or the site's own error. */
    private const val PEEK = 64 * 1024L

    /** Bytes of a 200 HTML answer read to tell Anubis' or HostAdmin's check: theirs say so early. */
    private const val CHECK_PAGE_PEEK = 16 * 1024L

    /** The largest request body sent from a page, whose `fetch` takes text. */
    private const val PAGE_BODY = 1024 * 1024L

    /** On what this has dealt with, so a second one on the same call leaves the answer alone. */
    private object Handled

    override fun intercept(chain: Interceptor.Chain): Response = intercept(chain, ::isChallenge)

    /**
     * What `CloudflareKiller` does. A site's own refusal of clients, sent through Cloudflare with
     * none of its marks, is a check too (Kinoger's "Access Denied"): the browser gets through it.
     */
    internal fun interceptForKiller(chain: Interceptor.Chain): Response = intercept(chain, ::isRefusal)

    private fun intercept(chain: Interceptor.Chain, isCheck: (Response) -> Boolean): Response {
        // Straight to where the site moved, when the app knows it did.
        val asked = chain.request()
        var request = WebClearanceStore.followMove(asked)
        val pageFirst = WebClearanceStore.isBrowserOnly(request.url.host)
        if (pageFirst) fromPage(request)?.let { return it }
        val response = try {
            chain.proceed(WebClearanceStore.apply(request))
        } catch (e: IOException) {
            if (request === asked) throw e
            // The site's new domain stopped answering: its own address says where it is now. Once:
            // the request sent there isn't rewritten again.
            WebClearanceStore.forgetMove(asked.url.host)
            HostHooks.event(
                ObjectMapper().writeValueAsString(mapOf("event" to "siteMoveDropped", "from" to asked.url.toString())),
            )
            request = asked
            chain.proceed(WebClearanceStore.apply(asked))
        }
        if (response.request.tag(Handled::class.java) != null || !isCheck(response)) return response
        // Only a site behind a check is a move worth following: other hosts send addresses elsewhere for
        // good for their own reasons (GitHub's raw host to github.com).
        reportMove(asked, request, response)
        // The check is the site's where the request ended, after any redirect.
        val reached = response.request.url
        // The request the site answered: a redirect may have sent it on, and made a POST a GET.
        val target = response.request
        val webView = HostHooks.webView ?: return handled(response)

        // [clearance] kept for the host, and the request sent again with it.
        fun sendWith(clearance: WebClearance, previous: Response): Response {
            WebClearanceStore.put(reached.host, clearance)
            // Closed first: OkHttp sends no second request on a call whose first response is open, and a
            // check marked in its headers (`cf-mitigated`) leaves its body unread.
            previous.close()
            return chain.proceed(WebClearanceStore.apply(target))
        }

        // A check met with a clearance names it, so the app solves again rather than hand back the one that just
        // failed; not on a host that lets only the browser through, where a check says nothing of its clearance. A
        // refusal names none: it may be the site's own answer, the clearance still good.
        val failed = if (isChallenge(response) && !WebClearanceStore.isBrowserOnly(reached.host)) {
            WebClearanceStore.carriedBy(target)
        } else {
            null
        }
        var clearance = webView.solveCloudflare(reached.toString(), failed) ?: return handled(response)
        var again = sendWith(clearance, response)
        if (!isCheck(again)) return handled(again)
        if (isChallenge(again)) {
            if (!clearance.earned && !WebClearanceStore.isBrowserOnly(reached.host)) {
                // One the app held, not one its browser earned, proves nothing: it may have lapsed sooner than the app
                // expects. Named, the app solves again, and the clearance its browser earns decides.
                clearance = webView.solveCloudflare(reached.toString(), clearance) ?: return handled(again)
                again = sendWith(clearance, again)
                if (!isChallenge(again)) return handled(again)
            }
            if (clearance.earned) {
                // A clearance the browser earned met a check again: the site lets only the browser through.
                markBrowserOnly(reached)
            } else if (!WebClearanceStore.isBrowserOnly(reached.host)) {
                // Still one the app held: nothing is proven. Unless another request found meanwhile that the site lets
                // only the browser through.
                return handled(again)
            }
            val fromPage = if (pageFirst) null else fromPage(target)
            if (fromPage == null) return handled(again)
            again.close()
            return fromPage
        }
        // A 403 with none of a check's marks (behind `CloudflareKiller`) that a clearance didn't lift: the site lets
        // only the browser through if one of its pages gets past it (Kinoger's "Access Denied"). One its page meets
        // too is the site's own answer to this request, and the host stays as it was.
        if (pageFirst) return handled(again)
        val fromPage = fromPage(target)
        if (fromPage == null || fromPage.code >= 400) {
            fromPage?.close()
            return handled(again)
        }
        if (!clearance.earned && !WebClearanceStore.isBrowserOnly(reached.host)) {
            // Past a clearance the app held, not one its browser earned: that one may have lapsed sooner than the app
            // expects. Named, the app solves again, and the clearance its browser earns gets through, or decides.
            val earned = webView.solveCloudflare(reached.toString(), clearance)
            if (earned == null) {
                again.close()
                return fromPage
            }
            again = sendWith(earned, again)
            if (!isCheck(again)) {
                fromPage.close()
                return handled(again)
            }
            if (!earned.earned) {
                again.close()
                return fromPage
            }
        }
        markBrowserOnly(reached)
        again.close()
        return fromPage
    }

    /**
     * [reached]'s host lets only the browser through: its later requests go to its pages first, and the app keeps it.
     */
    private fun markBrowserOnly(reached: HttpUrl) {
        WebClearanceStore.markBrowserOnly(reached.host)
        HostHooks.event(
            ObjectMapper().writeValueAsString(mapOf("event" to "siteBrowserOnly", "url" to reached.toString())),
        )
    }

    /**
     * Tells the app when [response] came from another host through permanent redirects (301, 308)
     * that kept the path and query: the site may have moved. The app's site list decides whether
     * the two hosts are two sites. The move is from the address the extension [asked] for, even
     * when the [request] went where it had moved before: a later move replaces the first.
     */
    private fun reportMove(asked: Request, request: Request, response: Response) {
        val reached = response.request.url
        if (reached.host == request.url.host) return
        if (reached.encodedPath != request.url.encodedPath || reached.encodedQuery != request.url.encodedQuery) return
        var prior = response.priorResponse ?: return
        while (true) {
            if (prior.code != 301 && prior.code != 308) return
            prior = prior.priorResponse ?: break
        }
        HostHooks.event(
            ObjectMapper().writeValueAsString(
                mapOf("event" to "siteMoved", "from" to asked.url.toString(), "to" to reached.toString()),
            ),
        )
    }

    /**
     * Whether [response] is a check a browser can clear, as the app's triage tells it
     * (`lib/core/network/clearance/challenge_triage.dart`): Cloudflare's challenge or DDoS-Guard's,
     * never a block page.
     */
    internal fun isChallenge(response: Response): Boolean {
        if (response.header("cf-mitigated").equals("challenge", ignoreCase = true)) return true
        // AWS WAF (IMDb's, a 202) and Vercel (a 429) say so in headers of their own.
        if (response.header("x-amzn-waf-action").equals("challenge", ignoreCase = true) ||
            response.header("x-vercel-mitigated").equals("challenge", ignoreCase = true)
        ) {
            return true
        }
        val server = response.header("Server")?.lowercase() ?: ""
        val code = response.code
        if (code == 200) return isCheckPage(response)
        val unsure = when {
            server.contains("ddos-guard") -> code == 403 || code == 503
            server.contains("cloudflare") -> code == 403 || code == 503 || code == 429
            else -> false
        }
        if (!unsure) return false
        val body = try {
            response.peekBody(PEEK).string()
        } catch (_: Exception) {
            return false
        }
        // Block pages carry Cloudflare's detection script (`.../scripts/jsd/`) too; only the
        // challenge's own (`.../h/`) counts.
        if (body.contains("Attention Required! | Cloudflare") || body.contains("Sorry, you have been blocked") ||
            body.contains("cf-error-details")
        ) {
            return false
        }
        return body.contains("_cf_chl_opt") || body.contains("/cdn-cgi/challenge-platform/h/") ||
            body.contains("<title>Just a moment...</title>") ||
            (body.contains("ddos-guard") && body.contains("check.ddos-guard.net"))
    }

    /**
     * A 200 page that is a check all the same, as the app's `triagePage` tells it: Anubis' (its assets
     * live under `/.within.website/`) or HostAdmin's ("Verification..." with its own `ha-waf-` cookie).
     */
    private fun isCheckPage(response: Response): Boolean {
        val type = response.header("Content-Type")?.lowercase()
        if (type != null && !type.contains("html")) return false
        val body = try {
            response.peekBody(CHECK_PAGE_PEEK).string()
        } catch (_: Exception) {
            return false
        }
        if (body.contains("/.within.website/")) return true
        return body.contains("<title>Verification...</title>") &&
            response.headers("Set-Cookie").any { it.contains("ha-waf-") }
    }

    /**
     * Any 403 from Cloudflare but a block page, as CloudStream's own `CloudflareKiller` asks its browser. A 503 with
     * none of a check's marks is the origin's own (overload, maintenance); one that is a check carries them.
     */
    internal fun isRefusal(response: Response): Boolean {
        if (isChallenge(response)) return true
        if (response.code != 403) return false
        if (!(response.header("Server") ?: "").contains("cloudflare", ignoreCase = true)) return false
        val body = try {
            response.peekBody(PEEK).string()
        } catch (_: Exception) {
            return false
        }
        return !body.contains("Sorry, you have been blocked") && !body.contains("cf-error-details")
    }

    /** [request] sent from inside one of its site's pages, answered as the page got it; null when it can't be. */
    private fun fromPage(request: Request): Response? {
        val webView = HostHooks.webView ?: return null
        val body = textBody(request) ?: return null
        val page = webView.fetchInPage(
            PageRequest(request.url.toString(), request.method, request.headers.toMap(), body.ifEmpty { null }),
        ) ?: return null
        val headers = Headers.Builder()
        for ((name, value) in page.headers) {
            // The page's fetch hands the body over decoded: its encoding and length no longer hold.
            if (name.equals("content-encoding", ignoreCase = true) || name.equals("content-length", ignoreCase = true)) continue
            runCatching { headers.addUnsafeNonAscii(name, value) }
        }
        val type = page.headers.entries.firstOrNull { it.key.equals("content-type", ignoreCase = true) }?.value
        val answered = request.newBuilder().url(page.url.toHttpUrlOrNull() ?: request.url).build()
        return Response.Builder()
            .request(handled(answered))
            .protocol(Protocol.HTTP_1_1)
            .code(page.status)
            .message("")
            .headers(headers.build())
            .body(page.body.toResponseBody(type?.toMediaTypeOrNull()))
            .build()
    }

    /** [request]'s body as text, "" when it has none; null when it isn't text a page's `fetch` can send. */
    private fun textBody(request: Request): String? {
        val body = request.body ?: return ""
        if (body.isOneShot() || body.isDuplex() || body.contentLength() > PAGE_BODY) return null
        val type = body.contentType()
        val text = type == null || type.type == "text" ||
            listOf("json", "xml", "javascript", "x-www-form-urlencoded").any { it in type.subtype }
        if (!text) return null
        return Buffer().also { body.writeTo(it) }.readUtf8()
    }

    private fun handled(request: Request): Request = request.newBuilder().tag(Handled::class.java, Handled).build()

    private fun handled(response: Response): Response = response.newBuilder().request(handled(response.request)).build()
}
