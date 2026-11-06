// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.plugins

import android.content.Context
import com.fasterxml.jackson.annotation.JsonProperty
import dev.akash.cs3engine.host.HostHooks
import java.io.File
import java.util.concurrent.ConcurrentHashMap

data class PluginData(
    @JsonProperty("internalName") val internalName: String,
    @JsonProperty("url") val url: String?,
    @JsonProperty("isOnline") val isOnline: Boolean,
    @JsonProperty("filePath") val filePath: String,
    @JsonProperty("version") val version: Int,
)

/**
 * The part of CloudStream's plugin manager that plugins call: mostly to find their own file.
 * The engine owns loading, so requests to load or unload plugins are declined.
 */
object PluginManager {
    private val loaded = ConcurrentHashMap<String, Pair<PluginData, BasePlugin>>()

    /**
     * Called by the engine as plugins come and go. [url] is where the plugin was downloaded from;
     * without one it counts as a local plugin, as a file the app was handed does upstream.
     */
    fun onLoaded(file: File, internalName: String, version: Int, plugin: BasePlugin, url: String?) {
        loaded[file.absolutePath] = PluginData(internalName, url, url != null, file.absolutePath, version) to plugin
    }

    fun onUnloaded(file: File) {
        loaded.remove(file.absolutePath)
    }

    val plugins: Map<String, BasePlugin> get() = loaded.mapValues { it.value.second }

    fun getPluginsOnline(): Array<PluginData> = loaded.values.map { it.first }.filter { it.isOnline }.toTypedArray()

    fun getPluginsLocal(): Array<PluginData> = loaded.values.map { it.first }.filterNot { it.isOnline }.toTypedArray()

    fun getPluginPath(context: Context, internalName: String, repositoryUrl: String): File =
        File(loaded.values.firstOrNull { it.first.internalName == internalName }?.first?.filePath ?: internalName)

    fun unloadPlugin(absolutePath: String) {
        HostHooks.log("a plugin asked to unload $absolutePath; the app decides that, so it stays loaded")
    }

    suspend fun loadSinglePlugin(context: Context, apiName: String): Boolean = false
}
