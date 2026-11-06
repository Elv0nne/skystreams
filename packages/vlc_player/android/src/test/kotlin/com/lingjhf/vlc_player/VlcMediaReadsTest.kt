package com.lingjhf.vlc_player

import org.mockito.MockMakers
import org.mockito.Mockito
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.interfaces.IMedia
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * `getMediaInfo` and `getMediaStats` read the media the player is playing, and
 * libvlcjni's `MediaPlayer.getMedia()` retains the media it hands out. Each
 * read has to give that reference back, or every call - media stats are asked
 * for four times a second - keeps a media alive after the player has moved on.
 */
internal class VlcMediaReadsTest {
    /**
     * A player on [media]. A subclass mock, because `getLength()` is a native
     * method: the inline mock maker cannot stand in for one, and the real one
     * has no library to call into on the JVM.
     */
    private fun playerOn(media: IMedia?): MediaPlayer {
        val player = Mockito.mock(
            MediaPlayer::class.java,
            Mockito.withSettings().mockMaker(MockMakers.SUBCLASS),
        )
        Mockito.`when`(player.media).thenReturn(media)
        return player
    }

    @Test
    fun mediaInfoOf_releasesTheMediaItRead() {
        val media = Mockito.mock(IMedia::class.java)
        Mockito.`when`(media.getMeta(IMedia.Meta.Title)).thenReturn("Channel One")
        val player = playerOn(media)

        val info = mediaInfoOf(player)

        assertEquals("Channel One", info["title"])
        Mockito.verify(player, Mockito.times(1)).media
        Mockito.verify(media, Mockito.times(1)).release()
    }

    @Test
    fun mediaStatsOf_releasesTheMediaItRead() {
        val media = Mockito.mock(IMedia::class.java)
        val player = playerOn(media)

        val stats = mediaStatsOf(player)

        assertEquals(false, stats["available"])
        Mockito.verify(player, Mockito.times(1)).media
        Mockito.verify(media, Mockito.times(1)).release()
    }

    @Test
    fun mediaInfoOf_answersForAPlayerWithNoMedia() {
        val info = mediaInfoOf(playerOn(null))

        assertEquals(0L, info["duration"])
        assertEquals(emptyList<Map<String, Any?>>(), info["audioTracks"])
    }
}
