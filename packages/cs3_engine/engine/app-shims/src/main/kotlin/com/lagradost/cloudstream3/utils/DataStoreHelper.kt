// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.utils

import com.fasterxml.jackson.annotation.JsonProperty
import com.lagradost.cloudstream3.DubStatus
import com.lagradost.cloudstream3.Score
import com.lagradost.cloudstream3.SearchQuality
import com.lagradost.cloudstream3.SearchResponse
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.ui.WatchType
import com.lagradost.cloudstream3.ui.result.VideoWatchState
import com.lagradost.cloudstream3.utils.downloader.DownloadObjects

/**
 * The app's record of a person's watching: bookmarks, favourites, subscriptions, where each video
 * was left. SkyStream keeps its own and none of CloudStream's, so plugins find what a fresh
 * CloudStream install has: nothing.
 */
object DataStoreHelper {
    /** The app's profile; SkyStream has one, CloudStream's first. */
    val currentAccount: String get() = "0"

    data class PosDur(
        @JsonProperty("position") val position: Long,
        @JsonProperty("duration") val duration: Long,
    )

    /** A bookmark, favourite or subscription. */
    abstract class LibrarySearchResponse(
        override var id: Int? = null,
        open val latestUpdatedTime: Long = 0L,
        override val name: String = "",
        override val url: String = "",
        override val apiName: String = "",
        override var type: TvType? = null,
        override var posterUrl: String? = null,
        open val year: Int? = null,
        open val syncData: Map<String, String>? = null,
        override var quality: SearchQuality? = null,
        override var posterHeaders: Map<String, String>? = null,
        open val plot: String? = null,
        override var score: Score? = null,
        open val tags: List<String>? = null,
    ) : SearchResponse

    fun getAllBookmarkedData(): List<LibrarySearchResponse> = emptyList()

    fun getAllFavorites(): List<LibrarySearchResponse> = emptyList()

    fun getAllSubscriptions(): List<LibrarySearchResponse> = emptyList()

    fun getAllResumeStateIds(): List<Int>? = emptyList()

    fun getLastWatched(id: Int?): DownloadObjects.ResumeWatching? = null

    fun getViewPos(id: Int?): PosDur? = null

    fun getVideoWatchState(id: Int?): VideoWatchState? = null

    fun getDub(id: Int): DubStatus? = null

    fun getResultWatchState(id: Int): WatchType = WatchType.NONE

    /** The season a title's page opens on; SkyStream's pages don't ask. */
    fun setResultSeason(id: Int, value: Int?) {
    }
}
