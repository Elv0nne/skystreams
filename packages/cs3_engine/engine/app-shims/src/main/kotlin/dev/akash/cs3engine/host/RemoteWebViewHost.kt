package dev.akash.cs3engine.host

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * The app's browser, reached over the engine protocol, and, for extension screens on the JVM, the pages
 * their web views show (`page`, `navigate`, `closePage`, `eval`), whose events come back through the
 * `webPage` method ([pageEvent]). Each operation goes out as a `webRequest` event, whose `op` is `solve`,
 * `fetch` or `resolve`, and the app answers with the `webReply` method. A resolve's page also reports its requests (`webCaptured`) and its script's results
 * (`webScript`), which the engine matches with the extension's own patterns. The asking thread (an
 * extension's) waits; the engine's own threads never do. The calling engine call's clock stands
 * still meanwhile.
 */
object RemoteWebViewHost : WebViewHost {
    /** How long a solve or an in-page request may take: a hidden one, or a person ticking the check. */
    @Volatile
    internal var answerTimeoutMs = 90_000L

    private val ids = AtomicLong()
    private val pending = ConcurrentHashMap<Long, CompletableFuture<JsonNode>>()
    private val resolves = ConcurrentHashMap<Long, Resolve>()
    private val evals = ConcurrentHashMap<Long, (String) -> Unit>()
    private val mapper = ObjectMapper()

    private class Resolve(val onRequest: (String, String?) -> Boolean, val onScript: (String) -> Unit) {
        val ended = CompletableDeferred<Unit>()
    }

    override fun solveCloudflare(url: String, failed: WebClearance?): WebClearance? {
        val asked = mutableMapOf<String, Any?>("op" to "solve", "url" to url)
        failed?.let { asked["failed"] = it.cookies }
        val answer = ask(asked) ?: return null
        val agent = answer.path("userAgent").asText("")
        val cookies = textMap(answer.path("cookies"))
        if (agent.isEmpty() || cookies.isEmpty()) return null
        return WebClearance(cookies, agent, earned = answer.path("earned").asBoolean(true))
    }

    override fun fetchInPage(request: PageRequest): PageResponse? {
        val answer = ask(
            mapOf(
                "op" to "fetch",
                "url" to request.url,
                "method" to request.method,
                "headers" to request.headers,
                "body" to request.body,
            ),
        ) ?: return null
        if (!answer.path("status").isInt) return null
        return PageResponse(
            answer.path("status").asInt(),
            answer.path("url").asText(request.url),
            textMap(answer.path("headers")),
            answer.path("body").asText(""),
        )
    }

    override suspend fun resolvePage(
        url: String,
        headers: Map<String, String>,
        script: String?,
        timeoutMs: Long,
        onScript: (String) -> Unit,
        onRequest: (url: String, method: String?) -> Boolean,
    ) {
        val rid = ids.incrementAndGet()
        val resolve = Resolve(onRequest, onScript)
        resolves[rid] = resolve
        BrokerClock.shared.pause()
        try {
            send(rid, mapOf("op" to "resolve", "url" to url, "headers" to headers, "script" to script, "timeoutMs" to timeoutMs))
            withTimeoutOrNull(timeoutMs) { resolve.ended.await() }
        } finally {
            resolves.remove(rid)
            BrokerClock.shared.resume()
        }
    }

    /** A request the page of resolve [rid] made. True when the resolve is done, or has ended: the app closes the page. */
    fun captured(rid: Long, url: String, method: String?): Boolean {
        val resolve = resolves[rid] ?: return true
        val done = try {
            resolve.onRequest(url, method)
        } catch (e: Exception) {
            HostHooks.log("Resolve: the extension failed on $url (${e.javaClass.simpleName})")
            false
        }
        if (done) resolve.ended.complete(Unit)
        return done
    }

    /** What the script of resolve [rid] returned in its page. */
    fun scriptResult(rid: Long, result: String) {
        val resolve = resolves[rid] ?: return
        try {
            resolve.onScript(result)
        } catch (e: Exception) {
            HostHooks.log("Resolve: the extension's script callback failed (${e.javaClass.simpleName})")
        }
    }

    /** Hears the app's events about the pages [openPage] asked for: JvmPages. */
    interface PageEvents {
        /** Page [rid]'s [event]: its `type` (started, finished, failed, message, request, closed) and fields. */
        fun event(rid: Long, event: JsonNode)

        /**
         * Page [rid]'s [event] that waits for its answer (Phase 7c): `call`, an answering JavaScript call (`{value}`,
         * `{error}`, or `{}` for undefined), or `dialog`, the page's own alert, confirm or prompt (`{accept, text?}`, or
         * `{show: true}` for the app to show it).
         */
        suspend fun answer(rid: Long, event: JsonNode): Map<String, Any?>
    }

    @Volatile
    var pageEvents: PageEvents? = null

    /**
     * Asks the app for a page shown at node [node] of screen [session], loading [url] with [headers] and [userAgent]
     * (null: the browser's own), with [interfaces] (name to its one-way methods) and [answering] (name to its methods
     * that answer the page, Phase 7c's §7). Returns its rid, which its events carry; nothing waits. [serve], when the app
     * serves the page's folder (Phase 7c's §6): `name`, `folder`, `path` below it, and the folder's own `file` address.
     */
    fun openPage(
        session: Int,
        node: Int,
        url: String,
        headers: Map<String, String>,
        userAgent: String?,
        interfaces: Map<String, List<String>>,
        fullScreen: Boolean = false,
        serve: Map<String, String>? = null,
        answering: Map<String, List<String>> = emptyMap(),
    ): Long {
        val rid = ids.incrementAndGet()
        val op = mutableMapOf<String, Any?>(
            "op" to "page", "session" to session, "node" to node, "url" to url, "headers" to headers,
            "userAgent" to userAgent, "interfaces" to interfaces,
        )
        // In a full-screen window: the app gives the page its extension's toasts, and a desktop its own close button.
        if (fullScreen) op["fullScreen"] = true
        // A page of the extension's own files: the app serves its folder (Phase 7c's §6).
        if (serve != null) op["serve"] = serve
        if (answering.isNotEmpty()) op["answering"] = answering
        send(rid, op)
        return rid
    }

    /** Page [rid] loads [url]: a later loadUrl on its web view; [serve] as [openPage]'s. */
    fun navigatePage(rid: Long, url: String, headers: Map<String, String>, serve: Map<String, String>? = null) =
        send(rid, mapOf("op" to "navigate", "url" to url, "headers" to headers) + (if (serve != null) mapOf("serve" to serve) else emptyMap()))

    /** Page [rid] goes: the app disposes it. */
    fun closePage(rid: Long) = send(rid, mapOf("op" to "closePage"))

    /** Runs [script] in page [page]; [onResult] hears its result as JSON text ("null" when the app couldn't), on the answer's thread. */
    fun evalPage(page: Long, script: String, onResult: (String) -> Unit) {
        val rid = ids.incrementAndGet()
        evals[rid] = onResult
        send(rid, mapOf("op" to "eval", "page" to page, "script" to script))
    }

    /**
     * An event of page [rid], from the app (`webPage`), and what the app's request answers: `call` and `dialog` wait
     * for theirs (with no pages: undefined, and cancel); the rest answer true at once.
     */
    suspend fun pageEvent(rid: Long, event: JsonNode): Any = when (event.path("type").asText()) {
        "call" -> pageEvents?.answer(rid, event) ?: emptyMap<String, Any?>()
        "dialog" -> pageEvents?.answer(rid, event) ?: mapOf("accept" to false)
        else -> {
            pageEvents?.event(rid, event)
            true
        }
    }

    /** The app's answer to request [rid]: what its `op` asked for, or nothing when it couldn't. Ends a resolve. */
    fun reply(rid: Long, answer: JsonNode) {
        evals.remove(rid)?.let { onResult -> onResult(answer.path("result").asText("null")) }
        pending.remove(rid)?.complete(answer)
        resolves[rid]?.ended?.complete(Unit)
    }

    /** Sends [fields] as a `webRequest` and waits for the app's answer: null when none came in time. */
    private fun ask(fields: Map<String, Any?>): JsonNode? {
        val rid = ids.incrementAndGet()
        val answer = CompletableFuture<JsonNode>()
        pending[rid] = answer
        BrokerClock.shared.pause()
        return try {
            send(rid, fields)
            answer.get(answerTimeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: Exception) {
            HostHooks.log("${fields["op"]} for ${fields["url"]}: no answer from the app (${e.javaClass.simpleName})")
            null
        } finally {
            pending.remove(rid)
            BrokerClock.shared.resume()
        }
    }

    private fun send(rid: Long, fields: Map<String, Any?>) {
        HostHooks.event(mapper.writeValueAsString(mapOf("event" to "webRequest", "rid" to rid) + fields))
    }

    private fun textMap(node: JsonNode): Map<String, String> =
        node.fields().asSequence().associate { it.key to it.value.asText() }
}
