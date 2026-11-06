package com.lingjhf.vlc_player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The arithmetic behind the player's volume and brightness swipes on Android. */
internal class VlcDeviceLevelsTest {
    @Test
    fun indexFor_roundsToTheNearestStepOfTheStream() {
        assertEquals(8, VlcDeviceLevels.indexFor(0.5, 15))
        assertEquals(0, VlcDeviceLevels.indexFor(-1.0, 15))
        assertEquals(15, VlcDeviceLevels.indexFor(2.0, 15))
        assertEquals(0, VlcDeviceLevels.indexFor(Double.NaN, 15))
        assertEquals(0, VlcDeviceLevels.indexFor(0.5, 0))
    }

    @Test
    fun levelFor_isTheShareOfTheStream() {
        assertEquals(8.0 / 15, VlcDeviceLevels.levelFor(8, 15))
        assertEquals(1.0, VlcDeviceLevels.levelFor(20, 15))
        assertEquals(0.0, VlcDeviceLevels.levelFor(3, 0))
    }

    @Test
    fun heldBack_isOnlyARaiseThatDidNotTake() {
        // The hearing-safety limit: a raise past the safe level stays where it was until the person confirms.
        assertTrue(VlcDeviceLevels.heldBack(wanted = 12, before = 10, actual = 10))
        assertFalse(VlcDeviceLevels.heldBack(wanted = 12, before = 10, actual = 12))
        // A lowering is never held back.
        assertFalse(VlcDeviceLevels.heldBack(wanted = 4, before = 10, actual = 10))
    }

    @Test
    fun windowBrightness_neverGoesUnderTheFloor() {
        // 0 turns some panels' backlight off: VLC's floor.
        assertEquals(0.01f, VlcDeviceLevels.windowBrightness(0.0))
        assertEquals(0.01f, VlcDeviceLevels.windowBrightness(Double.NaN))
        assertEquals(0.5f, VlcDeviceLevels.windowBrightness(0.5))
        assertEquals(1f, VlcDeviceLevels.windowBrightness(1.5))
    }

    @Test
    fun systemBrightness_isTheSettingOverItsMaximum() {
        assertEquals(128.0 / 255, VlcDeviceLevels.systemBrightness(128, 255))
        assertEquals(1.0, VlcDeviceLevels.systemBrightness(300, 255))
        assertEquals(0.5, VlcDeviceLevels.systemBrightness(2048, 4096))
        // A maximum the platform didn't give: the usual 255.
        assertEquals(100.0 / 255, VlcDeviceLevels.systemBrightness(100, 0))
    }
}
