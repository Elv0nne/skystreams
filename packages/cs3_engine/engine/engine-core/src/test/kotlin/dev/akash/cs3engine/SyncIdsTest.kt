package dev.akash.cs3engine

import android.content.Context
import com.lagradost.cloudstream3.LoadResponse.Companion.addAniListId
import com.lagradost.cloudstream3.LoadResponse.Companion.addImdbId
import com.lagradost.cloudstream3.LoadResponse.Companion.addMalId
import com.lagradost.cloudstream3.LoadResponse.Companion.addTMDbId
import com.lagradost.cloudstream3.LoadResponse.Companion.getAniListId
import com.lagradost.cloudstream3.LoadResponse.Companion.getImdbId
import com.lagradost.cloudstream3.LoadResponse.Companion.getMalId
import com.lagradost.cloudstream3.LoadResponse.Companion.getTMDbId
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.newAnimeLoadResponse
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The engine names CloudStream's id keys at start-up, as CloudStream's app does. With the library's empty defaults
 * every addMalId/addAniListId/addImdbId/addTMDbId wrote the one key "" and each overwrote the last: AnimeWorld's
 * Frieren arrived as {"": "{\"AniList\":\"154587\"}"}, its MAL id lost (measured 2026-10-11).
 */
class SyncIdsTest {
    private object NoPlugins : PluginLoader {
        override fun prepare(file: File) = PreparedPlugin(SyncIdsTest::class.java.classLoader)
    }

    private val api = object : MainAPI() {
        override var name = "Test"
        override var mainUrl = "https://test.example"
    }

    @Test
    fun `a title's ids keep their own keys once the engine has started`() = runBlocking {
        Engine(NoPlugins, { Context() }, "test")
        val response = api.newAnimeLoadResponse("Frieren", "https://test.example/frieren", TvType.Anime) {
            addMalId(52991)
            addAniListId(154587)
            addImdbId("tt22248376")
            addTMDbId("209867")
        }
        assertEquals("52991", response.getMalId())
        assertEquals("154587", response.getAniListId())
        assertEquals("tt22248376", response.getImdbId())
        assertEquals("209867", response.getTMDbId())
        Unit
    }
}
