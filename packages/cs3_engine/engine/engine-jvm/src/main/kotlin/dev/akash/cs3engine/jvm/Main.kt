package dev.akash.cs3engine.jvm

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import dev.akash.cs3engine.host.HostHooks
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.io.FileDescriptor
import java.io.FileOutputStream
import java.io.PrintStream
import kotlin.system.exitProcess

/**
 * Desktop entry point.
 *
 *   --stdio <dataDir>          engine protocol: one JSON request per stdin line, one response per stdout line;
 *                              events (lines without an id) go out on stdout between responses
 *   --scan <dataDir> <dir>     load every .cs3 under <dir> and print one JSON line per plugin
 */
fun main(args: Array<String>) {
    // Stdout carries protocol messages only; the library and plugins println freely.
    val protocol = PrintStream(FileOutputStream(FileDescriptor.out), true, "UTF-8")
    // Logs in UTF-8 too: on Windows stderr otherwise uses the ANSI code page.
    System.setErr(PrintStream(FileOutputStream(FileDescriptor.err), true, "UTF-8"))
    System.setOut(System.err)

    when (args.getOrNull(0)) {
        "--stdio" -> serveStdio(File(args[1]), protocol)
        "--scan" -> scan(File(args[1]), File(args[2]), protocol)
        else -> {
            System.err.println("usage: --stdio <dataDir> | --scan <dataDir> <pluginDir>")
            exitProcess(2)
        }
    }
    exitProcess(0)
}

private fun serveStdio(dataDir: File, protocol: PrintStream) {
    HostHooks.event = { event -> synchronized(protocol) { protocol.println(event) } }
    val engine = JvmEngine.create(dataDir, "desktop")
    val requests = SupervisorJob()
    val scope = CoroutineScope(requests + Dispatchers.Default)
    // Requests run concurrently; responses carry the request id.
    System.`in`.bufferedReader(Charsets.UTF_8).forEachLine { line ->
        if (line.isBlank()) return@forEachLine
        scope.launch {
            val response = engine.respond(line)
            synchronized(protocol) { protocol.println(response) }
        }
    }
    // stdin closed: the app has gone. Finish what was asked, briefly: a plugin stuck in a call must
    // not keep the process alive (main exits it).
    runBlocking { withTimeoutOrNull(5_000) { requests.children.toList().joinAll() } }
}

private fun scan(dataDir: File, pluginDir: File, protocol: PrintStream) = runBlocking {
    val engine = JvmEngine.create(dataDir, "desktop-scan")
    val mapper = jacksonObjectMapper()
    val files = pluginDir.walkTopDown().filter { it.isFile && it.extension == "cs3" }.sortedBy { it.path }.toList()
    files.forEachIndexed { index, file ->
        val request = mapper.writeValueAsString(mapOf("id" to index, "method" to "loadPlugin", "params" to mapOf("path" to file.absolutePath)))
        val response = mapper.readTree(engine.respond(request))
        val line = mapOf(
            "file" to file.relativeTo(pluginDir).path,
            "ok" to response.has("result"),
            "providers" to response.path("result").path("providers").size(),
            "notes" to response.path("result").path("notes"),
            "error" to response.path("error").path("type").asText(null),
            "message" to response.path("error").path("message").asText(null),
        )
        protocol.println(mapper.writeValueAsString(line))
    }
}
