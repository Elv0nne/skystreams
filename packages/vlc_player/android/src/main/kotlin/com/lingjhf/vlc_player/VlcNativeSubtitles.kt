package com.lingjhf.vlc_player

import android.util.Log
import org.videolan.libvlc.MediaPlayer

/// The look of the subtitle lines libVLC draws into the picture, changed
/// while the video plays - which libvlc-android 3.x has no call for.
///
/// Backed by the JNI shim in src/main/cpp/vlc_player_subtitles.c, built into
/// the same library as the crop (VlcNativeGeometry). Without it, a changed
/// look waits for the next player.
internal object VlcNativeSubtitles {
    /// The look - see VlcSubtitleLook in the Dart package. [raise] is a share
    /// of the picture's height; [apply] takes it in libVLC's pixels.
    data class Look(
        val textScale: Int,
        val color: Int,
        val backgroundColor: Int,
        val backgroundOpacity: Int,
        val outlineThickness: Int,
        val raise: Double,
    )

    @Volatile
    private var available: Boolean = try {
        System.loadLibrary("vlc_player_geometry")
        true
    } catch (error: UnsatisfiedLinkError) {
        Log.w("VlcPlayer", "libVLC subtitle looks are unavailable: ${error.message}")
        false
    }

    /// Applies [look] to [player], its lines raised [margin] of libVLC's
    /// pixels - see VlcSubtitleMargin: its text tracks show it from their next
    /// line, and their lines move at once. False when this libVLC cannot.
    fun apply(player: MediaPlayer, look: Look, margin: Int): Boolean {
        val instance = instanceOf(player) ?: return false
        return guarded {
            nativeApplyLook(
                instance,
                look.textScale,
                look.color,
                look.backgroundColor,
                look.backgroundOpacity,
                look.outlineThickness,
                margin,
            )
        }
    }

    /// Whether [player]'s OpenGL display draws its subtitle lines itself, in
    /// pixels of the picture on screen - see VlcSubtitleMargin.
    fun drawnOnDisplay(player: MediaPlayer): Boolean {
        val instance = instanceOf(player) ?: return false
        return guarded { nativeDrawnOnDisplay(instance) }
    }

    private fun instanceOf(player: MediaPlayer): Long? =
        if (available) player.instance.takeIf { it != 0L } else null

    private inline fun guarded(call: () -> Boolean): Boolean = try {
        call()
    } catch (error: UnsatisfiedLinkError) {
        // As for the crop: a host that minified the name away.
        Log.w("VlcPlayer", "libVLC subtitle looks are unavailable: ${error.message}")
        available = false
        false
    }

    @JvmStatic
    private external fun nativeApplyLook(
        player: Long,
        textScale: Int,
        color: Int,
        backgroundColor: Int,
        backgroundOpacity: Int,
        outlineThickness: Int,
        margin: Int,
    ): Boolean

    @JvmStatic
    private external fun nativeDrawnOnDisplay(player: Long): Boolean
}
