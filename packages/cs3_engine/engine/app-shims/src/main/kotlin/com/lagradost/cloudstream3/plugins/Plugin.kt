// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.plugins

import android.content.Context
import android.content.res.Resources
import com.lagradost.cloudstream3.actions.VideoClickAction

/** Base class Android-flavoured plugins extend; mirrors the app's `plugins.Plugin`. */
abstract class Plugin : BasePlugin() {
    /** Called when the plugin is loaded. Falls back to the cross-platform [load]. */
    @Throws(Throwable::class)
    open fun load(context: Context) {
        load()
    }

    /** The app lists these on a video's links; SkyStream shows none, so the action is only marked as the plugin's. */
    fun registerVideoClickAction(element: VideoClickAction) {
        element.sourcePlugin = this.filename
    }

    /** Set when the plugin's manifest asks for resources (not supported off-Android yet). */
    var resources: Resources? = null

    /** Settings screen entry point; the host decides whether it can show it. */
    var openSettings: ((context: Context) -> Unit)? = null
}
