package dev.akash.skystream

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.net.Uri
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterEngineConfigurator
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.util.GeneratedPluginRegister
import io.flutter.plugin.common.MethodChannel
import android.app.ActivityManager
import android.app.PictureInPictureParams
import android.os.Build
import android.util.Rational
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import kotlin.math.roundToInt

/**
 * The app's only activity. CloudStream extensions cast their context to CloudStream's
 * `MainActivity`, an `AppCompatActivity`, so this is one, hosting Flutter in a
 * [FlutterFragment] the way `FlutterFragmentActivity` does rather than being a
 * `FlutterActivity`.
 */
class MainActivity : com.lagradost.cloudstream3.MainActivity(), FlutterEngineConfigurator {
    private var flutterFragment: FlutterFragment? = null

    private val flutterEngine: FlutterEngine?
        get() = flutterFragment?.flutterEngine

    private val CHANNEL = "dev.akash.skystream.player/pip"
    private val TV_CHANNEL = "dev.akash.skystream/tv_channel"
    private val PLAYER_CHANNEL = "dev.akash.skystream/external_player"
    private val TEXT_INPUT_CHANNEL = "dev.akash.skystream/text_input"
    private val MEMORY_CHANNEL = "dev.akash.skystream/device_memory"

    private var isPlaying = false

    /// The shape of the video currently playing, as the PiP window should be
    /// shaped. Null until Dart has decoded a frame and told us. Held as a
    /// field because `updatePipActions()` rebuilds the params from scratch on
    /// every play/pause flip, and a rebuild that dropped the aspect ratio
    /// would snap the window back to square in the middle of a film.
    private var pipAspectRatio: Rational? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // A FlutterActivity registers plugins itself; a fragment's host has to.
        GeneratedPluginRegister.registerGeneratedPlugins(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        
        // Whether a Flutter text field has focus, for the televisions that give
        // a keyboard a session only for a text editor - see TextEditorProxy.
        val textEditing = TextEditingReports(resources) { flutterViewIn(flutterFragment?.view) }
        MethodChannel(messenger, TEXT_INPUT_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "needed" -> result.success(textEditing.needed())
                "editing" -> {
                    textEditing.editing(call.arguments == true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // What the player sizes its read-ahead from (lib/core/providers/device_memory.dart).
        // lowRam is the OEM's verdict, isLowRamDevice(); MemoryInfo.lowMemory only says
        // memory is short at this moment.
        MethodChannel(messenger, MEMORY_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "read") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val manager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
            val info = ActivityManager.MemoryInfo()
            manager.getMemoryInfo(info)
            result.success(
                mapOf(
                    "totalMb" to info.totalMem / 1_048_576L,
                    "freeMb" to info.availMem / 1_048_576L,
                    "lowRam" to manager.isLowRamDevice,
                )
            )
        }

        // PiP Channel
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "enterPip") {
                val playing = call.argument<Boolean>("isPlaying") ?: false
                this.isPlaying = playing // Sync state immediately
                pipAspectRatio = aspectRatioOf(
                    call.argument<Int>("videoWidth"),
                    call.argument<Int>("videoHeight"),
                ) ?: pipAspectRatio

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    updatePipActions()
                    val builder = PictureInPictureParams.Builder()
                    builder.setActions(createPipActions())
                    // Without this the window is whatever shape Android last
                    // used, so a 2.39:1 film is letterboxed inside a window
                    // that is already small.
                    pipAspectRatio?.let { builder.setAspectRatio(it) }
                    // Returns false when the user has PiP switched off for
                    // this app: no exception, and no onPictureInPictureModeChanged
                    // either. Dart needs the answer to undo its own optimism.
                    result.success(enterPictureInPictureMode(builder.build()))
                } else {
                    result.error("UNSUPPORTED", "PIP not supported", null)
                }
            } else if (call.method == "setPipState") {
                // Flutter tells us if playing or not
                val playing = call.argument<Boolean>("isPlaying") ?: false
                aspectRatioOf(
                    call.argument<Int>("videoWidth"),
                    call.argument<Int>("videoHeight"),
                )?.let { pipAspectRatio = it }
                // Always update state and force refresh actions
                // The user reported sync issues, so we shouldn't skip update if values match
                this.isPlaying = playing
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    updatePipActions()
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        // Android TV Channel
        MethodChannel(messenger, TV_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "createTvChannel" -> {
                    TvChannelUtils.createTvChannel(this)
                    result.success(null)
                }
                "addPrograms" -> {
                    // Start a background thread or coroutine ideally, but for now simple invocation
                    // The TvUtils methods do ContentProvider ops which should be background, but strict mode might complain. 
                    // Given this is a demo clone, running on UI thread (MethodChannel default) might cause minor frame drop but is simplest.
                    // Ideally use Thread { ... }.start() if heavy.
                    Thread {
                        val channelId = TvChannelUtils.getChannelId(this, getString(R.string.app_name))
                        if (channelId != null) {
                             val items = call.argument<List<Map<String, Any>>>("programs") ?: emptyList()
                             TvChannelUtils.addPrograms(this, channelId, items)
                             runOnUiThread { result.success(null) }
                        } else {
                             // Try to create channel if missing?
                             TvChannelUtils.createTvChannel(this)
                             val newId = TvChannelUtils.getChannelId(this, getString(R.string.app_name))
                             if (newId != null) {
                                  val items = call.argument<List<Map<String, Any>>>("programs") ?: emptyList()
                                  TvChannelUtils.addPrograms(this, newId, items)
                                  runOnUiThread { result.success(null) }
                             } else {
                                  runOnUiThread { result.error("NO_CHANNEL", "Channel not found and creation failed", null) }
                             }
                        }
                    }.start()
                }
                "deleteStoredPrograms" -> {
                    Thread {
                        TvChannelUtils.deleteStoredPrograms(this)
                        runOnUiThread { result.success(null) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        // External Player Channel — uses native Intent to avoid Uri.parse() issues
        MethodChannel(messenger, PLAYER_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "launchVideoInPlayer") {
                val videoUrl = call.argument<String>("url") ?: run {
                    result.error("INVALID_ARGS", "url is required", null)
                    return@setMethodCallHandler
                }
                val packageName = call.argument<String>("package")
                val mimeType = call.argument<String>("mimeType") ?: "video/*"
                val title = call.argument<String>("title")
                @Suppress("UNCHECKED_CAST")
                val headers = call.argument<Map<String, String>>("headers")

                try {
                    val uri = if (videoUrl.startsWith("file://") || (videoUrl.startsWith("/") && File(videoUrl).exists())) {
                        val filePath = if (videoUrl.startsWith("file://")) {
                            videoUrl.substring(7)
                        } else {
                            videoUrl
                        }
                        FileProvider.getUriForFile(this, "${applicationContext.packageName}.fileProvider", File(filePath))
                    } else {
                        Uri.parse(videoUrl)
                    }

                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, mimeType)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        if (!packageName.isNullOrEmpty()) setPackage(packageName)
                        if (!title.isNullOrEmpty()) {
                            putExtra("title", title)
                            putExtra("android.intent.extra.TITLE", title)
                        }
                        // VLC / MX / Just Player style HTTP headers.
                        if (!headers.isNullOrEmpty()) {
                            val headerBundle = Bundle()
                            val headerString = StringBuilder()
                            for ((key, value) in headers) {
                                if (key.isBlank() || value.isBlank()) continue
                                headerBundle.putString(key, value)
                                headerString.append(key).append(": ").append(value).append("\r\n")
                            }
                            putExtra("android.media.intent.extra.HTTP_HEADERS", headerBundle)
                            putExtra("headers", headerString.toString())
                            // VLC-Android accepts a string array of "Key: Value".
                            putExtra(
                                "android.media.intent.extra.HTTP_HEADERS_ARRAY",
                                headers.map { "${it.key}: ${it.value}" }.toTypedArray(),
                            )
                        }
                    }
                    startActivity(intent)
                    result.success(true)
                } catch (e: android.content.ActivityNotFoundException) {
                    result.success(false) // Player not installed / not found
                } catch (e: Exception) {
                    result.error("LAUNCH_ERROR", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
    
    // Action Constants
    //
    // Namespaced, and paired with RECEIVER_NOT_EXPORTED below. The bare
    // "media_control" string was registered as an exported receiver, so any
    // app on the device could broadcast it and pause, resume or seek whatever
    // the user was watching.
    private val ACTION_MEDIA_CONTROL = "dev.akash.skystream.MEDIA_CONTROL"
    private val EXTRA_CONTROL_TYPE = "control_type"
    private val CONTROL_TYPE_PLAY = 1
    private val CONTROL_TYPE_PAUSE = 2
    private val CONTROL_TYPE_REWIND = 3
    private val CONTROL_TYPE_FORWARD = 4

    private val receiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: android.content.Intent?) {
            if (intent?.action == ACTION_MEDIA_CONTROL) {
                val type = intent.getIntExtra(EXTRA_CONTROL_TYPE, 0)
                val method = when (type) {
                    CONTROL_TYPE_PLAY -> "play"
                    CONTROL_TYPE_PAUSE -> "pause"
                    CONTROL_TYPE_REWIND -> "seekBackward"
                    CONTROL_TYPE_FORWARD -> "seekForward"
                    else -> null
                }
                if (method != null) {
                    flutterEngine?.dartExecutor?.binaryMessenger?.let {
                        MethodChannel(it, CHANNEL).invokeMethod(method, null)
                    }
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {}

    private fun flutterViewIn(view: android.view.View?): FlutterView? = when (view) {
        is FlutterView -> view
        is android.view.ViewGroup ->
            (0 until view.childCount).firstNotNullOfOrNull { flutterViewIn(view.getChildAt(it)) }
        else -> null
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        switchLaunchThemeForNormalTheme()
        super.onCreate(savedInstanceState)
        setContentView(FrameLayout(this).apply { id = FRAGMENT_CONTAINER_ID })
        flutterFragment = supportFragmentManager.findFragmentByTag(TAG_FLUTTER_FRAGMENT) as FlutterFragment?
            ?: FlutterFragment.withNewEngine()
                .shouldAutomaticallyHandleOnBackPressed(true)
                // Opaque, as FlutterFragmentActivity builds it. A fragment is
                // transparent by default, which puts Flutter's surface above
                // the whole window: platform views shown through hybrid
                // composition (challenge_browser's page, in the check and
                // sign-in sheets) were drawn beneath it, never seen.
                .renderMode(RenderMode.surface)
                .transparencyMode(TransparencyMode.opaque)
                .build<FlutterFragment>()
                .also {
                    supportFragmentManager.beginTransaction()
                        .add(FRAGMENT_CONTAINER_ID, it, TAG_FLUTTER_FRAGMENT)
                        .commit()
                }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val filter = android.content.IntentFilter(ACTION_MEDIA_CONTROL)
            // ContextCompat rather than registerReceiver(..., RECEIVER_NOT_EXPORTED)
            // directly: below Android 13 there is no flag, and the plain
            // two-argument overload the old code used there is exported by
            // default. ContextCompat closes that gap by registering with a
            // signature-level permission only this app holds.
            //
            // The PiP buttons still work: their PendingIntents are sent with
            // this app's own identity and uid, and a same-uid broadcast
            // reaches a non-exported receiver. The intents below also name
            // this package explicitly, so the broadcast never leaves the app.
            ContextCompat.registerReceiver(
                this,
                receiver,
                filter,
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(receiver)
        } catch (e: Exception) {}
    }

    private fun createPipActions(): List<android.app.RemoteAction> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return emptyList()

        val actions = mutableListOf<android.app.RemoteAction>()

        // 1. Rewind (Use custom 10s icon)
        val rewindIntent = android.content.Intent(ACTION_MEDIA_CONTROL).apply {
            setPackage(packageName)
            putExtra(EXTRA_CONTROL_TYPE, CONTROL_TYPE_REWIND)
        }
        val rewindPendingIntent = android.app.PendingIntent.getBroadcast(
            this, CONTROL_TYPE_REWIND, rewindIntent, android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        )
        val rewindIcon = android.graphics.drawable.Icon.createWithResource(this, R.drawable.ic_replay_10)
        actions.add(android.app.RemoteAction(rewindIcon, "Rewind", "Rewind 10s", rewindPendingIntent))

        // 2. Play/Pause
        val playPauseIntent = android.content.Intent(ACTION_MEDIA_CONTROL).apply {
            setPackage(packageName)
            putExtra(EXTRA_CONTROL_TYPE, if (isPlaying) CONTROL_TYPE_PAUSE else CONTROL_TYPE_PLAY)
        }
        // Unique Request Code is Critical
        val playPauseReqCode = if (isPlaying) CONTROL_TYPE_PAUSE else CONTROL_TYPE_PLAY
        val playPausePendingIntent = android.app.PendingIntent.getBroadcast(
            this, playPauseReqCode, playPauseIntent, android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        )
        val playPauseIconIdx = if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play_arrow
        val playPauseTitle = if (isPlaying) "Pause" else "Play"
        val playPauseIcon = android.graphics.drawable.Icon.createWithResource(this, playPauseIconIdx)
        actions.add(android.app.RemoteAction(playPauseIcon, playPauseTitle, playPauseTitle, playPausePendingIntent))

        // 3. Forward (Use custom 10s icon)
        val forwardIntent = android.content.Intent(ACTION_MEDIA_CONTROL).apply {
            setPackage(packageName)
            putExtra(EXTRA_CONTROL_TYPE, CONTROL_TYPE_FORWARD)
        }
        val forwardPendingIntent = android.app.PendingIntent.getBroadcast(
            this, CONTROL_TYPE_FORWARD, forwardIntent, android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        )
        val forwardIcon = android.graphics.drawable.Icon.createWithResource(this, R.drawable.ic_forward_10)
        actions.add(android.app.RemoteAction(forwardIcon, "Forward", "Forward 10s", forwardPendingIntent))

        return actions
    }

    private fun updatePipActions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val builder = PictureInPictureParams.Builder()
                .setActions(createPipActions())
            pipAspectRatio?.let { builder.setAspectRatio(it) }
            setPictureInPictureParams(builder.build())
        }
    }

    /**
     * The video's shape as a [Rational] PiP will accept, or null when Dart has
     * not decoded a frame yet and there is nothing to say.
     *
     * Clamped, and that is the load-bearing part: Android rejects any aspect
     * ratio outside roughly 1:2.39 .. 2.39:1 by throwing
     * IllegalArgumentException out of `enterPictureInPictureMode`, which would
     * crash the app on the way into the window. A 2.76:1 Ultra Panavision
     * transfer or a phone-shot vertical clip is not a hypothetical, so the
     * bound is applied a hair inside the documented limit rather than at it.
     */
    private fun aspectRatioOf(width: Int?, height: Int?): Rational? {
        if (width == null || height == null || width <= 0 || height <= 0) {
            return null
        }
        val ratio = (width.toDouble() / height.toDouble())
            .coerceIn(1.0 / MAX_PIP_ASPECT, MAX_PIP_ASPECT)
        return Rational((ratio * 10_000).roundToInt(), 10_000)
    }

    /** The manifest's NormalTheme, as FlutterActivity applies it once the launch screen is up. */
    private fun switchLaunchThemeForNormalTheme() {
        try {
            val metaData = packageManager.getActivityInfo(componentName, PackageManager.GET_META_DATA).metaData
            val theme = metaData?.getInt("io.flutter.embedding.android.NormalTheme", -1) ?: -1
            if (theme != -1) setTheme(theme)
        } catch (e: PackageManager.NameNotFoundException) {
        }
    }

    // Lifecycle calls a FlutterFragment needs from its host, as FlutterFragmentActivity forwards them.
    override fun onPostResume() {
        super.onPostResume()
        flutterFragment?.onPostResume()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        flutterFragment?.onNewIntent(intent)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        flutterFragment?.onUserLeaveHint()
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        flutterFragment?.onTrimMemory(level)
    }

    @Deprecated("Forwarded for plugins that still use startActivityForResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        flutterFragment?.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        flutterFragment?.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    companion object {
        private const val TAG_FLUTTER_FRAGMENT = "flutter_fragment"
        private val FRAGMENT_CONTAINER_ID = android.view.View.generateViewId()

        /**
         * Android's documented ceiling is 2.39:1 (and its reciprocal). Held a
         * hair inside it so a film that *is* exactly 2.39:1 cannot land on the
         * wrong side of a float comparison inside the framework.
         */
        private const val MAX_PIP_ASPECT = 2.38
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        // Safe call, not !!. Closing the PiP window is one of the ways this
        // activity is torn down, and the engine can already be detached by the
        // time the leave-PiP callback lands — which crashed the app on exit.
        // The receiver above uses the same guarded form for the same reason.
        flutterEngine?.dartExecutor?.binaryMessenger?.let {
            MethodChannel(it, CHANNEL).invokeMethod("pipModeChanged", isInPictureInPictureMode)
        }
    }
}
