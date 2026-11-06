package com.lingjhf.vlc_player

import kotlin.math.roundToInt

/// How far libVLC raises subtitle lines (`sub-margin`) for a raise given as a
/// share of the picture's height - VlcSubtitleLook.raise in the Dart package.
///
/// libVLC counts the margin in pixels of whatever it lays the lines out on:
/// the picture it blends them into - the texture target's, which has no other
/// surface to draw them on - and, where an OpenGL display draws them itself,
/// as the platform view's does for hardware- and software-decoded video alike,
/// the picture on screen when that has more pixels than the decoded one (VLC
/// 3.0 src/video_output/video_output.c, ThreadDisplayRenderPicture). A crop
/// leaves the decoded picture its size but lays the lines out on what it
/// leaves. The picture on screen is placed in the view as libVLC's
/// vout_display_PlacePicture places it.
///
/// A rotated video is laid out unrotated here, so its raise comes out short.
internal object VlcSubtitleMargin {
    fun pixels(
        raise: Double,
        videoWidth: Int,
        videoHeight: Int,
        sarNum: Int,
        sarDen: Int,
        crop: String?,
        viewWidth: Int,
        viewHeight: Int,
        stretched: Boolean,
        drawnOnDisplay: Boolean,
    ): Int {
        if (raise.isNaN() || raise <= 0.0 || videoWidth <= 0 || videoHeight <= 0) {
            return 0
        }
        val known = sarNum > 0 && sarDen > 0
        val num = if (known) sarNum.toLong() else 1L
        val den = if (known) sarDen.toLong() else 1L
        val (cropWidth, cropHeight) = cropped(crop, videoWidth, videoHeight, num, den)
        var height = cropHeight
        if (drawnOnDisplay && viewWidth > 0 && viewHeight > 0) {
            val (placeWidth, placeHeight) = if (stretched) {
                // An aspect ratio of the view's own shape.
                viewWidth.toLong() to viewHeight.toLong()
            } else {
                place(cropWidth, cropHeight, num, den, viewWidth, viewHeight)
            }
            if (placeWidth * placeHeight > videoWidth.toLong() * videoHeight) {
                height = placeHeight
            }
        }
        return (raise.coerceAtMost(0.5) * height).roundToInt()
    }

    /// What [crop] leaves of the picture, as libVLC reads it: a region
    /// `WxH+X+Y`, or a shape `W:H` cut from the middle at the picture's
    /// display shape. The whole picture for none, or for one it cannot read.
    private fun cropped(
        crop: String?,
        videoWidth: Int,
        videoHeight: Int,
        num: Long,
        den: Long,
    ): Pair<Long, Long> {
        val width = videoWidth.toLong()
        val height = videoHeight.toLong()
        val whole = width to height
        if (crop.isNullOrEmpty()) {
            return whole
        }
        region.matchEntire(crop)?.let { match ->
            val regionWidth = match.groupValues[1].toLongOrNull() ?: return whole
            val regionHeight = match.groupValues[2].toLongOrNull() ?: return whole
            if (regionWidth <= 0 || regionHeight <= 0) {
                return whole
            }
            return minOf(regionWidth, width) to minOf(regionHeight, height)
        }
        ratio.matchEntire(crop)?.let { match ->
            val shapeWidth = match.groupValues[1].toLongOrNull() ?: return whole
            val shapeHeight = match.groupValues[2].toLongOrNull() ?: return whole
            if (shapeWidth <= 0 || shapeHeight <= 0) {
                return whole
            }
            // Wider than the shape on screen: the sides go. Otherwise the top
            // and bottom do.
            return if (width * num * shapeHeight > shapeWidth * height * den) {
                height * shapeWidth * den / (shapeHeight * num) to height
            } else {
                width to width * num * shapeHeight / (shapeWidth * den)
            }
        }
        return whole
    }

    /// The picture contained in the view at its display shape.
    private fun place(
        pictureWidth: Long,
        pictureHeight: Long,
        num: Long,
        den: Long,
        viewWidth: Int,
        viewHeight: Int,
    ): Pair<Long, Long> {
        val scaledWidth = pictureWidth * viewHeight * num / (pictureHeight * den)
        if (scaledWidth <= viewWidth) {
            return scaledWidth to viewHeight.toLong()
        }
        val scaledHeight = pictureHeight * viewWidth * den / (pictureWidth * num)
        return viewWidth.toLong() to scaledHeight
    }

    private val region = Regex("""(\d+)x(\d+)(?:[+-]\d+){0,2}""")
    private val ratio = Regex("""(\d+):(\d+)""")
}
