package dev.akash.cs3engine.android

import android.content.Context
import android.content.res.AssetManager
import android.content.res.Resources
import dalvik.system.PathClassLoader
import dev.akash.cs3engine.PluginLoader
import dev.akash.cs3engine.PreparedPlugin
import java.io.File

/** Android runs the plugin's DEX directly, as CloudStream does. */
class AndroidPluginLoader(private val context: Context) : PluginLoader {
    override fun prepare(file: File): PreparedPlugin {
        // Android 14+ refuses to load dex code from a writable file.
        file.setReadOnly()
        return PreparedPlugin(PathClassLoader(file.absolutePath, context.classLoader))
    }

    /**
     * As CloudStream's PluginManager: an AssetManager with the .cs3 added, wrapped in Resources with the
     * app's display and configuration. `addAssetPath` is on Android's "unsupported" hidden-API list,
     * allowed at targetSdk 37.
     */
    override fun resources(file: File, classLoader: ClassLoader): Resources {
        val assets = AssetManager::class.java.getDeclaredConstructor().newInstance()
        AssetManager::class.java.getMethod("addAssetPath", String::class.java).invoke(assets, file.absolutePath)
        @Suppress("DEPRECATION")
        return Resources(assets, context.resources.displayMetrics, context.resources.configuration)
    }
}
