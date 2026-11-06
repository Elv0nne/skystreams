package com.lingjhf.vlc_player

import com.lingjhf.vlc_player.VlcSurfaceHandover.Change.Remove
import com.lingjhf.vlc_player.VlcSurfaceHandover.Change.Show
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Players and their surfaces as names: p1 draws into s1, p2 into s2. */
internal class VlcSurfaceHandoverTest {
    private val handover = VlcSurfaceHandover<String, String>()

    @Test
    fun aNewSurfaceComesToTheFrontOnlyAtItsPlayersFirstPicture() {
        handover.start("p1", "s1")
        handover.replace("p1", "p2", "s2")
        assertEquals("s1", handover.onShow, "the picture a held copy is taken from")
        assertEquals(listOf(Show("s2")), handover.pictureUp("p2"))
        assertEquals("s2", handover.onShow)
        assertEquals(emptyList(), handover.pictureUp("p2"), "once")
    }

    @Test
    fun aReplacedSurfaceStaysOnShowAfterItsReleaseUntilANewerPictureIsUp() {
        handover.start("p1", "s1")
        handover.replace("p1", "p2", "s2")
        assertEquals(emptyList(), handover.released("p1"), "its last picture is what shows")
        assertEquals(listOf(Show("s2"), Remove("s1")), handover.pictureUp("p2"))
    }

    @Test
    fun aReplacedSurfaceGoesAtItsPlayersReleaseWhenANewerPictureIsAlreadyUp() {
        handover.start("p1", "s1")
        handover.replace("p1", "p2", "s2")
        assertEquals(listOf(Show("s2")), handover.pictureUp("p2"))
        assertEquals(listOf(Remove("s1")), handover.released("p1"))
    }

    @Test
    fun aPlayerThatNeverStopsKeepsItsSurfaceInTheView() {
        handover.start("p1", "s1")
        handover.replace("p1", "p2", "s2")
        handover.pictureUp("p2")
        handover.replace("p2", "p3", "s3")
        handover.released("p2")
        // p1's output may still draw: its surface stays, under the others.
        assertEquals(listOf(Show("s3"), Remove("s2")), handover.pictureUp("p3"))
    }

    @Test
    fun aSurfaceReplacedBeforeItsFirstPictureGoesAtItsRelease() {
        handover.start("p1", "s1")
        handover.replace("p1", "p2", "s2")
        handover.replace("p2", "p3", "s3")
        assertEquals(listOf(Remove("s2")), handover.released("p2"))
        assertEquals(emptyList(), handover.released("p1"), "still the picture on show")
        assertEquals(listOf(Show("s3"), Remove("s1")), handover.pictureUp("p3"))
    }

    @Test
    fun aLateFirstPictureFromAReplacedPlayerChangesNothing() {
        handover.start("p1", "s1")
        handover.replace("p1", "p2", "s2")
        handover.replace("p2", "p3", "s3")
        assertEquals(emptyList(), handover.pictureUp("p2"))
    }

    @Test
    fun nothingChangesOnceTheViewIsGone() {
        handover.start("p1", "s1")
        handover.replace("p1", "p2", "s2")
        handover.dispose()
        assertNull(handover.onShow)
        assertEquals(emptyList(), handover.pictureUp("p2"))
        assertEquals(emptyList(), handover.released("p1"))
        assertEquals(emptyList(), handover.released("p2"))
    }

    @Test
    fun aBlackFrameIsNoPictureAndALetterboxedOneIs() {
        val black = IntArray(64) { 0xFF000000.toInt() }
        assertFalse(VlcSurfaceHandover.isPicture(black), "an output's first clear")
        // Rows 3 and 4 of 8 grained green, the rest the letterbox's black: a
        // 16:9 picture in a portrait view.
        val letterboxed = IntArray(64) { i -> if (i / 8 in 3..4) 0xFF00A000.toInt() else 0xFF000000.toInt() }
        assertTrue(VlcSurfaceHandover.isPicture(letterboxed))
        val nearBlack = IntArray(64) { 0xFF0A0A0A.toInt() }
        assertFalse(VlcSurfaceHandover.isPicture(nearBlack), "too dark to tell: the time report decides")
    }
}
