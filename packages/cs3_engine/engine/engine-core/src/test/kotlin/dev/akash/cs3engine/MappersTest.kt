package dev.akash.cs3engine

import com.lagradost.cloudstream3.Actor
import com.lagradost.cloudstream3.ActorData
import com.lagradost.cloudstream3.ActorRole
import com.lagradost.cloudstream3.DubStatus
import com.lagradost.cloudstream3.LoadResponse.Companion.addAniListId
import com.lagradost.cloudstream3.LoadResponse.Companion.addImdbId
import com.lagradost.cloudstream3.LoadResponse.Companion.addMalId
import com.lagradost.cloudstream3.LoadResponse.Companion.addTMDbId
import com.lagradost.cloudstream3.LoadResponse.Companion.addTrailer
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.NextAiring
import com.lagradost.cloudstream3.Score
import com.lagradost.cloudstream3.SearchQuality
import com.lagradost.cloudstream3.SeasonData
import com.lagradost.cloudstream3.ShowStatus
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.addEpisodes
import com.lagradost.cloudstream3.newAnimeLoadResponse
import com.lagradost.cloudstream3.newAnimeSearchResponse
import com.lagradost.cloudstream3.newEpisode
import com.lagradost.cloudstream3.newMovieLoadResponse
import com.lagradost.cloudstream3.newTvSeriesLoadResponse
import kotlinx.coroutines.runBlocking
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

/** What `load` sends: every field CloudStream's details page shows (CloudStream details, Part 1). */
class MappersTest {
    private val api = object : MainAPI() {
        override var name = "Test"
        override var mainUrl = "https://test.example"
    }

    @BeforeTest
    fun keys() = Mappers.nameSyncKeys()

    @Test
    fun `an anime title sends what CloudStream's page shows`() = runBlocking {
        val response = api.newAnimeLoadResponse("Frieren", "https://test.example/frieren", TvType.Anime) {
            score = Score.from10(8.81)
            contentRating = "PG-13"
            logoUrl = "https://img.test/logo.png"
            posterHeaders = mapOf("Referer" to "https://test.example/")
            actors = listOf(
                ActorData(
                    Actor("Frieren", "https://img.test/frieren.jpg"),
                    role = ActorRole.Main,
                    voiceActor = Actor("Atsumi Tanezaki", "https://img.test/va.jpg"),
                ),
                ActorData(Actor("Himmel"), roleString = "Hero"),
            )
            addTrailer("https://www.youtube.com/embed/tR8YH0G67Rk", referer = "https://test.example/")
            recommendations = listOf(
                api.newAnimeSearchResponse("Dungeon Meshi", "https://test.example/meshi") {
                    score = Score.from10(8.0)
                    quality = SearchQuality.HD
                },
            )
            showStatus = ShowStatus.Ongoing
            nextAiring = NextAiring(episode = 29, unixTime = 1_900_000_000L, season = 2)
            seasonNames = listOf(SeasonData(1, "First Arc"), SeasonData(2, "Second Arc", 2))
            addMalId(52991)
            addAniListId(154587)
            addEpisodes(
                DubStatus.Subbed,
                listOf(
                    api.newEpisode("https://test.example/frieren/1") {
                        name = "The Journey's End"
                        season = 1
                        episode = 1
                        score = Score.from10(8.2)
                        date = 1_736_002_800_000L
                        runTime = 24
                    },
                ),
            )
        }
        val out = Mappers.loadResponse(response)

        assertEquals(8.81, out["score"] as Double, 1e-9)
        assertEquals("PG-13", out["contentRating"])
        assertEquals("https://img.test/logo.png", out["logoUrl"])
        assertEquals(mapOf("Referer" to "https://test.example/"), out["posterHeaders"])
        assertEquals(false, out["comingSoon"])
        assertEquals(
            listOf(
                mapOf(
                    "name" to "Frieren",
                    "image" to "https://img.test/frieren.jpg",
                    "role" to "Main",
                    "roleString" to null,
                    "voiceActor" to mapOf("name" to "Atsumi Tanezaki", "image" to "https://img.test/va.jpg"),
                ),
                mapOf("name" to "Himmel", "image" to null, "role" to null, "roleString" to "Hero", "voiceActor" to null),
            ),
            out["actors"],
        )
        assertEquals(
            listOf(
                mapOf(
                    "url" to "https://www.youtube.com/embed/tR8YH0G67Rk",
                    "referer" to "https://test.example/",
                    "raw" to false,
                    "headers" to emptyMap<String, String>(),
                ),
            ),
            out["trailers"],
        )
        val rec = (out["recommendations"] as List<*>).single() as Map<*, *>
        assertEquals("Dungeon Meshi", rec["name"])
        assertEquals("Test", rec["apiName"])
        assertEquals(8.0, rec["score"] as Double, 1e-9)
        assertEquals("HD", rec["quality"])
        assertEquals("Ongoing", out["showStatus"])
        // Typed: with one Long among them, Kotlin would make the other literals Longs too.
        assertEquals(mapOf<String, Any?>("episode" to 29, "unixTime" to 1_900_000_000L, "season" to 2), out["nextAiring"])
        assertEquals(
            listOf(
                mapOf("season" to 1, "name" to "First Arc", "displaySeason" to null),
                mapOf("season" to 2, "name" to "Second Arc", "displaySeason" to 2),
            ),
            out["seasonNames"],
        )
        assertEquals(mapOf("mal" to "52991", "anilist" to "154587"), out["syncIds"])
        val episode = (out["episodes"] as List<*>).single() as Map<*, *>
        assertEquals(8.2, episode["score"] as Double, 1e-9)
        assertEquals(1_736_002_800_000L, episode["date"])
        assertEquals(24, episode["runTime"])
        Unit
    }

    @Test
    fun `a score under 0_1 is none, and a film sends no show fields`() = runBlocking {
        val film = api.newMovieLoadResponse("Film", "https://test.example/film", TvType.Movie, "https://test.example/play") {
            score = Score.from10(0.05)
        }
        val out = Mappers.loadResponse(film)
        assertNull(out["score"])
        assertFalse(out.containsKey("showStatus"))
        assertFalse(out.containsKey("nextAiring"))
        assertEquals(emptyList<Any>(), out["trailers"])
        assertNull(out["actors"])
        assertEquals(emptyMap<String, String>(), out["syncIds"])
        Unit
    }

    @Test
    fun `a series with no episodes is coming soon`() = runBlocking {
        val series = api.newTvSeriesLoadResponse("Soon", "https://test.example/soon", TvType.TvSeries, emptyList())
        assertEquals(true, Mappers.loadResponse(series)["comingSoon"])
        Unit
    }

    @Test
    fun `ids filed in CloudStream's Simkl bundle come out under their own keys`() = runBlocking {
        val film = api.newMovieLoadResponse("Film", "https://test.example/film", TvType.Movie, "https://test.example/play") {
            addImdbId("tt0133093")
            addTMDbId("603")
        }
        assertEquals(mapOf("imdb" to "tt0133093", "tmdb" to "603"), Mappers.loadResponse(film)["syncIds"])
        Unit
    }

    @Test
    fun `a search result names the extension that answered`() {
        val item = api.newAnimeSearchResponse("Frieren", "https://test.example/frieren") { score = Score.from10(9.0) }
        val out = Mappers.searchItem(item)
        assertEquals("Test", out["apiName"])
        assertEquals(9.0, out["score"] as Double, 1e-9)
    }
}
