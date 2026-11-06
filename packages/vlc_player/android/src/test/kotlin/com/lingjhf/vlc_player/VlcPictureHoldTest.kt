package com.lingjhf.vlc_player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The Kotlin twin of src/native/vlc_picture_hold.h, held to the same cases. */
internal class VlcPictureHoldTest {
    @Test
    fun holdsOnlyWhenAskedAndThereIsAPicture() {
        val hold = VlcPictureHold()
        assertEquals(VlcPictureHold.Change.NONE, hold.arm(keepPicture = false, hasPicture = true))
        assertEquals(VlcPictureHold.Change.NONE, hold.arm(keepPicture = true, hasPicture = false))
        assertFalse(hold.held)
        assertEquals(VlcPictureHold.Change.HOLD, hold.arm(keepPicture = true, hasPicture = true))
        assertTrue(hold.held)
    }

    @Test
    fun endsAtTheFirstTimeAfterTheNewMediaOpens() {
        val hold = VlcPictureHold()
        hold.arm(keepPicture = true, hasPicture = true)
        assertEquals(VlcPictureHold.Change.NONE, hold.onTimeChanged())
        hold.onOpening()
        assertEquals(VlcPictureHold.Change.RELEASE, hold.onTimeChanged())
        assertFalse(hold.held)
    }

    @Test
    fun aMediaGoingNeverEndsIt() {
        val hold = VlcPictureHold()
        hold.arm(keepPicture = true, hasPicture = true)
        assertEquals(VlcPictureHold.Change.NONE, hold.onMediaGone())
        hold.onOpening()
        assertEquals(VlcPictureHold.Change.NONE, hold.onMediaGone())
        assertTrue(hold.held)
    }

    @Test
    fun aReopenAfterAFailureCarriesTheHoldOn() {
        val hold = VlcPictureHold()
        hold.arm(keepPicture = true, hasPicture = true)
        hold.onOpening()
        assertEquals(VlcPictureHold.Change.NONE, hold.onMediaGone())
        assertEquals(VlcPictureHold.Change.NONE, hold.arm(keepPicture = true, hasPicture = true))
        assertTrue(hold.held)
        assertEquals(VlcPictureHold.Change.NONE, hold.onTimeChanged())
        hold.onOpening()
        assertEquals(VlcPictureHold.Change.RELEASE, hold.onTimeChanged())
        assertFalse(hold.held)
    }

    @Test
    fun aPlainSourceAfterAFailureEndsIt() {
        val hold = VlcPictureHold()
        hold.arm(keepPicture = true, hasPicture = true)
        hold.onOpening()
        assertEquals(VlcPictureHold.Change.NONE, hold.onMediaGone())
        assertEquals(VlcPictureHold.Change.RELEASE, hold.arm(keepPicture = false, hasPicture = true))
        assertFalse(hold.held)
    }

    @Test
    fun aPlayAfterAFailureEndsItAtItsFirstTime() {
        val hold = VlcPictureHold()
        hold.arm(keepPicture = true, hasPicture = true)
        hold.onOpening()
        assertEquals(VlcPictureHold.Change.NONE, hold.onMediaGone())
        hold.onOpening()
        assertEquals(VlcPictureHold.Change.RELEASE, hold.onTimeChanged())
    }

    @Test
    fun aReopenDuringAHoldKeepsThePictureAndWaitsForTheNewest() {
        val hold = VlcPictureHold()
        hold.arm(keepPicture = true, hasPicture = true)
        hold.onOpening()
        assertEquals(VlcPictureHold.Change.NONE, hold.arm(keepPicture = true, hasPicture = true))
        assertEquals(VlcPictureHold.Change.NONE, hold.onTimeChanged())
        hold.onOpening()
        assertEquals(VlcPictureHold.Change.RELEASE, hold.onTimeChanged())
    }

    @Test
    fun aReopenWithoutKeepPictureEndsIt() {
        val hold = VlcPictureHold()
        hold.arm(keepPicture = true, hasPicture = true)
        assertEquals(VlcPictureHold.Change.RELEASE, hold.arm(keepPicture = false, hasPicture = true))
        assertEquals(VlcPictureHold.Change.NONE, hold.release())
    }
}
