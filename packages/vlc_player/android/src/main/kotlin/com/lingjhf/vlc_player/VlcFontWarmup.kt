package com.lingjhf.vlc_player

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import org.videolan.libvlc.LibVLC

/// libVLC's font database, built in the background before the first video.
///
/// libVLC's freetype text renderer has fontconfig build its font database the
/// first time a video output is made in a process, on the thread that opens
/// the media and before the decoder gets its output, so nothing plays until
/// it is done. With no cache that is a scan of every system font: 11.5 s on
/// the phone emulator and 12.7 s on the TV emulator, for the first video after
/// an install. fontconfig then keeps a cache in libvlc-android's home, and
/// every later build takes milliseconds. This builds it when the plugin
/// registers, if there is no cache yet, with the fontconfig in libvlc.so -
/// see src/main/cpp/vlc_player_fonts.c.
///
/// A player's play waits at [gate] while this runs, so libVLC then reads the
/// finished cache. Started alongside, its own scan slowed both: the first
/// picture of a fresh install took 32 s on the phone emulator (35 s for this
/// build), past the player screen's 30 s first-frame deadline, whose reopen
/// stranded the player inside its scan (SkyStream's QoE suite, 2026-10-14).
/// An OS update that changes the system fonts leaves a stale cache, which
/// libVLC rebuilds at the next first video, as before.
internal object VlcFontWarmup {
    /// The longest a play waits for the build: past it, libVLC builds its
    /// own, as it would have without this.
    private const val GATE_LIMIT_MS = 60_000L

    private val started = AtomicBoolean(false)

    /// Where players' plays wait while the database is being built.
    val gate = VlcStartGate()

    /// Starts the build on its own thread, once per process, when fontconfig
    /// has no cache yet.
    fun startIfNeeded(context: Context) {
        val appContext = context.applicationContext
        // libvlc-android's home: LibVLC hands this directory to nativeNew, and
        // libvlcjni makes it HOME, under which fontconfig keeps its cache.
        val home = appContext.getDir("vlc", Context.MODE_PRIVATE)
        startOnce(started, cacheDirectory(home)) {
            gate.close()
            val main = Handler(Looper.getMainLooper())
            main.postDelayed({ gate.open() }, GATE_LIMIT_MS)
            Thread({
                try {
                    build(appContext)
                } finally {
                    main.post { gate.open() }
                }
            }, "vlc-font-warmup").apply {
                isDaemon = true
                start()
            }
        }
    }

    /// Where fontconfig keeps its cache under libvlc-android's [home].
    fun cacheDirectory(home: File): File = File(home, ".cache/fontconfig")

    /// Whether fontconfig has yet to write a cache file
    /// (`<hash>-<arch>.cache-<version>`) into [cacheDirectory].
    fun needsDatabase(cacheDirectory: File): Boolean =
        cacheDirectory.listFiles()?.none { it.isFile && it.name.contains(".cache-") } ?: true

    /// Calls [launch] when [cacheDirectory] needs the database and [started]
    /// was not set yet, setting it; true when it did.
    fun startOnce(started: AtomicBoolean, cacheDirectory: File, launch: () -> Unit): Boolean {
        if (!needsDatabase(cacheDirectory) || !started.compareAndSet(false, true)) {
            return false
        }
        launch()
        return true
    }

    private fun build(context: Context) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
        val began = SystemClock.elapsedRealtime()
        try {
            // A LibVLC first: it loads libvlc.so and sets HOME, as every
            // player's does, so fontconfig writes where libVLC will look.
            val libVLC = LibVLC(context, ArrayList<String>())
            try {
                System.loadLibrary("vlc_player_geometry")
                val built = nativeBuildFontDatabase()
                val took = SystemClock.elapsedRealtime() - began
                Log.i("VlcPlayer", "font database ${if (built) "built" else "not built"} in $took ms")
            } finally {
                libVLC.release()
            }
        } catch (error: RuntimeException) {
            Log.w("VlcPlayer", "font database not built ahead: ${error.message}")
        } catch (error: UnsatisfiedLinkError) {
            Log.w("VlcPlayer", "font database not built ahead: ${error.message}")
        }
    }

    @JvmStatic
    private external fun nativeBuildFontDatabase(): Boolean
}
