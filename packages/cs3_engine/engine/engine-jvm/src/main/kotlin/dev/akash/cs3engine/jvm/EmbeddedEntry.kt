package dev.akash.cs3engine.jvm

import dev.akash.cs3engine.Engine
import dev.akash.cs3engine.host.HostHooks
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File

/**
 * JNI entry points for hosts that embed the VM in-process (iOS). The host registers the
 * `external` functions with RegisterNatives before calling [start].
 */
object EmbeddedEntry {
    @Volatile
    private var engine: Engine? = null

    private val requests = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @JvmStatic
    fun start(dataDir: String, platform: String) {
        HostHooks.event = ::emit
        if (engine == null) engine = JvmEngine.create(File(dataDir), platform)
    }

    /**
     * Answers [requestJson] through [reply], tagged with [token], once it is done, and returns at
     * once: requests can take minutes (a first load converts the plugin), and the host's threads
     * must stay free for the next ones.
     */
    @JvmStatic
    fun submit(token: Long, requestJson: String) {
        val engine = engine ?: error("EmbeddedEntry.start() was not called")
        requests.launch { reply(token, engine.respond(requestJson)) }
    }

    /** Passes an event to the app. */
    @JvmStatic
    external fun emit(event: String)

    /** Passes the response to the request submitted with [token] to the app. */
    @JvmStatic
    external fun reply(token: Long, response: String)
}
