package com.lingjhf.vlc_player

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * The device's media volume for the player's swipe and its rail: Android's
 * media stream, set the way VLC's player sets it.
 *
 * - A level becomes one of the stream's steps, and only a new step is a call:
 *   a swipe sends many levels per step.
 * - Set without the system's volume pop-up. A raise the hearing-safety limit
 *   held back is asked again with the system's UI, which is what shows its
 *   "raise volume above the recommended level?" prompt (VLC's fix since
 *   Android 4.3).
 * - Every AudioManager call is a binder call into the audio service, which can
 *   stall while a Bluetooth route changes, so they run in order on a thread of
 *   their own, as Media3's StreamVolumeManager runs them. Replies and events go
 *   back on the main thread, where Flutter takes them.
 */
internal class VlcSystemVolume(context: Context) : EventChannel.StreamHandler {
    private val appContext = context.applicationContext
    private val audioManager =
        appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())

    // Started on the first call, not at registration: the plugin registers in
    // every app session, and most never open the player.
    private val workerStarted = lazy { HandlerThread("vlc_player-volume").apply { start() } }
    private val background by lazy { Handler(workerStarted.value.looper) }

    private var sink: EventChannel.EventSink? = null
    private var receiverRegistered = false

    /**
     * The step last handed on. Android announces a change of any stream - the
     * ringer, an alarm - with the same broadcast, so only a new step of this one
     * is a change. Read and written on the worker thread only.
     */
    private var lastIndex = -1

    private var activity: Activity? = null
    private var playerShown = false
    private var controlStreamBefore: Int? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != VOLUME_CHANGED_ACTION) return
            // The broadcast names a stream and a value, but the stream that moved
            // can be an alias of this one, so the level is read back, as Media3
            // reads it.
            background.post {
                val index = runCatching { audioManager.getStreamVolume(STREAM) }.getOrNull()
                if (index == null || index == lastIndex) return@post
                lastIndex = index
                val level = VlcDeviceLevels.levelFor(index, maxIndex())
                main.post { sink?.success(level) }
            }
        }
    }

    /** The activity whose volume keys the player takes while it is shown, or none. */
    fun attach(activity: Activity?) {
        if (this.activity === activity) return
        releaseKeys()
        this.activity = activity
        if (playerShown) takeKeys()
    }

    /** The current level, 0..1, or null if the platform gave none. */
    fun get(result: MethodChannel.Result) {
        background.post {
            val level = runCatching {
                VlcDeviceLevels.levelFor(audioManager.getStreamVolume(STREAM), maxIndex())
            }.getOrNull()
            main.post { result.success(level) }
        }
    }

    /** Sets the level, 0..1, and answers the level that stood. */
    fun set(level: Double, result: MethodChannel.Result) {
        background.post {
            apply(level)
            val stood = runCatching {
                VlcDeviceLevels.levelFor(audioManager.getStreamVolume(STREAM), maxIndex())
            }.getOrNull()
            main.post { result.success(stood) }
        }
    }

    /** Whether apps can't change the volume (Chromebooks, some TV boxes). */
    fun isFixed(result: MethodChannel.Result) {
        background.post {
            val fixed = runCatching { audioManager.isVolumeFixed }.getOrDefault(false)
            main.post { result.success(fixed) }
        }
    }

    /**
     * While the player is shown, the volume keys move the media stream even
     * with the film paused, as Android's guide asks of a media app; afterwards
     * the activity's own choice comes back.
     */
    fun setPlayerShown(shown: Boolean) {
        if (shown == playerShown) return
        playerShown = shown
        if (shown) takeKeys() else releaseKeys()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        background.post {
            lastIndex = runCatching { audioManager.getStreamVolume(STREAM) }.getOrDefault(-1)
        }
        if (receiverRegistered) return
        val filter = IntentFilter(VOLUME_CHANGED_ACTION)
        // A protected system broadcast, so the Android 14 export flag is not
        // strictly required - but explicit, as for the noisy receiver.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            appContext.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        unregister()
    }

    fun dispose() {
        sink = null
        unregister()
        setPlayerShown(false)
        activity = null
        if (workerStarted.isInitialized()) workerStarted.value.quitSafely()
    }

    private fun apply(level: Double) {
        try {
            val wanted = VlcDeviceLevels.indexFor(level, maxIndex())
            val before = audioManager.getStreamVolume(STREAM)
            if (wanted == before) return
            audioManager.setStreamVolume(STREAM, wanted, 0)
            if (VlcDeviceLevels.heldBack(wanted, before, audioManager.getStreamVolume(STREAM))) {
                audioManager.setStreamVolume(STREAM, wanted, AudioManager.FLAG_SHOW_UI)
            }
        } catch (e: RuntimeException) {
            // Some devices refuse - a SecurityException over Do Not Disturb, a
            // policy. The player's rail reads the real level back.
        }
    }

    private fun maxIndex(): Int = audioManager.getStreamMaxVolume(STREAM)

    private fun takeKeys() {
        val activity = activity ?: return
        if (controlStreamBefore == null) controlStreamBefore = activity.volumeControlStream
        activity.volumeControlStream = STREAM
    }

    private fun releaseKeys() {
        val before = controlStreamBefore ?: return
        controlStreamBefore = null
        activity?.volumeControlStream = before
    }

    private fun unregister() {
        if (!receiverRegistered) return
        receiverRegistered = false
        // Unregistering one that is not registered throws, and this runs from
        // teardown.
        runCatching { appContext.unregisterReceiver(receiver) }
    }

    private companion object {
        const val STREAM = AudioManager.STREAM_MUSIC

        // AudioManager.VOLUME_CHANGED_ACTION is hidden from the SDK; Media3
        // listens for it by name too.
        const val VOLUME_CHANGED_ACTION = "android.media.VOLUME_CHANGED_ACTION"
    }
}
