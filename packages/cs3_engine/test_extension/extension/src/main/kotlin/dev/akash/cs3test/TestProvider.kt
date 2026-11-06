package dev.akash.cs3test

import com.lagradost.cloudstream3.HomePageResponse
import com.lagradost.cloudstream3.LoadResponse
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.MainPageRequest
import com.lagradost.cloudstream3.SearchResponse
import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.mainPageOf
import com.lagradost.cloudstream3.newHomePageResponse
import com.lagradost.cloudstream3.newMovieLoadResponse
import com.lagradost.cloudstream3.newMovieSearchResponse
import com.lagradost.cloudstream3.utils.ExtractorLink
import com.lagradost.cloudstream3.utils.ExtractorLinkType
import com.lagradost.cloudstream3.utils.newExtractorLink

/**
 * A provider with one film: the tests count providers, and its calls show the extension's own windows as real
 * ones do: a support pop-up from the home page, a bot check of its own from search, a choice from its links; and
 * pages: a promotion from Home's second page, and a check the person waits on as a title opens (a URL ending
 * `#verify`); a game, Play opening it full screen (Phase 7c): `/game/stuck` swallows Back, `/game/dialogs` takes its
 * page's dialogs, `/game/appdialogs` leaves them to the app; Home's fourth page, what the game's page saw; and
 * `/anime/rich`, a title with everything CloudStream's details page shows (CloudStream details, Part 1).
 */
class TestProvider(private val title: String) : MainAPI() {
    override var name = title
    override var mainUrl = "https://skystream.invalid"
    override val supportedTypes = setOf(TvType.Movie)
    override val hasMainPage = true
    override val mainPage = mainPageOf("$mainUrl/featured" to "Featured")

    override suspend fun getMainPage(page: Int, request: MainPageRequest): HomePageResponse {
        // The game's state, for the tests (Phase 7c): no window of its own.
        if (page == 3) return newHomePageResponse("Game", listOf(newMovieSearchResponse("Game: ${Game.state()}", "$mainUrl/game/1", TvType.Movie)), false)
        // What the last game's page saw (Phase 7c part 2): its file, its answers, its dialogs.
        if (page == 4) return newHomePageResponse("Report", listOf(newMovieSearchResponse("Report: ${Game.report()}", "$mainUrl/game/1", TvType.Movie)), false)
        if (page == 2) Pages.promo() else Popups.support()
        return newHomePageResponse(request.name, listOf(newMovieSearchResponse("Test Movie", "$mainUrl/movie/1", TvType.Movie)), false)
    }

    override suspend fun search(query: String): List<SearchResponse>? {
        if (query.contains("game", ignoreCase = true)) return listOf(newMovieSearchResponse("Test Game", "$mainUrl/game/1", TvType.Movie))
        Popups.check()
        return emptyList()
    }

    override suspend fun load(url: String): LoadResponse {
        if (url.endsWith("/anime/rich")) return Rich.title(this, url)
        if (url.contains("/game/")) return newMovieLoadResponse("Test Game", url, TvType.Movie, url)
        if (url.endsWith("#verify")) Pages.verify()
        return newMovieLoadResponse("Test Movie", url, TvType.Movie, "$mainUrl/play/1")
    }

    override suspend fun loadLinks(
        data: String,
        isCasting: Boolean,
        subtitleCallback: (SubtitleFile) -> Unit,
        callback: (ExtractorLink) -> Unit,
    ): Boolean {
        if (data.contains("/game/")) {
            val dialogs = when {
                data.endsWith("/appdialogs") -> Game.Dialogs.LEFT
                data.endsWith("/dialogs") -> Game.Dialogs.TAKEN
                else -> Game.Dialogs.NONE
            }
            Game.play(stuck = data.endsWith("/stuck"), dialogs = dialogs)
            return false
        }
        val server = Popups.chooseServer() ?: return false
        callback(newExtractorLink(name, "Server $server", "$mainUrl/video/server-$server.m3u8", ExtractorLinkType.M3U8))
        return true
    }
}
