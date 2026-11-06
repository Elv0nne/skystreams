package dev.akash.cs3engine.jvm

import com.lagradost.cloudstream3.CloudStreamApp
import com.lagradost.cloudstream3.CommonActivity
import com.lagradost.cloudstream3.MainActivity
import dev.akash.cs3engine.Engine
import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.host.RemoteWebViewHost
import dev.akash.cs3engine.stubs.MainThread
import dev.akash.cs3engine.stubs.Platform
import dev.akash.cs3engine.stubs.Ui
import dev.akash.cs3engine.stubs.WebPages
import java.io.File

/** Builds an [Engine] for the JVM (desktop sidecar or the embedded iOS VM). */
object JvmEngine {
    fun create(dataDir: File, platform: String): Engine {
        dataDir.mkdirs()
        System.setProperty("cs3.dataDir", dataDir.absolutePath)
        // Many sites send an incomplete certificate chain (Let's Encrypt's newer hierarchy, for
        // one). Browsers and Android fetch the missing issuer from the certificate's AIA URL;
        // the JDK only does when asked. Read once, when certificate checking first runs.
        System.setProperty("com.sun.security.enableAIAcaIssuers", "true")
        val context = MainActivity()
        CloudStreamApp.installContext(context)
        // Extensions show their screens with the app's activity, as on Android.
        CommonActivity.setActivityInstance(context)
        // Converted plugins live apart from cache/, which is plugins' own Context.getCacheDir().
        File(dataDir, "cache").listFiles { file -> file.name.startsWith("d2j-v") }?.forEach { it.deleteRecursively() }
        lateinit var engine: Engine
        // Extension screens: stand-in windows, read after the main thread's tasks.
        val ui = JvmUiHost(pluginOf = { type -> engine.pluginFileOf(type) }, pluginIn = { error -> engine.pluginFileIn(error) })
        engine = Engine(JvmPluginLoader(File(dataDir, "converted")), { context }, platform, ui)
        // What Android does for extensions itself: links, shares, toasts, restarts, exits, main-thread crashes.
        val host = JvmPlatform(pluginIn = engine::pluginFileIn, notice = engine::notice)
        Platform.install(host)
        HostHooks.toast = { message -> host.toast(message) }
        Ui.setListener(ui)
        MainThread.setAfterTask(ui::afterTask)
        // Web views' pages in extension screens: the app's browser, at their nodes (part 5).
        val pages = JvmPages(locate = ui::locate, fullScreen = ui::isFullScreen, extensionOf = ui::extensionOf)
        ui.pages = pages
        WebPages.install(pages)
        RemoteWebViewHost.pageEvents = pages
        return engine
    }
}
