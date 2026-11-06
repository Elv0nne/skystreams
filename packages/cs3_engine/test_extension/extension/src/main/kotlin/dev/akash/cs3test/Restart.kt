package dev.akash.cs3test

import android.app.Activity
import android.content.Context
import android.content.Intent

/**
 * How most extensions restart the app (37 of the 51 restart methods surveyed): the launch intent as a
 * new task, through the application context, then exit. SkyStream must stop it before the exit.
 */
fun restartThroughAppContext(context: Context) {
    val app = context.applicationContext
    val launch = app.packageManager.getLaunchIntentForPackage(app.packageName) ?: return
    app.startActivity(Intent.makeRestartActivityTask(launch.component))
    Runtime.getRuntime().exit(0)
}

/** The other way (14 of the 51): through the activity. */
fun restartThroughActivity(activity: Activity) {
    val launch = activity.packageManager.getLaunchIntentForPackage(activity.packageName) ?: return
    activity.startActivity(Intent.makeRestartActivityTask(launch.component))
    Runtime.getRuntime().exit(0)
}
