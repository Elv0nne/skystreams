package dev.akash.cs3engine.android

import android.os.Handler
import android.os.Looper
import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.host.RestartRequested

/**
 * Keeps a plugin's own threads and callbacks from crashing the app. Android kills the
 * process on any uncaught exception; CloudStream accepts that, but a plugin bug should not
 * take down the app that embeds the engine.
 *
 * Only errors whose stack runs through a plugin's classes are dropped (and logged): on a
 * background thread that thread ends, on the main thread the message loop continues.
 * Every other error still crashes the app.
 */
internal object PluginCrashGuard {
    @Volatile
    private var installed = false

    /**
     * Deals with an error that reached the main loop: an extension's restart reloads it
     * ([RestartRequested], e.g. from an alert's button, whose listener runs in a later message); a
     * plugin's crash is logged. False when the error is the app's own, which must crash as before.
     */
    internal fun handle(error: Throwable, pluginIn: (Throwable) -> String?): Boolean {
        if (error is RestartRequested) {
            if (!error.reported) HostHooks.restartRequested(error)
            return true
        }
        val plugin = pluginIn(error) ?: return false
        HostHooks.log("$plugin crashed on the main thread; ignored: ${error.stackTraceToString()}")
        // Its open screen, if it has one, ends: what's left of it may no longer work.
        HostHooks.pluginCrashed(error)
        return true
    }

    fun install(pluginIn: (Throwable) -> String?) {
        if (installed) return
        installed = true

        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            if (error is RestartRequested) {
                if (!error.reported) HostHooks.restartRequested(error)
                return@setDefaultUncaughtExceptionHandler
            }
            val plugin = if (thread === Looper.getMainLooper().thread) null else pluginIn(error)
            if (plugin != null) {
                HostHooks.log("$plugin crashed on thread ${thread.name}; ignored: ${error.stackTraceToString()}")
            } else {
                previous?.uncaughtException(thread, error)
            }
        }

        // The main thread cannot continue once an error leaves Looper.loop(), so run the loop
        // from inside a catch. Messages then run in this nested loop for the life of the app.
        Handler(Looper.getMainLooper()).post {
            while (true) {
                try {
                    Looper.loop()
                } catch (error: Throwable) {
                    if (!handle(error, pluginIn)) throw error
                }
            }
        }
    }
}
