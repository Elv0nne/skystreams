package dev.akash.cs3engine.stubs

import android.content.Context
import android.content.Intent
import java.util.Collections

/** The engine's side, recorded: what the stand-ins handed to the platform. */
class RecordingPlatform : Platform.Host {
    /** What an exit throws here, as the engine's RestartRequested does. */
    class ExitStopped(val status: Int) : Error("exit($status) stopped")

    val started: MutableList<Intent> = Collections.synchronizedList(mutableListOf())
    val toasts: MutableList<String> = Collections.synchronizedList(mutableListOf())
    val copies: MutableList<String> = Collections.synchronizedList(mutableListOf())
    val exits: MutableList<Int> = Collections.synchronizedList(mutableListOf())
    val uncaught: MutableList<Throwable> = Collections.synchronizedList(mutableListOf())

    override fun startActivity(context: Context, intent: Intent) {
        started += intent
    }

    override fun toast(text: CharSequence) {
        toasts += text.toString()
    }

    override fun copy(text: CharSequence) {
        copies += text.toString()
    }

    override fun exit(status: Int) {
        exits += status
        throw ExitStopped(status)
    }

    override fun uncaught(error: Throwable) {
        uncaught += error
    }
}
