package dev.akash.cs3engine.jvm

import android.content.res.Resources
import dev.akash.cs3engine.PluginLoader
import dev.akash.cs3engine.PreparedPlugin
import dev.akash.cs3engine.stubs.FilePreferences
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/** Desktop and iOS: DEX → JVM classes, then a per-plugin class loader over the result. */
class JvmPluginLoader(private val cacheDir: File) : PluginLoader {
    // Conversions done ahead of loading, by file version, for prepare to pick up: looking one
    // up again means hashing the file.
    private val converted = ConcurrentHashMap<String, Dex2Jar.Result>()

    // The framework classes extensions mention, made once for all of them (see FrameworkClassLoader).
    private val framework = FrameworkClassLoader(javaClass.classLoader)

    override fun convert(file: File) {
        // Loads of one file at once: keep the result of the one that converted it, for its notes.
        converted.merge(version(file), Dex2Jar.convert(file, cacheDir)) { old, new -> if (old.cached) new else old }
    }

    /** The .cs3's resources.arsc and compiled XML, read by the stand-ins (the spec's "Resources"). */
    override fun resources(file: File, classLoader: ClassLoader): Resources = Resources.of(file, classLoader)

    override fun prepare(file: File): PreparedPlugin {
        val conversion = converted.remove(version(file)) ?: Dex2Jar.convert(file, cacheDir)
        return PreparedPlugin(PluginClassLoader(conversion.jar, file, framework, conversion.interfaces), conversion.notes())
    }

    override fun forget(classLoader: ClassLoader) = FilePreferences.removeListenersFrom(classLoader)

    private fun version(file: File) = "${file.absolutePath}:${file.length()}:${file.lastModified()}"
}
