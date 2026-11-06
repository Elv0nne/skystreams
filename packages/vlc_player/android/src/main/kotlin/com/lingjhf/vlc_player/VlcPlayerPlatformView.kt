package com.lingjhf.vlc_player

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.PixelCopy
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream
import java.lang.reflect.Field
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.MediaPlayer.ScaleType
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.interfaces.IVLCVout
import org.videolan.libvlc.util.VLCVideoLayout

/**
 * One libVLC player and everything that hangs off it.
 *
 * Implements [PlatformView] for the [VlcRenderTarget.VideoLayout] target; a
 * [VlcRenderTarget.Texture] player is never registered as a platform view and
 * the engine never asks it for one. The name predates the texture target and
 * is kept so the Darwin plugins and this one read the same.
 */
internal class VlcPlayerPlatformView(
    private val context: Context,
    messenger: BinaryMessenger,
    viewIdentifier: Long,
    options: ArrayList<String>,
    fit: String,
    private val target: VlcRenderTarget,
    private val onDispose: (Long, VlcPlayerPlatformView) -> Unit,
) : PlatformView {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val videoLayouts = target as? VlcRenderTarget.VideoLayout

    /// The layout the current player draws into. Every player gets its own
    /// (FORK.md 29); [surfaces] decides which is on show.
    private var videoLayout: VLCVideoLayout? = videoLayouts?.newLayout()

    /// Which layout is on show, and when a replaced player's layout can go.
    private val surfaces = VlcSurfaceHandover<MediaPlayer, VLCVideoLayout>()

    /// The player whose first time report has asked for its layout to show.
    private var pictureAskedFor: MediaPlayer? = null

    /// Each player's view surfaces that its views let go of, kept until the
    /// player has stopped (FORK.md 29).
    private val surfaceKeepers = HashMap<MediaPlayer, VlcSurfaceKeeper<SurfaceTexture>>()

    /// A test hook: see [VlcReleaseDelay].
    private val releaseDelay = VlcReleaseDelay.from(options)
    private val libVLC = LibVLC(context, releaseDelay.libVlcOptions)

    /// The libVLC player currently playing for this view.
    ///
    /// Not fixed for the life of the view: a new source gets a fresh one, and
    /// the one it replaces is released off the main thread - see
    /// [replacePlayer] for why that is the only safe way to leave a stream.
    private var mediaPlayer = MediaPlayer(libVLC)

    /// What [setSource] last loaded, so [stop] can leave it loaded on the
    /// player that replaces the stopped one, as libVLC's own stop does.
    private var lastSource: Source? = null
    private var videoScale = scaleTypeFor(fit)

    /// The crop and aspect ratio the widget's fit needs; see
    /// [setVideoGeometry]. Kept here because every new source gets a fresh
    /// player, which has to be told again.
    private var cropGeometry: String? = null
    private var aspectRatio: String? = null
    private val eventChannel = EventChannel(messenger, "vlc_player/events/$viewIdentifier")
    private val streamHandler = StreamHandler()
    private val viewId = viewIdentifier
    private val attachStateListener = object : View.OnAttachStateChangeListener {
        override fun onViewAttachedToWindow(view: View) {
            scheduleAttachViews()
        }

        override fun onViewDetachedFromWindow(view: View) {
            releaseViews()
        }
    }
    private val layoutChangeListener = object : View.OnLayoutChangeListener {
        override fun onLayoutChange(
            view: View,
            left: Int,
            top: Int,
            right: Int,
            bottom: Int,
            oldLeft: Int,
            oldTop: Int,
            oldRight: Int,
            oldBottom: Int,
        ) {
            if (
                left != oldLeft ||
                top != oldTop ||
                right != oldRight ||
                bottom != oldBottom
            ) {
                scheduleAttachViews()
                // A raise is a share of the picture, which the view's size
                // can resize on screen.
                if (right - left != oldRight - oldLeft || bottom - top != oldBottom - oldTop) {
                    reapplySubtitleLook()
                }
            }
        }
    }
    private val surfaceCallback = object : TextureRegistry.SurfaceProducer.Callback {
        override fun onSurfaceAvailable() {
            // The engine has rebuilt the ImageReader behind the texture, so the
            // surface libVLC last drew into is gone for good; getSurface() now
            // hands out the replacement.
            attachViewsIfNeeded()
        }

        override fun onSurfaceCleanup() {
            // Synchronous on purpose: the engine closes the ImageReader the
            // moment this returns, and a decoder still queueing into it would
            // start failing dequeues.
            releaseViews()
        }
    }
    private val videoLayoutListener = IVLCVout.OnNewVideoLayoutListener {
        vout, width, height, visibleWidth, visibleHeight, _, _ ->
        // A replaced player's last word on its layout is not this picture.
        if (vout !== mediaPlayer.vlcVout) return@OnNewVideoLayoutListener
        onNewVideoLayout(
            if (visibleWidth > 0) visibleWidth else width,
            if (visibleHeight > 0) visibleHeight else height,
        )
    }

    /// Shared by every player this view has had, so each callback checks it is
    /// about the current one: a replaced player tearing down off the main
    /// thread still reports its surfaces going, and acting on that would
    /// detach the views the new player has just been given.
    private val voutCallback = object : IVLCVout.Callback {
        override fun onSurfacesCreated(vlcVout: IVLCVout) {
            if (disposed || vlcVout !== mediaPlayer.vlcVout) {
                return
            }
            viewsAttached = true
            surfacesReady = true
            surfaceWait.surfaceReady()
            mediaPlayer.setVideoScale(videoScale)
            sendSnapshot()
        }

        override fun onSurfacesDestroyed(vlcVout: IVLCVout) {
            if (vlcVout !== mediaPlayer.vlcVout) {
                return
            }
            surfacesReady = false
            viewsAttached = false
            if (disposed || detachingViews) {
                return
            }
            mainHandler.post {
                if (!disposed && vlcVout === mediaPlayer.vlcVout) {
                    releaseViews()
                    scheduleAttachViews()
                }
            }
        }
    }

    private val audioFocusListener = object : VlcAudioFocusManager.Listener {
        override fun onAudioFocusPause(transient: Boolean) {
            interruptPlayback(
                if (transient) INTERRUPTION_FOCUS_LOST_TRANSIENT else INTERRUPTION_FOCUS_LOST,
            )
        }

        override fun onAudioFocusDuck() {
            if (disposed || !mediaPlayer.isPlaying) {
                return
            }
            // Ducking beats pausing for a navigation prompt: the film keeps
            // running and the prompt is audible over it. The viewer's own
            // volume is left alone and the attenuation applied underneath, so
            // a volume slider does not jump while the prompt speaks.
            duckFactor = DUCK_FACTOR
            applyVolume()
            interruption = INTERRUPTION_DUCKED
            sendSnapshot()
        }

        override fun onAudioFocusGain() {
            if (disposed || interruption == INTERRUPTION_NONE) {
                return
            }
            restoreDuckedVolume()
            interruption = INTERRUPTION_NONE
            // Reported, not acted on. Whether playback should resume depends on
            // the app lifecycle and the background policy, and both of those
            // live in Dart; resuming from here would start a film in an app
            // the viewer walked away from ten minutes ago.
            sendSnapshot()
        }

        override fun onBecomingNoisy() {
            interruptPlayback(INTERRUPTION_BECAME_NOISY)
        }
    }
    private val audioFocus = VlcAudioFocusManager(context, audioFocusListener)

    private var state = STATE_IDLE
    private var volume = 100
    private var duckFactor = 1.0f
    private var interruption = INTERRUPTION_NONE
    private var playbackSpeed = 1.0f

    /// The subtitle look the host last asked for, carried to each new player
    /// as the speed and volume are. Null until it asks.
    private var subtitleLook: VlcNativeSubtitles.Look? = null
    private var bufferingProgress: Double? = null
    private var errorCode: String? = null
    private var errorDescription: String? = null
    private var lastSentEvent: Map<String, Any?>? = null
    /// Bumped on every audio or subtitle ESAdded / ESDeleted so a consumer
    /// caching the track lists knows to refetch. Monotonic for the life of
    /// this player.
    private var trackRevision = 0
    private var viewsAttached = false
    private var detachingViews = false
    private var attachViewsPosted = false
    private var disposed = false

    /// The decision a keepPicture reopen's hold follows; see [VlcPictureHold].
    private val pictureHold = VlcPictureHold()

    /// The copy of the last frame laid over the video, from a hold until its
    /// view is gone, a moment after the hold ends: see [VlcHeldOverlay].
    private val heldPicture = VlcHeldOverlay<ImageView>(
        scheduler = object : VlcHeldOverlay.Scheduler {
            override fun postDelayed(delayMs: Long, task: Runnable) {
                mainHandler.postDelayed(task, delayMs)
            }

            override fun cancel(task: Runnable) {
                mainHandler.removeCallbacks(task)
            }
        },
        remove = { overlay -> (overlay.parent as? ViewGroup)?.removeView(overlay) },
    )

    /// Whether the current player's views have their surfaces: libvlc-android
    /// starts playback only then. See [VlcSurfaceWait].
    private var surfacesReady = false
    private val surfaceWait = VlcSurfaceWait { SystemClock.elapsedRealtime() }

    /// Plays wait here while the plugin builds libVLC's font database; see
    /// [VlcFontWarmup.gate]. A play starting or ending its wait sends a
    /// snapshot, whose `startGated` says so.
    private val playRequests = VlcPlayRequests(VlcFontWarmup.gate) { sendSnapshot() }

    /// The surface libVLC is drawing into on the texture target, and so the
    /// one a snapshot copies from. Null whenever the vout is detached.
    private var attachedSurface: Surface? = null
    private var videoLayoutWidth = 0
    private var videoLayoutHeight = 0

    init {
        when (target) {
            is VlcRenderTarget.VideoLayout -> {
                target.container.addOnAttachStateChangeListener(attachStateListener)
                target.container.addOnLayoutChangeListener(layoutChangeListener)
                surfaces.start(mediaPlayer, videoLayout!!)
            }
            is VlcRenderTarget.Texture -> target.producer.setCallback(surfaceCallback)
        }
        connect(mediaPlayer)
        // The view target waits for its layout to reach a window; the texture's
        // surface exists now, and Dart's setSource follows create on the very
        // next message, so the vout has to be in place before that lands.
        if (target is VlcRenderTarget.Texture) {
            attachViewsIfNeeded()
        } else {
            scheduleAttachViews()
        }
        eventChannel.setStreamHandler(streamHandler)
    }

    override fun getView(): View? = videoLayouts?.container

    fun setSource(
        uri: String,
        httpHeaders: Map<String, String>,
        mediaOptions: List<String>,
        startPosition: Long,
        keepPicture: Boolean,
        autoPlay: Boolean,
        result: MethodChannel.Result,
    ) {
        if (!ensureActive(result)) {
            return
        }

        try {
            // Before the swap, while the view still shows the old frame.
            val keep = keepPicture && target is VlcRenderTarget.VideoLayout
            when (pictureHold.arm(keep, hasPicture = keep && holdPicture())) {
                VlcPictureHold.Change.RELEASE -> releaseHeldPicture()
                VlcPictureHold.Change.NONE -> if (!pictureHold.held) releaseHeldPicture()
                VlcPictureHold.Change.HOLD -> Unit
            }
            // A player that has had a source gets replaced rather than handed
            // the next one - see replacePlayer.
            if (lastSource != null) {
                replacePlayer()
            }
            // HTTP headers are translated to libVLC options in Dart
            // (vlc_http_headers.dart). libVLC 3.x can transmit only
            // User-Agent and Referer; there is no `http-header` option, and
            // emitting one here silently dropped every header.
            val source = Source(uri, mediaOptions, startPosition)
            load(source)
            lastSource = source
            errorCode = null
            errorDescription = null
            lastSentEvent = null
            clearInterruption()
            updateState(STATE_OPENING)
            if (autoPlay && requestAudioFocusToPlay()) {
                val player = mediaPlayer
                playRequests.request {
                    if (disposed || player !== mediaPlayer) return@request
                    surfaceWait.playAsked(
                        surfaceReady = surfacesReady || target !is VlcRenderTarget.VideoLayout,
                    )
                    player.play()
                }
            }
            result.success(null)
        } catch (error: RuntimeException) {
            errorCode = ERROR_SET_SOURCE_FAILED
            errorDescription = error.message
            updateState(STATE_ERROR)
            result.error(ERROR_SET_SOURCE_FAILED, error.message, null)
        }
    }

    /// Sets [source] as the current player's media.
    private fun load(source: Source) {
        val media = Media(libVLC, Uri.parse(source.uri))
        source.mediaOptions.forEach { option ->
            media.addOption(option)
        }
        if (source.startPosition > 0L) {
            media.addOption(":start-time=${source.startPosition / 1000.0}")
        }
        mediaPlayer.media = media
        media.release()
    }

    /// Wires [player]'s events and surface callbacks to this view.
    private fun connect(player: MediaPlayer) {
        player.setEventListener(PlayerEvents(player))
        player.vlcVout.addCallback(voutCallback)
    }

    /// Puts a fresh libVLC player in place of the current one and releases the
    /// old one off the main thread.
    ///
    /// libVLC 3 leaves a stream synchronously: `set_media` and `stop` both
    /// stop the input thread and wait for it to exit, holding the player's
    /// input lock the whole time, and every read of the player - time,
    /// length, tracks - takes that lock too. A live stream whose segment read
    /// has stalled keeps the input thread alive for as long as the read
    /// lasts; SkyStream caught its main thread 15 s deep in
    /// `libvlc_media_player_stop` -> `input_Close` -> `vlc_join`. The main
    /// thread is also Flutter's UI thread, so the app froze and Android killed
    /// it as not responding, on switching source or on pressing back.
    ///
    /// A fresh player has no input to wait for and shares no lock with the
    /// old one, so the next source starts at once, whatever the old one is
    /// stuck in. The settings the host made on the player, which libVLC
    /// keeps per player and not per media, are carried across.
    private fun replacePlayer() {
        surfacesReady = false
        surfaceWait.reset()
        val retired = mediaPlayer
        retired.setEventListener(null)
        retired.vlcVout.removeCallback(voutCallback)
        if (target is VlcRenderTarget.Texture) {
            // One Flutter surface for every player: detached here, on the main
            // thread and before anything else touches it.
            releaseViews()
        } else {
            // Its views stay until its stop has returned: its output draws into
            // a layout of its own, which nothing else uses, and keeps a live
            // surface for as long as it holds one (FORK.md 29). Its video track
            // goes now, and its decoder with it; its last picture stays.
            retired.setVideoTrack(-1)
            // Held at its size: libvlc-android's layout listener on its views
            // answers a resize of the container - a rotation, picture-in-
            // picture - by calling into libVLC on this thread when the player
            // has no picture size yet, behind the input lock its stop holds
            // while it joins a read that hangs (FORK.md 29).
            videoLayout?.let(::pinSize)
            viewsAttached = false
        }

        mediaPlayer = MediaPlayer(libVLC)
        videoLayouts?.let { layouts ->
            val layout = layouts.newLayout()
            videoLayout = layout
            surfaces.replace(retired, mediaPlayer, layout)
        }
        connect(mediaPlayer)
        mediaPlayer.rate = playbackSpeed
        applyVolume()
        applyVideoGeometry(mediaPlayer)
        applySubtitleLook()
        attachViewsIfNeeded()

        // Before the stop holds the input lock (VlcSurfaceKeeper.tellsLibVlc).
        surfaceKeepers[retired]?.playerStopping()
        releaser.execute {
            releaseDelay.beforeStop()
            retired.stop()
            mainHandler.post {
                // Its output has let go of its layout: the views go now, on
                // the main thread as libvlc-android wants.
                retired.detachViews()
                retired.vlcVout.detachViews()
                surfaceKeepers.remove(retired)?.playerStopped()
                releaser.execute {
                    retired.release()
                    mainHandler.post { applySurfaces(surfaces.released(retired)) }
                }
            }
        }
    }

    /// Holds [layout] at the size it has, so its frame keeps its bounds through
    /// any resize of the container and libvlc-android's layout listener on it
    /// has nothing to answer (it acts only on bounds that moved).
    private fun pinSize(layout: VLCVideoLayout) {
        val width = layout.width
        val height = layout.height
        if (width <= 0 || height <= 0) return
        layout.layoutParams = FrameLayout.LayoutParams(width, height)
    }

    /// Watches [layout]'s TextureView for [player]'s first picture, and keeps
    /// its surface past the view for as long as [player] may draw into it, in
    /// front of libvlc-android's own listener, which it hands every call on to.
    private fun watchFirstPicture(player: MediaPlayer, layout: VLCVideoLayout) {
        val texture = layout.findViewById<TextureView>(org.videolan.R.id.texture_video) ?: return
        val libVlcListener = texture.surfaceTextureListener ?: return
        if (libVlcListener is FirstPictureWatch) return
        val keeper = surfaceKeepers.getOrPut(player) { VlcSurfaceKeeper { it.release() } }
        texture.surfaceTextureListener = FirstPictureWatch(libVlcListener, keeper) { watch ->
            // Called while the view draws: looked at once that is over.
            mainHandler.post { checkFirstPicture(player, texture, watch) }
        }
    }

    /// Brings [player]'s layout to the front at its first frame that is a
    /// picture: an output's first frame can be its black clear (FORK.md 29).
    private fun checkFirstPicture(player: MediaPlayer, texture: TextureView, watch: FirstPictureWatch) {
        if (disposed || player !== mediaPlayer || surfaces.onShow === videoLayout) {
            watch.watching = false
            return
        }
        if (!texture.isAvailable) return
        // A small copy of the frame, made on this thread: 2-112 ms on the phone
        // emulator, up to 0.24 s on the 4K TV one. So only the first few frames
        // are looked at; a dark opening comes forward at its time report.
        if (watch.checks >= FIRST_PICTURE_CHECKS) {
            watch.watching = false
            return
        }
        watch.checks += 1
        val copy = texture.getBitmap(8, 8) ?: return
        val pixels = IntArray(64)
        copy.getPixels(pixels, 0, 8, 0, 0, 8, 8)
        copy.recycle()
        if (VlcSurfaceHandover.isPicture(pixels)) {
            watch.watching = false
            applySurfaces(surfaces.pictureUp(player))
        }
    }

    /// libvlc-android's TextureView listener, with the frames looked at until
    /// the picture is up, and the surface kept when the view goes.
    private class FirstPictureWatch(
        private val libVlc: TextureView.SurfaceTextureListener,
        private val keeper: VlcSurfaceKeeper<SurfaceTexture>,
        private val onFrame: (FirstPictureWatch) -> Unit,
    ) : TextureView.SurfaceTextureListener by libVlc {
        var watching = true
        var checks = 0

        override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {
            libVlc.onSurfaceTextureUpdated(surface)
            if (watching) onFrame(this)
        }

        override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
            // libvlc-android lets go of its surfaces and asks for the video
            // track to go, but an output can draw on until its player stops.
            // Not while it stops: see VlcSurfaceKeeper.tellsLibVlc.
            if (keeper.tellsLibVlc) libVlc.onSurfaceTextureDestroyed(surface)
            return keeper.viewLetGo(surface)
        }
    }

    /// Brings [player]'s layout to the front a moment after its first time
    /// report, as the held copy goes, if no frame has done so: one too dark to
    /// tell from a black clear, say.
    private fun showPictureOf(player: MediaPlayer) {
        if (pictureAskedFor === player) return
        pictureAskedFor = player
        mainHandler.postDelayed(
            { applySurfaces(surfaces.pictureUp(player)) },
            HELD_PICTURE_RELEASE_DELAY_MS,
        )
    }

    /// Applies the handover's decisions to the container. Never from inside a
    /// draw - a TextureView callback, say: a child removed while the container
    /// draws crashes its dispatchDraw.
    private fun applySurfaces(changes: List<VlcSurfaceHandover.Change<VLCVideoLayout>>) {
        val container = videoLayouts?.container ?: return
        for (change in changes) {
            when (change) {
                is VlcSurfaceHandover.Change.Show -> container.bringChildToFront(change.surface)
                is VlcSurfaceHandover.Change.Remove -> container.removeView(change.surface)
            }
        }
    }

    /// Routes one player's events to this view, and drops them once that
    /// player has been replaced.
    ///
    /// libVLC hands events over as runnables that captured the listener, so a
    /// replaced player's last events - the Stopped of its own teardown above
    /// all - can still arrive afterwards, and would read as the new source
    /// stopping.
    private inner class PlayerEvents(
        private val player: MediaPlayer,
    ) : MediaPlayer.EventListener {
        override fun onEvent(event: MediaPlayer.Event) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                dispatch(event)
            } else {
                mainHandler.post { dispatch(event) }
            }
        }

        private fun dispatch(event: MediaPlayer.Event) {
            if (player === mediaPlayer) {
                handlePlayerEvent(event)
            }
        }
    }

    /// A source as [setSource] was given it, kept so [stop] can reload it.
    private data class Source(
        val uri: String,
        val mediaOptions: List<String>,
        val startPosition: Long,
    )

    private fun isValidHeader(name: String, value: String): Boolean {
        return name.isNotBlank() &&
            !name.contains('\r') &&
            !name.contains('\n') &&
            !value.contains('\r') &&
            !value.contains('\n')
    }

    fun play(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        clearInterruption()
        if (requestAudioFocusToPlay()) {
            val player = mediaPlayer
            playRequests.request {
                if (!disposed && player === mediaPlayer) player.play()
            }
        }
        result.success(null)
    }

    fun pause(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        // Focus is kept over a pause on purpose. A viewer who pauses for a
        // moment expects the next press of play to be instant, and handing
        // audio back only to snatch it again interrupts whatever took it.
        clearInterruption()
        playRequests.cancel()
        mediaPlayer.pause()
        result.success(null)
    }

    fun stop(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        audioFocus.abandon()
        clearInterruption()
        playRequests.cancel()
        applyHold(pictureHold.release())
        // Not mediaPlayer.stop(), which waits on the stream on this thread -
        // see replacePlayer. The source stays loaded on the fresh player, so a
        // play() after stop() starts it again, as it does on libVLC's own stop.
        replacePlayer()
        lastSource?.let(::load)
        updateState(STATE_STOPPED)
        result.success(null)
    }

    fun seekTo(milliseconds: Long, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        mediaPlayer.time = milliseconds.coerceAtLeast(0L)
        sendSnapshot()
        result.success(null)
    }

    /** A place in a live HLS or DASH window, as libVLC's position fraction. */
    fun seekToFraction(fraction: Float, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        mediaPlayer.position = fraction
        sendSnapshot()
        result.success(null)
    }

    fun setVolume(volume: Int, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        this.volume = volume.coerceIn(0, 200)
        applyVolume()
        sendSnapshot()
        result.success(null)
    }

    fun setPlaybackSpeed(speed: Float, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        if (!speed.isFinite() || speed <= 0.0f) {
            result.error("invalid_args", "A finite positive playback speed is required.", null)
            return
        }
        playbackSpeed = speed
        mediaPlayer.rate = playbackSpeed
        sendSnapshot()
        result.success(null)
    }

    fun setAudioDelay(microseconds: Long, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        if (!mediaPlayer.setAudioDelay(microseconds)) {
            result.error("vlc_error", "VLC failed to set audio delay.", null)
            return
        }
        sendSnapshot()
        result.success(null)
    }

    /// Restyles the subtitle lines libVLC draws, from their next line; answers
    /// whether it could. Kept, so the next player takes it too.
    fun setSubtitleLook(look: VlcNativeSubtitles.Look, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        subtitleLook = look
        result.success(applySubtitleLook())
    }

    /// Applies the kept look to the current player, its raise worked out for
    /// the picture as it is now - see VlcSubtitleMargin.
    private fun applySubtitleLook(): Boolean {
        val look = subtitleLook ?: return false
        val margin = if (look.raise > 0.0) {
            // libvlc-android keeps the track list it first read, and an
            // adaptive stream's rendition change resizes the picture without a
            // word to it: read the picture afresh.
            dropCachedTracks()
            val track = sizedVideoTrack()
            val (viewWidth, viewHeight) = when (target) {
                is VlcRenderTarget.VideoLayout -> target.container.width to target.container.height
                is VlcRenderTarget.Texture -> videoLayoutWidth to videoLayoutHeight
            }
            VlcSubtitleMargin.pixels(
                raise = look.raise,
                videoWidth = track?.width ?: 0,
                videoHeight = track?.height ?: 0,
                sarNum = track?.sarNum ?: 1,
                sarDen = track?.sarDen ?: 1,
                crop = cropGeometry,
                viewWidth = viewWidth,
                viewHeight = viewHeight,
                stretched = aspectRatio != null,
                drawnOnDisplay = VlcNativeSubtitles.drawnOnDisplay(mediaPlayer),
            )
        } else {
            0
        }
        return VlcNativeSubtitles.apply(mediaPlayer, look, margin)
    }

    /// Works the kept raise out again, for what changed the picture's size on
    /// screen or what libVLC lays the lines out on.
    private fun reapplySubtitleLook() {
        if (disposed || (subtitleLook?.raise ?: 0.0) <= 0.0) {
            return
        }
        applySubtitleLook()
    }

    fun setSubtitleDelay(microseconds: Long, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        if (!mediaPlayer.setSpuDelay(microseconds)) {
            result.error("vlc_error", "VLC failed to set subtitle delay.", null)
            return
        }
        sendSnapshot()
        result.success(null)
    }

    fun takeSnapshot(width: Int, height: Int, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        when (target) {
            is VlcRenderTarget.VideoLayout -> snapshotWindow(videoLayout!!, width, height, result)
            is VlcRenderTarget.Texture -> snapshotSurface(width, height, result)
        }
    }

    private fun snapshotWindow(
        videoLayout: VLCVideoLayout,
        width: Int,
        height: Int,
        result: MethodChannel.Result,
    ) {
        val activity = activityFrom(context)
        if (activity == null) {
            result.error("snapshot_failed", "Unable to locate the Android activity window.", null)
            return
        }
        if (videoLayout.width <= 0 || videoLayout.height <= 0) {
            result.error("snapshot_failed", "The video view has no rendered size.", null)
            return
        }

        val location = IntArray(2)
        videoLayout.getLocationInWindow(location)
        val sourceRect = Rect(
            location[0],
            location[1],
            location[0] + videoLayout.width,
            location[1] + videoLayout.height,
        )
        val snapshotWidth = if (width > 0) width else videoLayout.width
        val snapshotHeight = if (height > 0) height else videoLayout.height
        val bitmap = Bitmap.createBitmap(snapshotWidth, snapshotHeight, Bitmap.Config.ARGB_8888)

        PixelCopy.request(activity.window, sourceRect, bitmap, { copyResult ->
            deliverSnapshot(copyResult, bitmap, result)
        }, mainHandler)
    }

    /// Copies the last buffer libVLC queued to the texture's surface.
    ///
    /// There is no window region to copy on this target: the frame belongs to
    /// Flutter's compositor, not to a View. Reading the surface's last queued
    /// buffer also means the copy is the decoder's output as libVLC left it -
    /// the widget's fit is not applied and nothing drawn over the video is in
    /// it, which is the better snapshot anyway.
    private fun snapshotSurface(width: Int, height: Int, result: MethodChannel.Result) {
        val surface = attachedSurface
        val track = mediaPlayer.currentVideoTrack
        if (surface == null || !surface.isValid || track == null || track.width <= 0 || track.height <= 0) {
            result.error("snapshot_failed", "The video has no rendered frame.", null)
            return
        }
        val snapshotWidth = if (width > 0) width else track.width
        val snapshotHeight = if (height > 0) height else track.height
        val bitmap = Bitmap.createBitmap(snapshotWidth, snapshotHeight, Bitmap.Config.ARGB_8888)

        PixelCopy.request(surface, bitmap, { copyResult ->
            deliverSnapshot(copyResult, bitmap, result)
        }, mainHandler)
    }

    private fun deliverSnapshot(copyResult: Int, bitmap: Bitmap, result: MethodChannel.Result) {
        if (copyResult != PixelCopy.SUCCESS) {
            bitmap.recycle()
            result.error("snapshot_failed", "Android PixelCopy failed with code $copyResult.", null)
            return
        }
        val output = ByteArrayOutputStream()
        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
            bitmap.recycle()
            result.error("snapshot_failed", "Android failed to encode the snapshot PNG.", null)
            return
        }
        bitmap.recycle()
        result.success(output.toByteArray())
    }

    fun getAudioTracks(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        result.success(trackDescriptions(mediaPlayer.audioTracks))
    }

    fun setAudioTrack(id: Int, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        if (!mediaPlayer.setAudioTrack(id)) {
            result.error("track_not_found", "Audio track $id was not found.", null)
            return
        }
        // ESSelected will follow, but the caller is waiting on this value now.
        sendSnapshot(force = true)
        result.success(null)
    }

    fun getSubtitleTracks(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        result.success(trackDescriptions(mediaPlayer.spuTracks))
    }

    fun setSubtitleTrack(id: Int, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        if (!mediaPlayer.setSpuTrack(id)) {
            result.error("track_not_found", "Subtitle track $id was not found.", null)
            return
        }
        sendSnapshot(force = true)
        result.success(null)
    }

    fun disableSubtitle(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        mediaPlayer.setSpuTrack(-1)
        sendSnapshot(force = true)
        result.success(null)
    }

    fun addSubtitle(uri: String, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        if (!mediaPlayer.addSlave(IMedia.Slave.Type.Subtitle, Uri.parse(uri), true)) {
            result.error("add_subtitle_failed", "Failed to add subtitle: $uri", null)
            return
        }
        // Unlike setAudioTrack / setSpuTrack above, this one cannot report its
        // own result: libVLC 3 posts an added slave to the input thread, so
        // addSlave returning true only means it was accepted and this snapshot
        // still carries the pre-add spuTracks. It is forced to keep the rest of
        // the payload fresh, not to announce the subtitle. The text-stream
        // MediaPlayer.Event.ESAdded is what bumps trackRevision once the track
        // really exists, and that revision - not this result - is the signal a
        // caller has to wait on.
        sendSnapshot(force = true)
        result.success(null)
    }

    fun getMediaInfo(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }

        result.success(mediaInfoOf(mediaPlayer))
    }

    fun getMediaStats(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }

        result.success(mediaStatsOf(mediaPlayer))
    }

    override fun onFlutterViewAttached(flutterView: View) {
        if (!disposed) {
            scheduleAttachViews()
        }
    }

    override fun onFlutterViewDetached() {
        detachViewsIfNeeded()
    }

    override fun dispose() {
        if (disposed) {
            return
        }
        disposed = true
        playRequests.cancel()
        pictureHold.release()
        releaseHeldPicture(now = true)
        audioFocus.dispose()
        eventChannel.setStreamHandler(null)
        mediaPlayer.setEventListener(null)
        when (target) {
            is VlcRenderTarget.VideoLayout -> {
                target.container.removeOnAttachStateChangeListener(attachStateListener)
                target.container.removeOnLayoutChangeListener(layoutChangeListener)
            }
            is VlcRenderTarget.Texture -> target.producer.setCallback(null)
        }
        mediaPlayer.vlcVout.removeCallback(voutCallback)
        when (target) {
            // Flutter has already taken the view away, and with it every
            // layout's surface: libvlc-android's own listener has told each
            // player still drawing (FORK.md 29). Their views go once each has
            // stopped, below.
            is VlcRenderTarget.VideoLayout -> surfaces.dispose()
            // Detached here, on the main thread, where the views live.
            is VlcRenderTarget.Texture -> releaseViews()
        }
        onDispose(viewId, this)

        // Everything that waits on libVLC's threads happens off the main
        // thread - see replacePlayer. stop() on a stalled live stream held it
        // for as long as the download hung, and pressing back got the app
        // killed as not responding.
        //
        // The order is the one this always had. The producer sits between the
        // vout and the player: releasing it closes the ImageReader behind the
        // surface, so the player has to have stopped drawing into it first,
        // and the player, with nowhere left to draw, goes before the instance.
        val player = mediaPlayer
        val producer = (target as? VlcRenderTarget.Texture)?.producer
        // Before the stop holds the input lock (VlcSurfaceKeeper.tellsLibVlc).
        surfaceKeepers[player]?.playerStopping()
        releaser.execute {
            releaseDelay.beforeStop()
            player.stop()
            mainHandler.post {
                // Its output has let go: its views go, on the main thread.
                player.detachViews()
                player.vlcVout.detachViews()
                surfaceKeepers.remove(player)?.playerStopped()
                // Texture registry calls belong on the platform thread.
                producer?.release()
                releaser.execute {
                    player.release()
                    libVLC.release()
                }
            }
        }
    }

    /// Lays a copy of the frame on screen over the video, which libVLC draws
    /// into directly. False, holding nothing, when there is no frame to copy.
    private fun holdPicture(): Boolean {
        // A copy still over the video - held, or let go less than its delay
        // ago - is the one to keep: the view under it may already show the
        // newer media's picture at 0. Its removal, if one was coming, is off.
        if (heldPicture.reuse() != null) return true
        // The picture on show: the newest layout that has had one.
        val layout = surfaces.onShow ?: return false
        val container = videoLayouts?.container ?: return false
        val texture =
            layout.findViewById<TextureView>(org.videolan.R.id.texture_video) ?: return false
        if (!texture.isAvailable || texture.width == 0 || texture.height == 0) return false
        // At most 1920 wide: the copy shows for seconds, and a 4K one is 33 MB.
        val scale = minOf(1f, 1920f / texture.width)
        val bitmap = texture.getBitmap(
            (texture.width * scale).toInt(),
            (texture.height * scale).toInt(),
        ) ?: return false
        // The texture is centred in its layout, which fills the container:
        // its own parameters place the copy over it there.
        val params = (texture.layoutParams as? FrameLayout.LayoutParams)
            ?.let { FrameLayout.LayoutParams(it) }
            ?: FrameLayout.LayoutParams(texture.layoutParams)
        val overlay = ImageView(context).apply {
            setImageBitmap(bitmap)
            scaleType = ImageView.ScaleType.FIT_XY
            // Over every layout, whichever is brought to the front.
            translationZ = HELD_PICTURE_Z
        }
        container.addView(overlay, params)
        heldPicture.hold(overlay)
        return true
    }

    /// Takes the copy away once the new player's first frame at its start has
    /// had a moment to reach the view: libVLC's first time report can come a
    /// frame before it. [now] for a teardown, which takes a copy already let
    /// go as well. Whether a hold is on is [pictureHold]'s, so the snapshot
    /// this sends already says it ended.
    private fun releaseHeldPicture(now: Boolean = false) {
        if (now) {
            if (!heldPicture.isUp) return
            heldPicture.releaseNow()
        } else {
            // A copy already let go is on its way out, and was said to be.
            if (!heldPicture.isHeld) return
            heldPicture.release(HELD_PICTURE_RELEASE_DELAY_MS)
        }
        sendSnapshot()
    }

    private fun applyHold(change: VlcPictureHold.Change) {
        if (change == VlcPictureHold.Change.RELEASE) releaseHeldPicture()
    }

    private fun handlePlayerEvent(event: MediaPlayer.Event) {
        if (disposed) {
            return
        }

        when (event.type) {
            MediaPlayer.Event.Opening -> {
                bufferingProgress = null
                pictureHold.onOpening()
                updateState(STATE_OPENING)
            }
            MediaPlayer.Event.Buffering -> {
                val percent = event.getBuffering().coerceIn(0.0f, 100.0f)
                bufferingProgress = percent.toDouble() / 100.0
                // libVLC emits Buffering CONTINUOUSLY during healthy playback,
                // reaching 100 each time. Mapping every one to STATE_BUFFERING
                // overwrote STATE_PLAYING, so the player never reported that it
                // was playing: the spinner never cleared, the play/pause icon
                // was wrong, and every host feature gated on "playing" -
                // progress, scrobbling, completion, next episode - silently
                // stopped working. Only a partial buffer is a real stall.
                //
                // And only on a player that is actually running. A pause lands
                // while the demuxer is mid-fill, so a trailing Buffering below
                // 100 can arrive after Paused and would overwrite STATE_PAUSED
                // with a spinner over a frame the viewer asked to hold.
                if (mediaPlayer.isPlaying) {
                    updateState(if (percent < 100.0f) STATE_BUFFERING else STATE_PLAYING)
                } else {
                    // The first fill, before libVLC plays: Dart keeps the
                    // percentage while the media opens (spec 4).
                    sendSnapshot()
                }
            }
            MediaPlayer.Event.Playing -> {
                bufferingProgress = null
                updateState(STATE_PLAYING)
            }
            MediaPlayer.Event.Paused -> {
                bufferingProgress = null
                updateState(STATE_PAUSED)
            }
            MediaPlayer.Event.Stopped -> {
                bufferingProgress = null
                applyHold(pictureHold.onMediaGone())
                // Focus is deliberately not abandoned here. Replacing the media
                // on a running player emits Stopped, and this event arrives a
                // main-thread hop later - after setSource has already taken
                // focus for the next item, which this would then throw away.
                // The deliberate stop() abandons on its own.
                updateState(STATE_STOPPED)
            }
            MediaPlayer.Event.EndReached -> {
                bufferingProgress = null
                applyHold(pictureHold.onMediaGone())
                // Nothing left to play: hold audio no longer, so whatever was
                // ducked or paused behind us can come back on its own. A
                // playlist advancing takes it straight back.
                audioFocus.abandon()
                updateState(STATE_ENDED)
            }
            MediaPlayer.Event.EncounteredError -> {
                bufferingProgress = null
                applyHold(pictureHold.onMediaGone())
                errorCode = ERROR_PLAYBACK
                errorDescription = "VLC encountered an error while playing the media."
                updateState(STATE_ERROR)
            }
            MediaPlayer.Event.Vout -> {
                // A new video output: the picture's size, and whether its
                // display draws the lines itself, are known from here.
                reapplySubtitleLook()
                sendSnapshot()
            }
            MediaPlayer.Event.TimeChanged -> {
                applyHold(pictureHold.onTimeChanged())
                showPictureOf(mediaPlayer)
                sendSnapshot()
            }
            MediaPlayer.Event.PositionChanged -> {
                // libVLC sends a new time as PositionChanged, then TimeChanged
                // (lib/media_player.c, INPUT_EVENT_POSITION): the first is the
                // time report that ends a hold, so the snapshot of the first
                // move already says so, at the new picture's size (FORK.md 30).
                applyHold(pictureHold.onTimeChanged())
                sendSnapshot()
            }
            MediaPlayer.Event.LengthChanged,
            MediaPlayer.Event.SeekableChanged,
            MediaPlayer.Event.ESSelected,
            -> sendSnapshot()
            MediaPlayer.Event.ESAdded,
            MediaPlayer.Event.ESDeleted,
            -> {
                // Only the audio and subtitle lists are published, and libVLC
                // announces the video ES here too. A rendition change or an
                // MPEG-TS PMT update re-announces video on its own, and
                // bumping for that reloads a track list that did not change:
                // the panel blinks to a spinner and the D-pad cursor jumps
                // back to the active row from wherever the viewer had it.
                if (event.esChangedType == IMedia.Track.Type.Audio ||
                    event.esChangedType == IMedia.Track.Type.Text
                ) {
                    trackRevision += 1
                }
                sendSnapshot()
            }
        }
    }

    /// Claims audio focus, and says whether playback may start.
    ///
    /// A refusal is reported as an interruption rather than swallowed: it is
    /// why the play button appeared to do nothing, and it is what tells the
    /// Dart side to resume when the delayed grant lands after the call.
    private fun requestAudioFocusToPlay(): Boolean {
        if (audioFocus.request()) {
            return true
        }
        interruption = INTERRUPTION_FOCUS_LOST_TRANSIENT
        sendSnapshot()
        return false
    }

    /// Pauses for an interruption the viewer did not ask for.
    ///
    /// The pause happens here rather than after a round trip to Dart because
    /// audio focus has to be honoured in the instant it moves - a film that
    /// waits for an event channel talks over the first ring of a phone call.
    private fun interruptPlayback(reason: String) {
        if (disposed) {
            return
        }
        restoreDuckedVolume()
        if (mediaPlayer.isPlaying) {
            interruption = reason
            mediaPlayer.pause()
            updateState(STATE_PAUSED)
            return
        }
        if (interruption != INTERRUPTION_NONE) {
            // Already silent for an earlier interruption. A transient loss that
            // turned permanent is still worth saying, because it withdraws the
            // promise that anything is coming back.
            interruption = reason
            sendSnapshot()
            return
        }
        // Nothing was playing and nothing had interrupted it. Reporting one
        // would make a player the viewer paused themselves look system-paused,
        // and invite a resume they never asked for.
    }

    private fun applyVolume() {
        mediaPlayer.volume = (volume * duckFactor).toInt().coerceIn(0, 200)
    }

    private fun restoreDuckedVolume() {
        if (duckFactor == 1.0f) {
            return
        }
        duckFactor = 1.0f
        applyVolume()
    }

    /// Drops the system's claim, restoring whatever it changed.
    ///
    /// Called from the deliberate-intent entry points: once the viewer has
    /// pressed something, the interruption no longer explains what the player
    /// is doing.
    private fun clearInterruption() {
        restoreDuckedVolume()
        interruption = INTERRUPTION_NONE
    }

    private fun updateState(state: String) {
        this.state = state
        sendSnapshot()
    }

    /// Changes how video is scaled without recreating the player.
    ///
    /// setVideoScale is already a runtime call on MediaPlayer; only the Dart
    /// side forced a rebuild, by folding `fit` into the platform-view key.
    ///
    /// A texture-backed player is fitted in Dart, by the widget that owns the
    /// Texture. setVideoScale is a no-op without a VLCVideoLayout behind it, so
    /// nothing needs guarding here; the value is kept so a later attach of a
    /// view target would still honour it.
    fun setFit(fit: String, result: MethodChannel.Result) {
        if (disposed) {
            result.error("disposed", "This player has been disposed.", null)
            return
        }
        videoScale = scaleTypeFor(fit)
        mediaPlayer.setVideoScale(videoScale)
        result.success(null)
    }

    /// Has libVLC crop the picture to the view's shape (Zoom), give it the
    /// view's aspect ratio (Stretch), or neither (Fit), as the widget
    /// computed from its fit and size.
    ///
    /// Done in libVLC rather than by sizing the view, because libVLC draws the
    /// subtitles: a view larger than the screen took them off its bottom edge
    /// and enlarged them, and libvlc-android's view sizing never worked on
    /// hardware-decoded video at all - it needs a size report only the native
    /// display sends, while MediaCodec output is shown by the OpenGL one.
    fun setVideoGeometry(crop: String?, aspect: String?, result: MethodChannel.Result) {
        if (disposed) {
            result.error("disposed", "This player has been disposed.", null)
            return
        }
        cropGeometry = crop?.takeIf { it.isNotEmpty() }
        aspectRatio = aspect?.takeIf { it.isNotEmpty() }
        applyVideoGeometry(mediaPlayer)
        reapplySubtitleLook()
        result.success(null)
    }

    private fun applyVideoGeometry(player: MediaPlayer) {
        player.aspectRatio = aspectRatio
        VlcNativeGeometry.setCrop(player, cropGeometry)
    }

    private fun attachViewsIfNeeded() {
        if (disposed || viewsAttached) {
            return
        }
        when (target) {
            is VlcRenderTarget.VideoLayout -> {
                val layout = videoLayout ?: return
                if (!layout.isAttachedToWindow) {
                    return
                }
                releaseViews()
                mediaPlayer.attachViews(layout, null, false, true)
                mediaPlayer.setVideoScale(videoScale)
                watchFirstPicture(mediaPlayer, layout)
            }
            is VlcRenderTarget.Texture -> {
                val surface = target.producer.surface
                if (surface == null || !surface.isValid) {
                    return
                }
                releaseViews()
                val vout = mediaPlayer.vlcVout
                // Video only. There is no second surface for subtitles, so
                // libVLC blends them into the picture; see VlcRenderTarget.
                vout.setVideoSurface(surface, null)
                vout.attachViews(videoLayoutListener)
                attachedSurface = surface
                if (videoLayoutWidth > 0 && videoLayoutHeight > 0) {
                    vout.setWindowSize(videoLayoutWidth, videoLayoutHeight)
                }
            }
        }
        viewsAttached = true
    }

    /// libVLC has opened its display and knows the picture it will draw.
    ///
    /// The window is told it is exactly the visible picture, so libVLC places
    /// the video 1:1 and neither scales nor letterboxes inside the buffer -
    /// fit belongs to the widget. The producer is told the same size so the
    /// ImageReader the engine builds is the video's, not a placeholder.
    ///
    /// What deliberately does NOT happen here is a re-attach. On API 29+ the
    /// engine answers setSize by minting a new ImageReader on the next
    /// getSurface(), and swapping libVLC onto it would go through
    /// MediaPlayer's own surface callback, which disables and re-enables the
    /// video track - a decoder restart and a wait for the next keyframe, at
    /// the first frame of every stream. The buffers MediaCodec queues carry
    /// their own dimensions and crop, which the engine honours
    /// (handlesCropAndRotation), so the surface libVLC already holds keeps
    /// showing the right picture; the resized reader is picked up the next
    /// time the engine recycles the surface anyway.
    private fun onNewVideoLayout(width: Int, height: Int) {
        if (disposed || width <= 0 || height <= 0) {
            return
        }
        val producer = (target as? VlcRenderTarget.Texture)?.producer ?: return
        if (width == videoLayoutWidth && height == videoLayoutHeight) {
            return
        }
        videoLayoutWidth = width
        videoLayoutHeight = height
        producer.setSize(width, height)
        mediaPlayer.vlcVout.setWindowSize(width, height)
        sendSnapshot()
    }

    private fun scheduleAttachViews() {
        if (disposed || attachViewsPosted) {
            return
        }
        attachViewsPosted = true
        mainHandler.post {
            attachViewsPosted = false
            attachViewsIfNeeded()
        }
    }

    private fun detachViewsIfNeeded() {
        releaseViews()
    }

    private fun releaseViews() {
        detachingViews = true
        try {
            // MediaPlayer.detachViews() only releases the VLCVideoLayout helper;
            // a raw surface is let go on the vout itself. Each is a no-op for
            // the target that did not use it.
            mediaPlayer.detachViews()
            mediaPlayer.vlcVout.detachViews()
            attachedSurface = null
            viewsAttached = false
        } finally {
            detachingViews = false
        }
    }

    private fun ensureActive(result: MethodChannel.Result): Boolean {
        if (!disposed) {
            return true
        }
        result.error("disposed", "The vlc_player has been disposed.", null)
        return false
    }

    private fun trackDescriptions(
        tracks: Array<MediaPlayer.TrackDescription>?,
    ): List<Map<String, Any?>> {
        return tracks.orEmpty().map { track ->
            mapOf(
                "id" to track.id,
                "name" to track.name,
                "language" to null,
            )
        }
    }

    private fun sendSnapshot(force: Boolean = false) {
        if (disposed) {
            return
        }

        val duration = mediaPlayer.length.coerceAtLeast(0L)
        val isSeekable = mediaPlayer.isSeekable
        val event = HashMap<String, Any?>()
        event["state"] = state
        event["position"] = mediaPlayer.time.coerceAtLeast(0L)
        event["duration"] = duration
        event["positionFraction"] = mediaPlayer.position.toDouble()
        event["volume"] = volume
        event["playbackSpeed"] = playbackSpeed.toDouble()
        event["audioDelay"] = mediaPlayer.audioDelay
        event["subtitleDelay"] = mediaPlayer.spuDelay
        // -1 when there is none / subtitles are off; Dart normalises to null.
        event["audioTrack"] = mediaPlayer.audioTrack
        event["subtitleTrack"] = mediaPlayer.spuTrack
        event["trackRevision"] = trackRevision
        event["isReady"] = isReadyState(state)
        event["isSeekable"] = isSeekable
        event["isLive"] = isLiveState(state) && duration == 0L && !isSeekable
        event["interruption"] = interruption
        putVideoShape(event)
        // The decision, the same on every backend (FORK.md 30); the overlay
        // outlives a hold by its removal's delay.
        event["pictureHeld"] = pictureHold.held
        // A play waiting at the font start gate (FORK.md 26 and 33).
        event["startGated"] = playRequests.waiting
        surfaceWait.waitedMs?.let { event["videoSurfaceWaitMs"] = it }
        bufferingProgress?.let {
            event["bufferingProgress"] = it
        }
        errorDescription?.let {
            event["errorCode"] = errorCode ?: ERROR_PLAYBACK
            event["errorDescription"] = it
        }
        if (!force && event == lastSentEvent) {
            return
        }
        lastSentEvent = HashMap(event)
        streamHandler.send(event)
    }

    /**
     * Puts the video's stored size and its rotation into the snapshot.
     *
     * One function, and one read of `currentVideoTrack` once the track is
     * sized, because that property walks the media's track array every time it
     * is touched and this runs on every snapshot.
     *
     * `videoSize` stays the *stored* size - the elementary stream's own width
     * and height - because that is what this key means on every other platform
     * and what the layout code expects. The rotation goes beside it rather than
     * being folded into it. A clip shot in portrait on a handset is stored as
     * landscape frames plus a 90 degree matrix, so the two have to be combined
     * to get the shape a viewer sees, and Dart is where that happens: it is the
     * only side of this channel the project's CI runs tests on.
     *
     * Nothing is sent before the first video track exists and has a size.
     * `currentVideoTrack` is null while the player is still opening, which is
     * exactly when a shape would be a guess.
     */
    private fun putVideoShape(event: HashMap<String, Any?>) {
        val track = sizedVideoTrack() ?: return
        event["videoSize"] = mapOf("width" to track.width, "height" to track.height)
        event["videoOrientation"] = track.orientation
    }

    /**
     * The current video track, once libVLC knows its size.
     *
     * libvlc-android's `Media` caches its track array the first time anything
     * asks for it, and only a `ParsedChanged` event clears that copy - which
     * playback never raises. MP4 and MKV declare their size in the container,
     * so the first read is already right. MPEG-TS does not, and neither does
     * HLS, which is TS segments behind a playlist: the video track exists
     * before the decoder has parsed a frame, and a read taken then caches 0x0
     * for the life of the media, although libVLC's own track info fills in a
     * moment later. Every HLS and TS source - most anime and live channels -
     * reached Dart with no shape at all, so the host could not turn the device
     * to match it.
     *
     * So an unsized track drops the cached copy and asks again, on each
     * snapshot until libVLC has an answer. A sized track, or no video track at
     * all, costs nothing extra.
     */
    private fun sizedVideoTrack(): IMedia.VideoTrack? {
        val cached = mediaPlayer.currentVideoTrack ?: return null
        if (cached.width > 0 && cached.height > 0) {
            return cached
        }
        if (!dropCachedTracks()) {
            return null
        }
        return mediaPlayer.currentVideoTrack?.takeIf { it.width > 0 && it.height > 0 }
    }

    /**
     * Clears libvlc-android's cached track array, so the next read goes back
     * to libVLC. Returns whether it could.
     *
     * Reflection, because libvlc-android 3.x offers no public way to do this:
     * the field is private and the only code that clears it is
     * `Media.postParse`. Locked on the media exactly as `Media.getTracks`
     * locks, and guarded, so a libvlc build without the field falls back to
     * the old behaviour rather than failing the snapshot.
     */
    private fun dropCachedTracks(): Boolean {
        val field = nativeTracksField ?: return false
        // getMedia() retains the media, so every call is paired with a release.
        val media = mediaPlayer.media ?: return false
        return try {
            synchronized(media) { field.set(media, null) }
            true
        } catch (e: Exception) {
            false
        } finally {
            media.release()
        }
    }

    private inner class StreamHandler : EventChannel.StreamHandler {
        private var events: EventChannel.EventSink? = null

        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            this.events = events
            sendSnapshot(force = true)
        }

        override fun onCancel(arguments: Any?) {
            events = null
        }

        fun send(event: Map<String, Any?>) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                sendOnMainThread(event)
            } else {
                mainHandler.post { sendOnMainThread(event) }
            }
        }

        private fun sendOnMainThread(event: Map<String, Any?>) {
            if (!disposed) {
                events?.success(event)
            }
        }
    }

    private companion object {
        /// How long the copy laid over the video outlives the new player's
        /// first time report, so its first frame at the start is drawn first.
        const val HELD_PICTURE_RELEASE_DELAY_MS = 120L

        /// The held copy's elevation in the container: above every player's
        /// layout, whichever the handover brings to the front.
        const val HELD_PICTURE_Z = 1f

        /// How many of a new player's first frames are looked at for its first
        /// picture: the black clear, the picture, and one to spare.
        const val FIRST_PICTURE_CHECKS = 3

        /**
         * Where libVLC players are stopped and released: never the main
         * thread, see [replacePlayer]. A thread per job rather than a single
         * worker, so one teardown stuck behind a stalled read does not hold
         * up every one after it.
         */
        val releaser: ExecutorService = Executors.newCachedThreadPool { job ->
            Thread(job, "vlc-release").apply { isDaemon = true }
        }

        /**
         * `Media.mNativeTracks`, libvlc-android's cached track array, or null
         * where this libvlc build has no such field. See [dropCachedTracks].
         *
         * A minified host already has to keep `org.videolan.**` whole, because
         * libvlcjni resolves those classes by name, so R8 leaves this alone.
         */
        val nativeTracksField: Field? by lazy {
            try {
                Media::class.java.getDeclaredField("mNativeTracks").apply {
                    isAccessible = true
                }
            } catch (e: Exception) {
                null
            }
        }

        const val STATE_IDLE = "idle"
        const val STATE_OPENING = "opening"
        const val STATE_BUFFERING = "buffering"
        const val STATE_PLAYING = "playing"
        const val STATE_PAUSED = "paused"
        const val STATE_STOPPED = "stopped"
        const val STATE_ENDED = "ended"
        const val STATE_ERROR = "error"
        const val INTERRUPTION_NONE = "none"
        const val INTERRUPTION_FOCUS_LOST = "focusLost"
        const val INTERRUPTION_FOCUS_LOST_TRANSIENT = "focusLostTransient"
        const val INTERRUPTION_DUCKED = "ducked"
        const val INTERRUPTION_BECAME_NOISY = "becameNoisy"

        // Roughly the attenuation a system notification ducks other audio by.
        const val DUCK_FACTOR = 0.3f

        const val ERROR_PLAYBACK = "playback_error"
        const val ERROR_SET_SOURCE_FAILED = "set_source_failed"

        /// Always a plain fit: every fit reaches libVLC as a crop or an aspect
        /// ratio through [setVideoGeometry], so the picture the view is handed
        /// is already the shape to show. Scaling the view as well would apply
        /// the fit twice - and a view larger than the screen is what took the
        /// subtitles off its edge.
        @Suppress("UNUSED_PARAMETER")
        fun scaleTypeFor(fit: String): ScaleType = ScaleType.SURFACE_BEST_FIT

        fun activityFrom(context: Context): Activity? {
            var current = context
            while (current is ContextWrapper) {
                if (current is Activity) {
                    return current
                }
                current = current.baseContext
            }
            return null
        }

        fun isReadyState(state: String): Boolean {
            return state == STATE_PLAYING ||
                state == STATE_PAUSED ||
                state == STATE_STOPPED ||
                state == STATE_ENDED
        }

        fun isLiveState(state: String): Boolean {
            // STATE_BUFFERING is deliberately excluded. isLive is derived from
            // `duration == 0 && !isSeekable`, and both are trivially true while
            // VLC is still opening the stream — including buffering made every
            // VOD report isLive for the first frames.
            return state == STATE_PLAYING || state == STATE_PAUSED
        }
    }
}
