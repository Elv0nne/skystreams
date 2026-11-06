package com.lingjhf.vlc_player

import android.content.Context
import android.graphics.Color
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.view.TextureRegistry
import org.videolan.libvlc.util.VLCVideoLayout

/**
 * Where libVLC draws.
 *
 * Everything else about a player - audio focus, the becoming-noisy receiver,
 * event emission, track selection - is the same whichever way the frames reach
 * the screen, so the choice is a value the player is handed rather than a
 * second player class. Mirrors `VlcRenderTarget` in the Darwin plugins.
 */
internal sealed interface VlcRenderTarget {
    /**
     * [VLCVideoLayout]s inside a platform view, one for each player.
     *
     * libVLC decodes into a layout's TextureView and Flutter then composites
     * the platform view as a texture of its own: two full-frame compositions
     * per frame, a frame of latency, and the platform view's input and focus
     * plumbing.
     *
     * A player's video output can keep its surface until the player's stop
     * has returned, and a second output can't share it meanwhile, so every
     * player gets a layout of its own (FORK.md 29). [container] stacks them,
     * with the held picture over them.
     */
    class VideoLayout(private val context: Context) : VlcRenderTarget {
        /** The platform view's view. */
        val container = FrameLayout(context).apply { setBackgroundColor(Color.BLACK) }

        /** A layout for a new player, under every other one until its first picture. */
        fun newLayout(): VLCVideoLayout {
            val layout = VLCVideoLayout(context)
            container.addView(
                layout,
                0,
                FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
            )
            return layout
        }
    }

    /**
     * A Flutter-owned surface, drawn as an ordinary `Texture` widget.
     *
     * The decoder writes straight into Flutter's buffer queue, so the video is
     * composited once, with everything else in the frame, and the widget tree
     * owns fit and clipping. Subtitles are blended into the video by libVLC
     * because there is no second surface to put them on.
     */
    class Texture(val producer: TextureRegistry.SurfaceProducer) : VlcRenderTarget
}
