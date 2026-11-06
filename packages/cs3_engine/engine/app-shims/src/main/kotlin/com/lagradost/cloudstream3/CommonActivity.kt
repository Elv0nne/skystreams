// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3

import android.app.Activity
import dev.akash.cs3engine.host.HostHooks

object CommonActivity {
    /** The app's activity: Android's, or the JVM engine's stand-in (JvmEngine). Extensions show their screens with it. */
    var activity: Activity? = null
        private set

    fun setActivityInstance(newActivity: Activity?) {
        activity = newActivity
    }

    fun showToast(message: String?, duration: Int? = null) {
        if (message != null) HostHooks.toast(message)
    }

    fun showToast(act: Activity?, message: String?, duration: Int? = null) {
        showToast(message, duration)
    }
}
