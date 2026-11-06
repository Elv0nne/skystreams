package com.lingjhf.vlc_player

import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.interfaces.IMedia

/** `getMediaInfo`'s answer: what the media [player] is playing says about itself and its tracks. */
internal fun mediaInfoOf(player: MediaPlayer): Map<String, Any?> {
    return readMedia(player) { media ->
        if (media == null) emptyMediaInfo() else mediaInfo(media, player.length)
    }
}

/** `getMediaStats`'s answer: the counters of the media [player] is playing. */
internal fun mediaStatsOf(player: MediaPlayer): Map<String, Any> {
    return readMedia(player) { media -> mediaStats(media?.getStats()) }
}

/**
 * Runs [read] on the media [player] is playing - null when it has none - and
 * gives back the reference that took.
 *
 * libvlcjni's `MediaPlayer.getMedia()` retains the media it hands out, so a
 * read that only drops the reference leaks it: the media, and libVLC's input
 * item behind it, outlive the player that moved on from them - one per call,
 * and media stats are asked for four times a second.
 */
private inline fun <T> readMedia(player: MediaPlayer, read: (IMedia?) -> T): T {
    val media = player.media
    try {
        return read(media)
    } finally {
        media?.release()
    }
}

private fun mediaInfo(media: IMedia, playerLength: Long): Map<String, Any?> {
    val info = HashMap<String, Any?>()
    info["title"] = media.getMeta(IMedia.Meta.Title)
    info["artist"] = media.getMeta(IMedia.Meta.Artist)
    info["album"] = media.getMeta(IMedia.Meta.Album)
    info["duration"] = maxOf(media.duration, playerLength, 0L)

    val videoTracks = ArrayList<Map<String, Any?>>()
    val audioTracks = ArrayList<Map<String, Any?>>()
    val subtitleTracks = ArrayList<Map<String, Any?>>()
    for (index in 0 until media.trackCount) {
        val track = media.getTrack(index) ?: continue
        val trackInfo = mediaTrackInfo(track)
        when (track.type) {
            IMedia.Track.Type.Video -> videoTracks.add(trackInfo)
            IMedia.Track.Type.Audio -> audioTracks.add(trackInfo)
            IMedia.Track.Type.Text -> subtitleTracks.add(trackInfo)
        }
    }
    info["videoTracks"] = videoTracks
    info["audioTracks"] = audioTracks
    info["subtitleTracks"] = subtitleTracks
    return info
}

private fun emptyMediaInfo(): Map<String, Any?> {
    return mapOf(
        "title" to null,
        "artist" to null,
        "album" to null,
        "duration" to 0L,
        "videoTracks" to emptyList<Map<String, Any?>>(),
        "audioTracks" to emptyList<Map<String, Any?>>(),
        "subtitleTracks" to emptyList<Map<String, Any?>>(),
    )
}

private fun mediaStats(stats: IMedia.Stats?): Map<String, Any> {
    return mapOf(
        "available" to (stats != null),
        "readBytes" to (stats?.readBytes ?: 0),
        "inputBitrate" to (stats?.inputBitrate?.toDouble() ?: 0.0),
        "demuxReadBytes" to (stats?.demuxReadBytes ?: 0),
        "demuxBitrate" to (stats?.demuxBitrate?.toDouble() ?: 0.0),
        "demuxCorrupted" to (stats?.demuxCorrupted ?: 0),
        "demuxDiscontinuity" to (stats?.demuxDiscontinuity ?: 0),
        "decodedVideo" to (stats?.decodedVideo ?: 0),
        "decodedAudio" to (stats?.decodedAudio ?: 0),
        "displayedPictures" to (stats?.displayedPictures ?: 0),
        "lostPictures" to (stats?.lostPictures ?: 0),
        "playedAudioBuffers" to (stats?.playedAbuffers ?: 0),
        "lostAudioBuffers" to (stats?.lostAbuffers ?: 0),
        "sentPackets" to (stats?.sentPackets ?: 0),
        "sentBytes" to (stats?.sentBytes ?: 0),
        "sendBitrate" to (stats?.sendBitrate?.toDouble() ?: 0.0),
    )
}

private fun mediaTrackInfo(track: IMedia.Track): Map<String, Any?> {
    val info = HashMap<String, Any?>()
    info["type"] = trackTypeName(track.type)
    info["codec"] = track.codec
    info["language"] = track.language
    info["bitrate"] = track.bitrate.takeIf { it > 0 }
    if (track is IMedia.VideoTrack) {
        info["width"] = track.width.takeIf { it > 0 }
        info["height"] = track.height.takeIf { it > 0 }
    }
    if (track is IMedia.AudioTrack) {
        info["channels"] = track.channels.takeIf { it > 0 }
        info["sampleRate"] = track.rate.takeIf { it > 0 }
    }
    return info
}

private fun trackTypeName(type: Int): String {
    return when (type) {
        IMedia.Track.Type.Audio -> "audio"
        IMedia.Track.Type.Video -> "video"
        IMedia.Track.Type.Text -> "subtitle"
        else -> "unknown"
    }
}
