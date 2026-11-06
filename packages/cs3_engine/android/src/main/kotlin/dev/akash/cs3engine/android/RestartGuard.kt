package dev.akash.cs3engine.android

import android.content.Context
import android.content.Intent
import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.host.RestartRequested

/**
 * Stops extensions restarting the app. 44 of the 79 settings screens surveyed restart it: the launch
 * intent with `Intent.makeRestartActivityTask`, then `Runtime.exit(0)`, which would end SkyStream. 37 of
 * the 51 restart methods call `requireContext().applicationContext.startActivity(…)`, the rest the
 * activity. Both come here (ExtensionHostApplication, CloudStream's MainActivity), and a restart from an
 * extension's code throws [RestartRequested] before the exit runs; the engine reloads the extension instead.
 */
object RestartGuard {
    @Volatile
    private var extensionCalling: () -> Boolean = { false }

    /** Set when the engine starts: whether an extension's code is calling. Asked of restarts only. */
    fun start(extensionCalling: () -> Boolean) {
        this.extensionCalling = extensionCalling
    }

    /** For tests: as before [start]. */
    fun reset() {
        extensionCalling = { false }
    }

    /** Whether [intent] restarts this app: its own component, as a new task that clears the old one. */
    fun isRestart(context: Context, intent: Intent?): Boolean {
        val component = intent?.component ?: return false
        return component.packageName == context.packageName && intent.flags and Intent.FLAG_ACTIVITY_CLEAR_TASK != 0
    }

    /** Throws [RestartRequested] for a restart an extension's code asks for. */
    fun check(context: Context, intent: Intent?) {
        if (!isRestart(context, intent) || !extensionCalling()) return
        // Told before it's thrown: an extension that catches every Throwable around its restart would hide
        // it from the engine. Its exit, after the start, doesn't run either way.
        val restart = RestartRequested()
        HostHooks.restartRequested(restart)
        restart.reported = true
        throw restart
    }
}
