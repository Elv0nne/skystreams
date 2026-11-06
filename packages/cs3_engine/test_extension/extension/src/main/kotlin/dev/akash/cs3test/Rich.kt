package dev.akash.cs3test

import com.lagradost.cloudstream3.Actor
import com.lagradost.cloudstream3.ActorData
import com.lagradost.cloudstream3.ActorRole
import com.lagradost.cloudstream3.DubStatus
import com.lagradost.cloudstream3.LoadResponse
import com.lagradost.cloudstream3.LoadResponse.Companion.addAniListId
import com.lagradost.cloudstream3.LoadResponse.Companion.addMalId
import com.lagradost.cloudstream3.LoadResponse.Companion.addTrailer
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.NextAiring
import com.lagradost.cloudstream3.Score
import com.lagradost.cloudstream3.SeasonData
import com.lagradost.cloudstream3.ShowStatus
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.addEpisodes
import com.lagradost.cloudstream3.newAnimeLoadResponse
import com.lagradost.cloudstream3.newAnimeSearchResponse
import com.lagradost.cloudstream3.newEpisode

/** A title with everything CloudStream's details page shows, for SkyStream's details tests (CloudStream details, Part 1). */
internal object Rich {
    private const val DAY_MS = 24 * 3600 * 1000L

    suspend fun title(api: MainAPI, url: String): LoadResponse {
        val now = System.currentTimeMillis()
        val img = "${api.mainUrl}/img"
        return api.newAnimeLoadResponse("Rich Title", url, TvType.Anime) {
            plot = "A journey &amp; its end."
            posterUrl = "$img/poster.png"
            backgroundPosterUrl = "$img/back.png"
            logoUrl = "$img/logo.png"
            posterHeaders = mapOf("Referer" to "${api.mainUrl}/")
            year = 2023
            tags = listOf("Adventure", "Fantasy")
            duration = 24
            score = Score.from10(8.81)
            contentRating = "PG-13"
            showStatus = ShowStatus.Ongoing
            nextAiring = NextAiring(episode = 1, unixTime = (now + 2 * DAY_MS) / 1000, season = 2)
            seasonNames = listOf(SeasonData(1, "First Arc"), SeasonData(2, "Second Arc", 2))
            actors = listOf(
                ActorData(Actor("Frieren", "$img/frieren.png"), role = ActorRole.Main, voiceActor = Actor("Atsumi Tanezaki", "$img/va.png")),
                ActorData(Actor("Fern", "$img/fern.png"), role = ActorRole.Supporting),
                ActorData(Actor("Himmel", "$img/himmel.png"), roleString = "Hero"),
            )
            addTrailer("https://www.youtube.com/watch?v=tR8YH0G67Rk")
            recommendations = listOf(api.newAnimeSearchResponse("Rich Sequel", "${api.mainUrl}/anime/rich2"))
            addMalId(52991)
            addAniListId(154587)
            addEpisodes(
                DubStatus.Subbed,
                listOf(
                    api.newEpisode("${api.mainUrl}/play/rich/1") {
                        name = "The Journey&#39;s End"; season = 1; episode = 1
                        score = Score.from10(8.2); date = now - 30 * DAY_MS; runTime = 24
                        description = "Ten years &amp; more."
                    },
                    api.newEpisode("${api.mainUrl}/play/rich/2") {
                        name = "A Second Look"; season = 1; episode = 2
                        score = Score.from10(7.9); date = now - 23 * DAY_MS; runTime = 25
                    },
                    api.newEpisode("${api.mainUrl}/play/rich/3") {
                        name = "Next Week"; season = 2; episode = 1
                        date = now + 2 * DAY_MS; runTime = 24
                    },
                ),
            )
        }
    }
}
