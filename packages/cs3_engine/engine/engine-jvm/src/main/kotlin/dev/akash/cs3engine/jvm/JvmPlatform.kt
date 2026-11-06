package dev.akash.cs3engine.jvm

import android.content.Context
import android.content.Intent
import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.host.RestartRequested
import dev.akash.cs3engine.stubs.Platform
import java.io.File

/**
 * What Android does for extensions itself, on the JVM and iOS: links, shares, copies and toasts go to the
 * app as events ([notice]), with the extension whose code asked ([pluginIn] of the stack). The app's
 * restart and an exit end that code with [RestartRequested], which the engine reloads the extension for,
 * as Android's RestartGuard does. A crash of an extension's main-thread code ends its screen.
 */
class JvmPlatform(
    private val pluginIn: (Throwable) -> File?,
    private val notice: (type: String, plugin: File?, fields: Map<String, Any?>) -> Unit,
) : Platform.Host {
    override fun startActivity(context: Context, intent: Intent) {
        val calling = pluginIn(Throwable())
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
        when {
            isRestart(context, intent) -> if (calling != null) restart()
            intent.action == Intent.ACTION_CHOOSER -> intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)?.let { startActivity(context, it) }
            intent.action == Intent.ACTION_VIEW && intent.data?.scheme?.lowercase() in WEB -> notice("openUrl", calling, mapOf("url" to intent.data.toString()))
            intent.action == Intent.ACTION_SEND && text != null -> notice("copy", calling, mapOf("text" to text.toString()))
            else -> HostHooks.log("${calling?.name ?: "the engine"} started $intent, which nothing here opens")
        }
    }

    override fun toast(text: CharSequence) = notice("toast", pluginIn(Throwable()), mapOf("text" to text.toString()))

    override fun copy(text: CharSequence) = notice("copy", pluginIn(Throwable()), mapOf("text" to text.toString()))

    /** An exit: the extension asked to end the process, as its restarts do once they've started the app again. */
    override fun exit(status: Int) {
        restart()
    }

    override fun uncaught(error: Throwable) {
        if (error is RestartRequested) {
            if (!error.reported) HostHooks.restartRequested(error)
            return
        }
        val plugin = pluginIn(error)
        if (plugin == null) {
            HostHooks.log("a main-thread task failed: ${error.stackTraceToString()}")
            return
        }
        HostHooks.log("${plugin.name} crashed on the main thread; its screen ends: ${error.stackTraceToString()}")
        HostHooks.pluginCrashed(error)
    }

    /** As Android's RestartGuard: the app's own component, as a new task that clears the old one. */
    private fun isRestart(context: Context, intent: Intent): Boolean {
        val component = intent.component ?: return false
        return component.packageName == context.packageName && intent.flags and Intent.FLAG_ACTIVITY_CLEAR_TASK != 0
    }

    /** Told before it's thrown: an extension that catches every Throwable around its restart would hide it. */
    private fun restart(): Nothing {
        val restart = RestartRequested()
        HostHooks.restartRequested(restart)
        restart.reported = true
        throw restart
    }

    private companion object {
        val WEB = setOf("http", "https")
    }
}
