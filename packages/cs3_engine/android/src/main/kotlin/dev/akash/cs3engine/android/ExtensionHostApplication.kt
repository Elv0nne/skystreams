package dev.akash.cs3engine.android

import android.app.Application
import android.content.Intent
import android.os.Bundle

/**
 * The host app's Application must be this, or extend it: extensions restart the app through
 * `applicationContext.startActivity(…)`, which reaches here, and a restart from an extension's code stops
 * (see RestartGuard). It's the real Application, so an extension casting its context to one gets it.
 */
open class ExtensionHostApplication : Application() {
    override fun startActivity(intent: Intent?) {
        RestartGuard.check(this, intent)
        super.startActivity(intent)
    }

    override fun startActivity(intent: Intent?, options: Bundle?) {
        RestartGuard.check(this, intent)
        super.startActivity(intent, options)
    }
}
