package dev.akash.cs3engine

import android.content.Context
import android.content.res.Resources
import com.lagradost.cloudstream3.APIHolder
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.plugins.BasePlugin
import com.lagradost.cloudstream3.plugins.Plugin
import com.lagradost.cloudstream3.plugins.PluginManager
import com.lagradost.cloudstream3.utils.Event
import com.lagradost.cloudstream3.utils.extractorApis
import java.io.File
import java.util.WeakHashMap
import java.util.zip.ZipFile

/** How one platform makes a .cs3's classes loadable. */
interface PluginLoader {
    /**
     * Work done before a plugin loads, outside the engine's load lock so that plugins can do it
     * side by side: on desktop and iOS, converting its DEX code. [prepare] picks up the result.
     */
    fun convert(file: File) {}

    fun prepare(file: File): PreparedPlugin

    /**
     * The resources of [file], for a plugin whose manifest asks for them (`requiresResources`): its own
     * layouts, strings and drawables. [classLoader] is the plugin's, for the views its layouts name. Null
     * where the platform has none.
     */
    fun resources(file: File, classLoader: ClassLoader): Resources? = null

    /** Drops what the platform's stand-ins still hold of an unloaded plugin's [classLoader]. */
    fun forget(classLoader: ClassLoader) {}
}

/** [notes] carries platform details worth reporting, e.g. dex2jar conversion stats. */
class PreparedPlugin(val classLoader: ClassLoader, val notes: Map<String, Any?> = emptyMap())

class LoadedPlugin(
    val file: File,
    /** Identifies the file version that was loaded; see [PluginRegistry.fingerprint]. */
    val fingerprint: String,
    val manifest: BasePlugin.Manifest,
    val plugin: BasePlugin,
    val providers: List<MainAPI>,
    /** Link extractors it registered, which other plugins' links can come through. */
    val extractors: Int,
    val notes: Map<String, Any?>,
)

/** Loads and unloads plugins the way CloudStream's PluginManager does, on any platform. */
class PluginRegistry(private val loader: PluginLoader, private val context: () -> Context) {
    // Every plugin class loader still in memory, with its file: an unloaded plugin's threads may
    // still be running.
    private val classLoaders = WeakHashMap<ClassLoader, File>()

    /** The plugin whose code [error] passed through, if any: a crash on one of its threads. */
    fun pluginIn(error: Throwable): File? {
        val loaders = synchronized(classLoaders) { classLoaders.entries.map { it.key to it.value } }
        val seen = HashSet<Throwable>()
        var next: Throwable? = error
        while (next != null && seen.add(next)) {
            for (frame in next.stackTrace) {
                val name = frame.className
                if (HOST_PACKAGES.any { name.startsWith(it) }) continue
                for ((loader, plugin) in loaders) {
                    val owner = runCatching { Class.forName(name, false, loader).classLoader }.getOrNull()
                    if (owner === loader) return plugin
                }
            }
            next = next.cause
        }
        return null
    }

    /** The plugin whose class loader loaded [type], if any. */
    fun pluginOf(type: Class<*>): File? = synchronized(classLoaders) { classLoaders[type.classLoader] }

    /** Plugin updates are re-downloaded to the same path, so the path alone is not a version. */
    fun fingerprint(file: File): String = "${file.length()}:${file.lastModified()}"

    /** See [PluginLoader.convert]. */
    fun convert(file: File) = loader.convert(file)

    /** [url] is where the plugin was downloaded from, if known; plugins can look it up. */
    fun load(file: File, url: String?): LoadedPlugin {
        val fingerprint = fingerprint(file)
        // Read from the .cs3 itself: class-loader lookups would search the host classpath first.
        val manifest = ZipFile(file).use { zip ->
            val entry = zip.getEntry("manifest.json") ?: error("${file.name} has no manifest.json")
            zip.getInputStream(entry).use { Json.mapper.readValue(it, BasePlugin.Manifest::class.java) }
        }
        val className = manifest.pluginClassName ?: error("${file.name}: manifest.json has no pluginClassName")
        val prepared = loader.prepare(file)
        synchronized(classLoaders) { classLoaders[prepared.classLoader] = file }
        try {
            val pluginClass = try {
                prepared.classLoader.loadClass(className)
            } catch (e: ClassNotFoundException) {
                if (prepared.notes["incomplete"] != true) throw e
                throw IllegalStateException("${file.name}: its code was only partly converted ${prepared.notes}", e)
            }
            val plugin = pluginClass.getDeclaredConstructor().newInstance() as BasePlugin
            plugin.filename = file.absolutePath
            // Registered first: plugins look themselves up in PluginManager while loading.
            PluginManager.onLoaded(file, manifest.name ?: file.nameWithoutExtension, manifest.version ?: 0, plugin, url)
            // As CloudStream's PluginManager: the plugin's own resources, before it loads.
            if (manifest.requiresResources && plugin is Plugin) plugin.resources = loader.resources(file, prepared.classLoader)
            if (plugin is Plugin) plugin.load(context()) else plugin.load()
            val providers = APIHolder.allProviders.filter { it.sourcePlugin == file.absolutePath }.toList()
            val extractors = extractorApis.withLock { extractorApis.count { it.sourcePlugin == file.absolutePath } }
            return LoadedPlugin(file, fingerprint, manifest, plugin, providers, extractors, prepared.notes)
        } catch (t: Throwable) {
            // Whatever it registered before failing goes, and its classes with it.
            forget(file, prepared.classLoader)
            throw t
        }
    }

    /** Removes everything [loaded] registered, mirroring PluginManager.unloadPlugin. */
    fun unload(loaded: LoadedPlugin) {
        runCatching { loaded.plugin.beforeUnload() }
        forget(loaded.file, loaded.plugin.javaClass.classLoader)
    }

    private fun forget(file: File, classLoader: ClassLoader) {
        val path = file.absolutePath
        PluginManager.onUnloaded(file)
        APIHolder.apis.filter { it.sourcePlugin == path }.forEach { APIHolder.removePluginMapping(it) }
        APIHolder.allProviders.withLock { APIHolder.allProviders.removeAll { it.sourcePlugin == path } }
        extractorApis.withLock { extractorApis.removeAll { it.sourcePlugin == path } }
        // Listeners it left on app-wide events and preferences would keep its classes in memory.
        Event.removeObserversFrom(classLoader)
        loader.forget(classLoader)
        JacksonCaches.clear(com.lagradost.cloudstream3.mapper)
        // Desktop and iOS class loaders hold the converted jar open (a locked file on Windows).
        (classLoader as? java.io.Closeable)?.close()
    }

    private companion object {
        /** Frames from these are never plugin code, which saves class lookups. */
        val HOST_PACKAGES = listOf(
            "java.", "javax.", "jdk.", "sun.", "kotlin.", "kotlinx.", "android.", "androidx.", "com.android.",
            "dalvik.", "libcore.", "okhttp3.", "okio.", "com.fasterxml.", "org.jsoup.", "io.flutter.",
            "dev.akash.cs3engine.", "com.lagradost.nicehttp.",
        )
    }
}
