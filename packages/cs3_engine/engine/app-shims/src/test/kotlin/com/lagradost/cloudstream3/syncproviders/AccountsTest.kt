package com.lagradost.cloudstream3.syncproviders

import com.lagradost.cloudstream3.CloudStreamApp
import com.lagradost.cloudstream3.TestStore
import com.lagradost.cloudstream3.syncproviders.providers.AniListApi
import com.lagradost.cloudstream3.utils.AppUtils.parseJson
import kotlinx.coroutines.runBlocking
import kotlin.coroutines.Continuation
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** CloudStream's accounts, as plugins built for the app reach them. SkyStream signs nobody in to them. */
class AccountsTest {
    @Test
    fun `a plugin reading a person's Simkl or AniList lists finds nobody signed in`() = runBlocking {
        // CineStream and TorraStream wrap these in a SyncRepo when they load.
        for (api in listOf(AccountManager.simklApi, AccountManager.aniListApi)) {
            val repo = SyncRepo(api)
            assertNull(repo.authData())
            assertNull(repo.authUser())
            val library = repo.library()
            assertTrue(library.isSuccess)
            assertNull(library.getOrNull())
            assertNull(repo.status("1").getOrThrow())
            assertNull(repo.load("1").getOrThrow())
        }
        assertEquals(SyncIdName.Simkl, SyncRepo(AccountManager.simklApi).syncIdName)
        assertEquals(SyncIdName.Anilist, SyncRepo(AccountManager.aniListApi).syncIdName)
    }

    @Test
    fun `the services are listed, none of them signed in`() {
        assertEquals(listOf("AniList", "Simkl"), AccountManager.syncApis.map { it.name })
        assertTrue(AccountManager.syncApis.all { it.authData() == null })
        assertEquals(listOf("AniList", "Simkl"), AccountManager.allApis.map { it.name })
        assertTrue(AccountManager.inAppAuths.isEmpty())
    }

    @Test
    fun `plugins call library by its compiled name`() {
        // Result is an inline class, so the compiler mangles the name plugins were built against.
        SyncRepo::class.java.getMethod("library-IoAF18A", Continuation::class.java)
    }

    @Test
    fun `a plugin built before the account rework starts on its saved account`() {
        // FStream extends InAppAuthAPIManager and calls init() while it loads.
        TestStore.install()
        val api = object : InAppAuthAPIManager(0) {
            override val idPrefix = "test_${System.nanoTime()}"

            override fun loginInfo(): AuthAPI.LoginInfo? = null
        }
        api.init()
        assertEquals(0, api.accountIndex)
        CloudStreamApp.setKey("${api.idPrefix}_active", 3)
        api.init()
        assertEquals(3, api.accountIndex)
        assertEquals("Mela", AuthAPI.LoginInfo(name = "Mela", accountIndex = 3).name)
    }

    @Test
    fun `AniList's data classes read AniList's answers`() {
        // TorraStream parses AniList's GraphQL replies into these.
        val media = parseJson<Media>(
            """{"title":{"english":"Frieren","romaji":"Sousou no Frieren"},
               "coverImage":{"medium":"m.jpg","large":"l.jpg","extraLarge":"xl.jpg"},
               "nextAiringEpisode":{"episode":12,"timeUntilAiring":60},
               "recommendations":{"edges":[{"node":{"mediaRecommendation":{"id":7,
                  "title":{"romaji":"R","english":"E","native":"N","userPreferred":"U"},
                  "coverImage":{"extraLarge":null,"large":"r.jpg","medium":null,"color":"#fff"}}}}]},
               "pageInfo":{"total":1,"currentPage":1,"lastPage":1,"perPage":20,"hasNextPage":false}}""",
        )
        assertEquals("Frieren", media.title.english)
        assertEquals("Sousou no Frieren", media.title.romaji)
        assertEquals("xl.jpg", media.coverImage.extraLarge)
        assertEquals(12, media.nextAiringEpisode.episode)
        val recommended = media.recommendations.edges.single().node.mediaRecommendation!!
        assertEquals(7, recommended.id)
        assertEquals("E", recommended.title?.english)
        assertEquals("r.jpg", recommended.coverImage?.large)
        assertEquals(false, media.pageInfo.hasNextPage)
    }

    private data class Media(
        val title: AniListApi.Title,
        val coverImage: AniListApi.CoverImage,
        val nextAiringEpisode: AniListApi.SeasonNextAiringEpisode,
        val recommendations: AniListApi.RecommendationConnection,
        val pageInfo: AniListApi.LikePageInfo,
    )
}
