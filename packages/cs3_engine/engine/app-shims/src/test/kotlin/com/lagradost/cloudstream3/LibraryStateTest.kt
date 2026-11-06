package com.lagradost.cloudstream3

import android.content.Context
import com.lagradost.cloudstream3.ui.SyncWatchType
import com.lagradost.cloudstream3.ui.WatchType
import com.lagradost.cloudstream3.ui.player.source_priority.QualityDataHelper
import com.lagradost.cloudstream3.ui.result.VideoWatchState
import com.lagradost.cloudstream3.ui.result.getId
import com.lagradost.cloudstream3.utils.DataStoreHelper
import com.lagradost.cloudstream3.utils.Qualities
import com.lagradost.cloudstream3.utils.UiText
import com.lagradost.cloudstream3.utils.txt
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** What CloudStream keeps about a person's watching, as plugins read it. SkyStream keeps none of it. */
class LibraryStateTest {
    @Test
    fun `watch states keep CloudStream's order and ids`() {
        // A `when` over these in a plugin reads every constant the first time it runs.
        assertEquals(
            listOf("NONE", "WATCHING", "COMPLETED", "ONHOLD", "DROPPED", "PLANTOWATCH", "REWATCHING"),
            SyncWatchType.values().map { it.name },
        )
        assertEquals(listOf(-1, 0, 1, 2, 3, 4, 5), SyncWatchType.values().map { it.internalId })
        assertEquals(SyncWatchType.NONE, SyncWatchType.fromInternalId(42))
        assertEquals(
            listOf("WATCHING", "COMPLETED", "ONHOLD", "DROPPED", "PLANTOWATCH", "NONE"),
            WatchType.values().map { it.name },
        )
        assertEquals(WatchType.PLANTOWATCH, WatchType.fromInternalId(4))
        assertEquals(listOf("None", "Watched"), VideoWatchState.values().map { it.name })
    }

    @Test
    fun `nothing is bookmarked, resumed or watched`() {
        assertEquals("0", DataStoreHelper.currentAccount)
        assertTrue(DataStoreHelper.getAllBookmarkedData().isEmpty())
        assertTrue(DataStoreHelper.getAllFavorites().isEmpty())
        assertTrue(DataStoreHelper.getAllSubscriptions().isEmpty())
        assertEquals(emptyList(), DataStoreHelper.getAllResumeStateIds())
        assertNull(DataStoreHelper.getLastWatched(1))
        assertNull(DataStoreHelper.getViewPos(1))
        assertNull(DataStoreHelper.getVideoWatchState(1))
        assertNull(DataStoreHelper.getDub(1))
        assertEquals(WatchType.NONE, DataStoreHelper.getResultWatchState(1))
        DataStoreHelper.setResultSeason(1, 2)
        // Plugins call the getter of CloudStream's `currentAccount` property.
        assertEquals(String::class.java, DataStoreHelper::class.java.getMethod("getCurrentAccount").returnType)
    }

    @Test
    fun `a result's id is CloudStream's, its address without its site hashed`() = runBlocking {
        val provider = object : MainAPI() {
            override var name = "Not registered"
            override var mainUrl = "https://site.example"
        }
        val response = provider.newMovieLoadResponse("A film", "https://site.example/film/1", TvType.Movie, "1")
        // Its provider isn't registered, so there is no site to take off.
        assertEquals("https:site.examplefilm1".hashCode(), response.getId())
    }

    @Test
    fun `source priorities a plugin sets stay with their profile`() {
        TestStore.install()
        val source = "source ${System.nanoTime()}"
        assertEquals(1, QualityDataHelper.getSourcePriority(1, source))
        QualityDataHelper.setSourcePriority(1, source, 7)
        assertEquals(7, QualityDataHelper.getSourcePriority(1, source))
        assertEquals(1, QualityDataHelper.getSourcePriority(2, source))
        QualityDataHelper.setSourcePriority(1, source, 1)
        assertEquals(1, QualityDataHelper.getSourcePriority(1, source))
        assertEquals(Qualities.P1080.defaultPriority, QualityDataHelper.getQualityPriority(1, Qualities.P1080))
        assertEquals((1..7).toList(), QualityDataHelper.getProfiles().map { it.id })
    }

    @Test
    fun `text a plugin makes reads back as it was written`() {
        val text: UiText = txt("Continue watching")
        assertEquals("Continue watching", text.asString(Context()))
        assertNull(txt(null as String?))
    }
}
