package com.lingjhf.vlc_player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * Audio focus and output-route changes for one player.
 *
 * Android shares audio by convention, not by force: nothing stops libVLC
 * decoding straight through a phone call, so a player that never asks for
 * focus talks over everything else and cannot be silenced from outside. The
 * focus request, its loss callbacks and the becoming-noisy broadcast are one
 * concern with one lifetime, so they live together here instead of spreading
 * through the platform view.
 *
 * Nothing in here decides what playback should do; it reports, and
 * [VlcPlayerPlatformView] acts.
 */
internal class VlcAudioFocusManager(
    context: Context,
    private val listener: Listener,
) {
    internal interface Listener {
        /**
         * Stop making noise. [transient] means focus is expected back, which is
         * the only case anything resumes from.
         */
        fun onAudioFocusPause(transient: Boolean)

        /** Get quieter rather than stop - something short is talking over us. */
        fun onAudioFocusDuck()

        /** Focus is ours again. */
        fun onAudioFocusGain()

        /** The output device went away: headphones out, or Bluetooth dropped. */
        fun onBecomingNoisy()
    }

    // The application context, not the activity's: this outlives a
    // configuration change and a receiver registered against a dead activity
    // is a leak with a crash at the end of it.
    private val appContext = context.applicationContext
    private val audioManager =
        appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        onMain {
            when (change) {
                AudioManager.AUDIOFOCUS_LOSS -> {
                    // Gone for good. Hold nothing, and stop listening for a
                    // gain that is not coming.
                    abandon()
                    listener.onAudioFocusPause(transient = false)
                }
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                    // The request stays registered, which is what makes the
                    // gain that follows a phone call reach us at all.
                    holdsFocus = false
                    listener.onAudioFocusPause(transient = true)
                }
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK ->
                    listener.onAudioFocusDuck()
                AudioManager.AUDIOFOCUS_GAIN -> {
                    // Also how a delayed request is finally granted: focus
                    // asked for during a phone call arrives here when the call
                    // ends.
                    holdsFocus = true
                    registerNoisyReceiver()
                    listener.onAudioFocusGain()
                }
            }
        }
    }

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                onMain { listener.onBecomingNoisy() }
            }
        }
    }

    private var focusRequest: AudioFocusRequest? = null
    private var requested = false
    private var holdsFocus = false
    private var noisyReceiverRegistered = false

    /**
     * Claims audio focus for movie playback.
     *
     * Returns whether playback may start now. A refusal means something else
     * holds the audio - a phone call, usually - and starting anyway is exactly
     * the noise this class exists to prevent.
     *
     * The request accepts a delayed grant, so the common refusal is not a dead
     * end: the system remembers it and calls back with a gain when the call
     * ends, and the player resumes from that. Without it a refused request is
     * silent forever, because focus *changes* are only reported for a request
     * that was granted.
     *
     * With no AudioManager at all there is nothing to arbitrate, so playback
     * goes ahead.
     */
    fun request(): Boolean {
        val audioManager = audioManager ?: return true
        if (holdsFocus) {
            return true
        }

        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build(),
                )
                // False: we duck rather than pause for a navigation prompt, so
                // the system may hand us a can-duck loss instead of a full one.
                .setWillPauseWhenDucked(false)
                .setAcceptsDelayedFocusGain(true)
                .setOnAudioFocusChangeListener(focusListener, mainHandler)
                .build()
            focusRequest = request
            audioManager.requestAudioFocus(request)
        } else {
            // AudioFocusRequest is API 26 and minSdk here is 24, so these two
            // releases get the old call and no delayed grant: the answer is yes
            // or no, and a no is the viewer's to retry.
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            )
        }

        holdsFocus = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        requested = holdsFocus || result == AUDIOFOCUS_REQUEST_DELAYED
        if (!requested) {
            focusRequest = null
        }
        if (holdsFocus) {
            registerNoisyReceiver()
        }
        return holdsFocus
    }

    /** Releases focus and stops listening for route changes. Idempotent. */
    fun abandon() {
        val audioManager = audioManager
        // A delayed request is not held yet but is still registered, and
        // leaving it registered means a gain arriving at a player that has
        // stopped caring.
        if (audioManager != null && requested) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let(audioManager::abandonAudioFocusRequest)
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(focusListener)
            }
        }
        focusRequest = null
        requested = false
        holdsFocus = false
        unregisterNoisyReceiver()
    }

    fun dispose() {
        abandon()
    }

    private fun registerNoisyReceiver() {
        if (noisyReceiverRegistered) {
            return
        }
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        // ACTION_AUDIO_BECOMING_NOISY is a protected system broadcast, so the
        // Android 14 export flag is not strictly required - but being explicit
        // costs nothing and survives the next tightening of the rule.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appContext.registerReceiver(
                noisyReceiver,
                filter,
                Context.RECEIVER_NOT_EXPORTED,
            )
        } else {
            appContext.registerReceiver(noisyReceiver, filter)
        }
        noisyReceiverRegistered = true
    }

    private fun unregisterNoisyReceiver() {
        if (!noisyReceiverRegistered) {
            return
        }
        noisyReceiverRegistered = false
        // Unregistering one that is not registered throws, and this runs from
        // dispose - the one path that must never take the teardown down.
        runCatching { appContext.unregisterReceiver(noisyReceiver) }
    }

    private companion object {
        // AudioManager.AUDIOFOCUS_REQUEST_DELAYED is API 26; minSdk here is 24,
        // and the constant is only ever compared against a result that the
        // API 26 branch produced.
        const val AUDIOFOCUS_REQUEST_DELAYED = 2
    }

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            action()
        } else {
            mainHandler.post(action)
        }
    }
}
