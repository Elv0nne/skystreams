package dev.akash.cs3engine

import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.utils.ExtractorLink
import com.lagradost.cloudstream3.utils.ExtractorLinkType
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.BufferedInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit

/**
 * Cầu nối cho `MainAPI.getVideoInterceptor`.
 *
 * CloudStream (app) phát video bằng OkHttp có gắn Interceptor do plugin cung cấp: plugin có thể
 * giải mã segment, cắt phần đầu giả của file TS, hoặc dựng cả một "host giả" (vd hydrax-relay.internal)
 * mà chỉ Interceptor mới trả lời được. SkyStream phát bằng player gốc (libVLC) nên không có chỗ
 * để gắn Interceptor đó, và các link kiểu này trước đây không phát được.
 *
 * Cách giải quyết: với mỗi link mà plugin trả về Interceptor, engine thay URL bằng một URL
 * loopback `http://127.0.0.1:<port>/v/<id>/...`. Player kết nối vào đây; engine gửi request thật
 * bằng OkHttp CÓ Interceptor của plugin rồi chuyển kết quả (hỗ trợ Range) về cho player.
 * Với playlist m3u8, mọi URL trong đó cũng được viết lại để đi qua cầu này, đúng như ExoPlayer của
 * CloudStream gửi cả playlist lẫn segment qua cùng một client.
 *
 * Chỉ nghe trên 127.0.0.1, dùng `ServerSocket` thuần (không phụ thuộc com.sun.net.httpserver,
 * vốn không có trên Android) nên chạy giống nhau trên Android, iOS (OpenJDK Zero), macOS, Windows, Linux.
 */
object VideoProxy {
    private class Entry(
        val url: String,
        val headers: Map<String, String>,
        val referer: String?,
        val type: ExtractorLinkType,
        val client: OkHttpClient,
    )

    private const val MAX_ENTRIES = 256
    private const val MAX_PLAYLIST_BYTES = 8L * 1024 * 1024
    private const val COPY_BUFFER = 64 * 1024

    private val entries = object : LinkedHashMap<String, Entry>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Entry>?) = size > MAX_ENTRIES
    }
    private val random = SecureRandom()

    private val pool = Executors.newCachedThreadPool(object : ThreadFactory {
        private var n = 0
        override fun newThread(r: Runnable) = Thread(r, "cs3-videoproxy-${n++}").apply { isDaemon = true }
    })

    @Volatile private var server: ServerSocket? = null

    /** Các hop-by-hop / header không chuyển tiếp từ nguồn về player. */
    private val forwardedResponseHeaders = setOf(
        "content-type", "content-range", "accept-ranges", "last-modified", "etag", "cache-control",
    )

    // ---------------------------------------------------------------- đăng ký link

    /**
     * Trả về URL loopback nếu plugin có Interceptor cho [link], ngược lại `null` (dùng link gốc).
     * Không bao giờ ném lỗi: có sự cố gì thì link gốc vẫn được trả như trước.
     */
    fun wrap(api: MainAPI, link: ExtractorLink): String? = try {
        // Giống CS3IPlayer của CloudStream: interceptor lấy từ provider có TÊN trùng `link.source`
        // (`getApiFromNameNull(link.source)?.getVideoInterceptor(link)`), KHÔNG phải mọi link mà
        // provider này gọi callback. Link do extractor của host khác tạo (source = tên host đó) vẫn
        // đi thẳng, không bị interceptor của provider chen vào (có plugin thêm header/đổi request
        // chỉ đúng cho server của họ).
        val owner = if (link.source == api.name) api
        else com.lagradost.cloudstream3.APIHolder.getApiFromNameNull(link.source)
        val interceptor = owner?.getVideoInterceptor(link) ?: return null
        val port = ensureStarted()
        val id = newId()
        val base = com.lagradost.cloudstream3.app.baseClient
        val client = base.newBuilder()
            .addInterceptor(interceptor)
            .followRedirects(true)
            .followSslRedirects(true)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
        synchronized(entries) {
            entries[id] = Entry(link.url, link.headers, link.referer, link.type, client)
        }
        val suffix = if (link.type == ExtractorLinkType.M3U8) "index.m3u8" else "video.mp4"
        "http://127.0.0.1:$port/v/$id/main/$suffix"
    } catch (_: Throwable) {
        null
    }

    private fun newId(): String {
        val b = ByteArray(12)
        random.nextBytes(b)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(b)
    }

    /** Dùng cho test. */
    internal fun port(): Int = ensureStarted()

    @Synchronized
    private fun ensureStarted(): Int {
        server?.let { if (!it.isClosed) return it.localPort }
        val s = ServerSocket(0, 64, InetAddress.getLoopbackAddress())
        server = s
        pool.execute {
            while (!s.isClosed) {
                val socket = try {
                    s.accept()
                } catch (_: IOException) {
                    break
                }
                pool.execute { handle(socket) }
            }
        }
        return s.localPort
    }

    // ---------------------------------------------------------------- xử lý request

    private class Req(val method: String, val path: String, val headers: Map<String, String>)

    private fun handle(socket: Socket) {
        socket.use { sock ->
            try {
                sock.soTimeout = 15_000
                sock.tcpNoDelay = true
                val input = BufferedInputStream(sock.getInputStream(), 8192)
                val out = sock.getOutputStream()
                val req = readRequest(input) ?: return
                sock.soTimeout = 0
                serve(req, out)
            } catch (_: IOException) {
                // Player đóng kết nối giữa chừng (tua video làm việc này liên tục): bình thường.
            } catch (_: Throwable) {
            }
        }
    }

    private fun readLine(input: InputStream, limit: Int = 16 * 1024): String? {
        val sb = StringBuilder()
        while (true) {
            val c = input.read()
            if (c < 0) return if (sb.isEmpty()) null else sb.toString()
            if (c == '\n'.code) break
            if (c != '\r'.code) sb.append(c.toChar())
            if (sb.length > limit) throw IOException("dòng quá dài")
        }
        return sb.toString()
    }

    private fun readRequest(input: InputStream): Req? {
        val first = readLine(input) ?: return null
        val parts = first.split(' ')
        if (parts.size < 2) return null
        val headers = HashMap<String, String>()
        var count = 0
        while (true) {
            val line = readLine(input) ?: return null
            if (line.isEmpty()) break
            if (++count > 100) throw IOException("quá nhiều header")
            val i = line.indexOf(':')
            if (i > 0) headers[line.substring(0, i).trim().lowercase()] = line.substring(i + 1).trim()
        }
        return Req(parts[0].uppercase(), parts[1], headers)
    }

    private fun serve(req: Req, out: OutputStream) {
        if (req.method != "GET" && req.method != "HEAD") {
            return fail(out, 405, "Method Not Allowed")
        }
        // /v/<id>/main/<tên>        -> URL gốc của link
        // /v/<id>/s/<base64url>/<tên> -> tài nguyên phụ (segment, key, playlist con) trong m3u8
        val segs = req.path.substringBefore('?').split('/').filter { it.isNotEmpty() }
        if (segs.size < 3 || segs[0] != "v") return fail(out, 404, "Not Found")
        val entry = synchronized(entries) { entries[segs[1]] } ?: return fail(out, 404, "Not Found")

        val target: String
        val isMain: Boolean
        when (segs[2]) {
            "main" -> {
                target = entry.url
                isMain = true
            }
            "s" -> {
                if (segs.size < 4) return fail(out, 404, "Not Found")
                target = try {
                    String(Base64.getUrlDecoder().decode(segs[3]), Charsets.UTF_8)
                } catch (_: IllegalArgumentException) {
                    return fail(out, 400, "Bad Request")
                }
                isMain = false
            }
            else -> return fail(out, 404, "Not Found")
        }

        val builder = Request.Builder().url(target)
        entry.headers.forEach { (k, v) -> runCatching { builder.header(k, v) } }
        if (entry.referer != null && entry.headers.keys.none { it.equals("referer", true) }) {
            builder.header("Referer", entry.referer)
        }
        req.headers["range"]?.let { builder.header("Range", it) }
        req.headers["if-range"]?.let { builder.header("If-Range", it) }

        val response = try {
            entry.client.newCall(builder.build()).execute()
        } catch (e: IOException) {
            return fail(out, 502, "Bad Gateway")
        } catch (e: Throwable) {
            return fail(out, 502, "Bad Gateway")
        }

        response.use { resp ->
            val ct = resp.header("Content-Type")?.lowercase().orEmpty()
            val looksLikePlaylist = ct.contains("mpegurl") ||
                target.substringBefore('?').lowercase().endsWith(".m3u8") ||
                (isMain && entry.type == ExtractorLinkType.M3U8)

            if (looksLikePlaylist && resp.isSuccessful && resp.code != 206) {
                return servePlaylist(req, resp, segs[1], out)
            }
            streamBody(req, resp, out)
        }
    }

    private fun servePlaylist(req: Req, resp: Response, id: String, out: OutputStream) {
        val body = resp.body
        val declared = body.contentLength()
        if (declared > MAX_PLAYLIST_BYTES) return fail(out, 502, "Bad Gateway")
        val bytes = body.source().let { src ->
            val buf = okio.Buffer()
            var total = 0L
            while (true) {
                val n = src.read(buf, 8192)
                if (n < 0) break
                total += n
                if (total > MAX_PLAYLIST_BYTES) return fail(out, 502, "Bad Gateway")
            }
            buf.readByteArray()
        }
        val text = bytes.toString(Charsets.UTF_8)
        val result = if (text.trimStart().startsWith("#EXTM3U")) {
            rewritePlaylist(text, resp.request.url.toString(), id).toByteArray(Charsets.UTF_8)
        } else {
            bytes // không phải playlist thật: trả nguyên
        }
        val ctOut = if (text.trimStart().startsWith("#EXTM3U")) "application/vnd.apple.mpegurl"
        else resp.header("Content-Type") ?: "application/octet-stream"
        val head = StringBuilder("HTTP/1.1 200 OK\r\n")
        head.append("Content-Type: ").append(ctOut).append("\r\n")
        head.append("Content-Length: ").append(result.size).append("\r\n")
        head.append("Cache-Control: no-cache\r\nConnection: close\r\n\r\n")
        out.write(head.toString().toByteArray(Charsets.ISO_8859_1))
        if (req.method != "HEAD") out.write(result)
        out.flush()
    }

    /** Viết lại mọi URL trong playlist để đi qua cầu này. */
    internal fun rewritePlaylist(text: String, baseUrl: String, id: String): String {
        val base = baseUrl.toHttpUrlOrNull()
        val port = ensureStarted()
        fun proxied(raw: String): String {
            if (raw.startsWith("data:", ignoreCase = true)) return raw
            val abs = base?.resolve(raw)?.toString() ?: raw
            val b64 = Base64.getUrlEncoder().withoutPadding().encodeToString(abs.toByteArray(Charsets.UTF_8))
            val name = abs.substringBefore('?').substringAfterLast('/').ifBlank { "r" }
                .filter { it.isLetterOrDigit() || it == '.' || it == '_' || it == '-' }.ifBlank { "r" }
            return "http://127.0.0.1:$port/v/$id/s/$b64/$name"
        }
        val uriAttr = Regex("""URI="([^"]*)"""")
        return text.lines().joinToString("\n") { line ->
            val t = line.trim()
            when {
                t.isEmpty() -> line
                t.startsWith("#") -> if (t.contains("URI=\"")) {
                    uriAttr.replace(line) { m -> "URI=\"" + proxied(m.groupValues[1]) + "\"" }
                } else line
                else -> proxied(t)
            }
        }
    }

    private fun streamBody(req: Req, resp: Response, out: OutputStream) {
        val body = resp.body
        val length = body.contentLength()
        val head = StringBuilder("HTTP/1.1 ").append(resp.code).append(' ')
            .append(resp.message.ifBlank { reason(resp.code) }).append("\r\n")
        for ((name, value) in resp.headers) {
            if (name.lowercase() in forwardedResponseHeaders) head.append(name).append(": ").append(value).append("\r\n")
        }
        if (resp.code == 200 || resp.code == 206) {
            if (resp.header("Accept-Ranges") == null) head.append("Accept-Ranges: bytes\r\n")
        }
        if (length >= 0) head.append("Content-Length: ").append(length).append("\r\n")
        head.append("Connection: close\r\n\r\n")
        out.write(head.toString().toByteArray(Charsets.ISO_8859_1))
        if (req.method != "HEAD") {
            val source = body.source()
            val sink = okio.Buffer()
            while (true) {
                val n = source.read(sink, COPY_BUFFER.toLong())
                if (n < 0) break
                sink.writeTo(out)
            }
        }
        out.flush()
    }

    private fun fail(out: OutputStream, code: Int, message: String) {
        val bytes = ("HTTP/1.1 $code $message\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            .toByteArray(Charsets.ISO_8859_1)
        try {
            out.write(bytes)
            out.flush()
        } catch (_: IOException) {
        }
    }

    private fun reason(code: Int) = when (code) {
        200 -> "OK"
        206 -> "Partial Content"
        301 -> "Moved Permanently"
        302 -> "Found"
        304 -> "Not Modified"
        400 -> "Bad Request"
        403 -> "Forbidden"
        404 -> "Not Found"
        416 -> "Range Not Satisfiable"
        else -> "OK"
    }
}
