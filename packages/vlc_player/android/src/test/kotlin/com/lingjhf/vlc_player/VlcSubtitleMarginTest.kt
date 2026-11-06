package com.lingjhf.vlc_player

import kotlin.test.Test
import kotlin.test.assertEquals

/** How far libVLC raises subtitle lines on Android, in the pixels it counts them in. */
internal class VlcSubtitleMarginTest {
    private fun pixels(
        raise: Double,
        video: Pair<Int, Int>,
        view: Pair<Int, Int>,
        drawnOnDisplay: Boolean,
        stretched: Boolean = false,
        crop: String? = null,
        sar: Pair<Int, Int> = 1 to 1,
    ): Int = VlcSubtitleMargin.pixels(
        raise = raise,
        videoWidth = video.first,
        videoHeight = video.second,
        sarNum = sar.first,
        sarDen = sar.second,
        crop = crop,
        viewWidth = view.first,
        viewHeight = view.second,
        stretched = stretched,
        drawnOnDisplay = drawnOnDisplay,
    )

    @Test
    fun isAShareOfTheDecodedPicture_whereLibVlcBlendsTheLinesIntoIt() {
        assertEquals(36, pixels(0.1, 640 to 360, 2560 to 1440, drawnOnDisplay = false))
    }

    @Test
    fun isAShareOfThePictureOnScreen_whereTheOpenGLDisplayDrawsThemLarger() {
        // Measured on an Android TV emulator: 60 pixels moved the lines 60/1440.
        assertEquals(144, pixels(0.1, 640 to 360, 2560 to 1440, drawnOnDisplay = true))
    }

    @Test
    fun isTheDecodedPictureAgain_whereTheScreenShowsItSmaller() {
        assertEquals(216, pixels(0.1, 3840 to 2160, 1920 to 1080, drawnOnDisplay = true))
    }

    @Test
    fun aLetterboxedPicture_isAShareOfThePictureNotTheView() {
        // 1280x534 contained in 1920x1080 is shown 1920x801.
        assertEquals(80, pixels(0.1, 1280 to 534, 1920 to 1080, drawnOnDisplay = true))
    }

    @Test
    fun aStretchedPicture_isAShareOfTheView() {
        // Stretch: an aspect ratio of the view's shape.
        assertEquals(
            108,
            pixels(0.1, 1280 to 534, 1920 to 1080, drawnOnDisplay = true, stretched = true),
        )
    }

    @Test
    fun aZoomedPicture_isAShareOfTheViewItFills_whenThatIsTheLarger() {
        // 720p zoomed in a 1920x1080 view: cut to 16:9 and shown at the view's size.
        assertEquals(
            108,
            pixels(0.1, 1280 to 534, 1920 to 1080, drawnOnDisplay = true, crop = "16:9"),
        )
    }

    @Test
    fun aZoomedPicture_isAShareOfWhatTheCropLeaves_whenThatIsTheLarger() {
        // 1080p zoomed on a 1600x720 phone: cut to 20:9 it is 1920x864, still
        // more pixels than the view, so libVLC lays the lines out on the crop.
        assertEquals(
            86,
            pixels(0.1, 1920 to 1080, 1600 to 720, drawnOnDisplay = true, crop = "20:9"),
        )
    }

    @Test
    fun anOriginalRegion_isPlacedAtItsOwnShape() {
        // Original on a 1600x900 view: the middle 1280x800 of a 1080p picture,
        // which the view shows 1440x900 - fewer pixels than the picture.
        assertEquals(
            80,
            pixels(0.1, 1920 to 1080, 1600 to 900, drawnOnDisplay = true, crop = "1280x800+320+140"),
        )
    }

    @Test
    fun aCropOfTheBlendedPicture_isAShareOfWhatItLeaves() {
        assertEquals(
            86,
            pixels(0.1, 1920 to 1080, 1600 to 720, drawnOnDisplay = false, crop = "20:9"),
        )
    }

    @Test
    fun aCropItCannotRead_leavesThePictureWhole() {
        assertEquals(108, pixels(0.1, 1920 to 1080, 0 to 0, drawnOnDisplay = false, crop = "wide"))
        assertEquals(108, pixels(0.1, 1920 to 1080, 0 to 0, drawnOnDisplay = false, crop = "0:9"))
    }

    @Test
    fun anAnamorphicPicture_isShownAtItsDisplayShape() {
        // PAL 16:9: 720x576 at 64:45 is shown 1920x1080 in a 1920x1080 view.
        assertEquals(
            108,
            pixels(0.1, 720 to 576, 1920 to 1080, drawnOnDisplay = true, sar = 64 to 45),
        )
    }

    @Test
    fun nothingRaisesNothing() {
        assertEquals(0, pixels(0.0, 640 to 360, 2560 to 1440, drawnOnDisplay = true))
        assertEquals(0, pixels(-0.2, 640 to 360, 2560 to 1440, drawnOnDisplay = true))
        assertEquals(0, pixels(Double.NaN, 640 to 360, 2560 to 1440, drawnOnDisplay = true))
        // Before the picture has a size.
        assertEquals(0, pixels(0.1, 0 to 0, 2560 to 1440, drawnOnDisplay = true))
    }

    @Test
    fun isHeldToHalfThePicture() {
        assertEquals(180, pixels(0.9, 640 to 360, 0 to 0, drawnOnDisplay = false))
    }
}
