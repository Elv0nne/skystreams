// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.plugins

import com.fasterxml.jackson.annotation.JsonProperty
import com.lagradost.cloudstream3.amap
import com.lagradost.cloudstream3.app
import com.lagradost.cloudstream3.ui.settings.extensions.RepositoryData
import com.lagradost.cloudstream3.utils.AppUtils.parseJson
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** A repository manifest (`repo.json`). */
data class Repository(
    @JsonProperty("iconUrl") val iconUrl: String?,
    @JsonProperty("name") val name: String,
    @JsonProperty("description") val description: String?,
    @JsonProperty("manifestVersion") val manifestVersion: Int,
    @JsonProperty("pluginLists") val pluginLists: List<String>,
)

/** One entry of a plugin list. Status: 0 down, 1 ok, 2 slow, 3 beta only. */
data class SitePlugin(
    @JsonProperty("url") val url: String,
    @JsonProperty("status") val status: Int,
    @JsonProperty("version") val version: Int,
    @JsonProperty("apiVersion") val apiVersion: Int,
    @JsonProperty("name") val name: String,
    @JsonProperty("internalName") val internalName: String,
    @JsonProperty("authors") val authors: List<String>,
    @JsonProperty("description") val description: String?,
    @JsonProperty("repositoryUrl") val repositoryUrl: String?,
    @JsonProperty("tvTypes") val tvTypes: List<String>?,
    @JsonProperty("language") val language: String?,
    @JsonProperty("iconUrl") val iconUrl: String?,
    @JsonProperty("fileSize") val fileSize: Long?,
    @JsonProperty("fileHash") val fileHash: String?,
)

data class PluginWrapper(
    @JsonProperty("repository") val repository: Repository,
    @JsonProperty("repositoryData") val repositoryData: RepositoryData,
    @JsonProperty("plugin") val plugin: SitePlugin,
)

/**
 * The part of CloudStream's repository manager that plugins call. The app owns the repository
 * list: the engine holds a copy ([setRepositories]) and hands on each repository a plugin adds
 * ([onAdded]). MegaRepo's plugin, for one, adds every repository in CloudStream's community list
 * each time it loads.
 */
object RepositoryManager {
    val PREBUILT_REPOSITORIES: Array<RepositoryData> = emptyArray()

    private val repositories = AtomicReference<List<RepositoryData>>(emptyList())

    /** Set by the engine: hears of each repository a plugin adds, with the stack it was added from. */
    @Volatile
    var onAdded: (repository: RepositoryData, caller: Throwable) -> Unit = { _, _ -> }

    /** Called by the engine with the app's repositories. */
    fun setRepositories(list: List<RepositoryData>) {
        repositories.set(list)
    }

    suspend fun parseRepository(url: String): Repository? = try {
        parseJson<Repository>(app.get(url, cacheTime = 5, cacheUnit = TimeUnit.MINUTES).text)
    } catch (_: Exception) {
        null
    }

    private suspend fun parsePlugins(pluginUrls: String): List<SitePlugin> = try {
        parseJson<Array<SitePlugin>>(app.get(pluginUrls, cacheTime = 5, cacheUnit = TimeUnit.MINUTES).text).toList()
    } catch (_: Exception) {
        emptyList()
    }

    /** Gets all plugins from repositories and pairs them with the repository url. */
    suspend fun getRepoPlugins(repositoryData: RepositoryData): List<PluginWrapper>? {
        val repo = parseRepository(repositoryData.url) ?: return null
        return repo.pluginLists.amap { url -> parsePlugins(url).map { PluginWrapper(repo, repositoryData, it) } }.flatten()
    }

    fun getRepositories(): Array<RepositoryData> = repositories.get().toTypedArray()

    suspend fun addRepository(repository: RepositoryData) {
        // Taken before anything suspends, while the calling plugin's frames are on the stack.
        val caller = Throwable()
        // No duplicates
        var added = false
        repositories.updateAndGet { current ->
            added = current.none { it.url == repository.url }
            if (added) current + repository else current
        }
        if (added) onAdded(repository, caller)
    }
}
