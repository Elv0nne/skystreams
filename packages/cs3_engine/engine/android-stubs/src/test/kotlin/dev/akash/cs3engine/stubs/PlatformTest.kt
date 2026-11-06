package dev.akash.cs3engine.stubs

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class PlatformTest {
    private val platform = RecordingPlatform()

    @BeforeTest
    fun install() = Platform.install(platform)

    @AfterTest
    fun uninstall() = Platform.install(null)

    @Test
    fun `a context's starts go to the platform, through a wrapper too`() {
        val context = Context()
        val link = Intent(Intent.ACTION_VIEW, Uri.parse("https://example.com/a"))
        context.startActivity(link)
        ContextWrapper(context).startActivity(link, Bundle())
        assertEquals(listOf(link, link), platform.started)
    }

    @Test
    fun `the app's restart is its launch intent as a new task that clears the old one`() {
        val context = Context()
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)!!
        assertTrue(Intent.CATEGORY_LAUNCHER in launch.categories)
        val restart = Intent.makeRestartActivityTask(launch.component)
        assertEquals(context.packageName, restart.component!!.packageName)
        assertEquals(Intent.ACTION_MAIN, restart.action)
        assertEquals(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK, restart.flags)
        assertNull(context.packageManager.getLaunchIntentForPackage("com.other.app"), "only the engine's package is installed")
    }

    @Test
    fun `toasts and the clipboard reach the platform`() {
        val context = Context()
        Toast.makeText(context, "Saved", Toast.LENGTH_SHORT).show()
        assertEquals(listOf("Saved"), platform.toasts)
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        assertSame(clipboard, context.getSystemService(ClipboardManager::class.java))
        clipboard.setPrimaryClip(ClipData.newPlainText("token", "abc123"))
        assertEquals(listOf("abc123"), platform.copies)
        assertEquals("abc123", clipboard.primaryClip!!.getItemAt(0).text)
        assertTrue(clipboard.hasPrimaryClip())
    }

    @Test
    fun `an exit stops the code that asked for it, and the platform hears it`() {
        assertFailsWith<RecordingPlatform.ExitStopped> { Exits.exit(0) }
        assertFailsWith<RecordingPlatform.ExitStopped> { Exits.exit(Runtime.getRuntime(), 3) }
        assertFailsWith<RecordingPlatform.ExitStopped> { Exits.halt(Runtime.getRuntime(), 4) }
        assertFailsWith<RecordingPlatform.ExitStopped> { Exits.killProcess(1234) }
        assertFailsWith<RecordingPlatform.ExitStopped> { Exits.exitProcess(5) }
        assertEquals(listOf(0, 3, 4, 0, 5), platform.exits)
    }

    @Test
    fun `without an engine an exit still stops the code`() {
        Platform.install(null)
        assertFailsWith<IllegalStateException> { Exits.exit(0) }
    }

    @Test
    fun `a main-thread task that throws reaches the platform, and the main thread runs on`() {
        MainThread.post { throw IllegalStateException("boom") }
        drainMain()
        assertEquals("boom", platform.uncaught.single().message)
        assertEquals(2, onMain { 1 + 1 })
    }

    @Test
    fun `the after-task hook runs after every main-thread task`() {
        val after = AtomicInteger()
        MainThread.setAfterTask { after.incrementAndGet() }
        try {
            repeat(3) { MainThread.post {} }
            // Two rounds: a drain returns from inside its task, before that task's hook has run.
            drainMain(2)
            assertTrue(after.get() >= 4, "three tasks and the first drain's own")
        } finally {
            MainThread.setAfterTask(null)
        }
    }

    @Test
    fun `bundles keep typed values, with defaults for missing and mismatched ones`() {
        val bundle = Bundle()
        bundle.putString("name", "CNC")
        bundle.putInt("count", 3)
        bundle.putBoolean("on", true)
        bundle.putStringArrayList("list", arrayListOf("a", "b"))
        assertEquals("CNC", bundle.getString("name"))
        assertEquals("fallback", bundle.getString("missing", "fallback"))
        assertEquals(3, bundle.getInt("count"))
        assertEquals(7, bundle.getInt("name", 7), "a string isn't an int: the default, as on Android")
        assertTrue(bundle.getBoolean("on"))
        assertEquals(listOf("a", "b"), bundle.getStringArrayList("list"))
        val copy = Bundle(bundle)
        copy.putString("name", "other")
        assertEquals("CNC", bundle.getString("name"), "a copy is apart")
        assertEquals(setOf("name", "count", "on", "list"), bundle.keySet())
    }

    @Test
    fun `intents carry their data and extras, and a chooser wraps its target`() {
        val target = Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, "a link").setType("text/plain")
        assertEquals("a link", target.getStringExtra(Intent.EXTRA_TEXT))
        assertEquals(5, target.getIntExtra("missing", 5))
        val chooser = Intent.createChooser(target, "Share")
        assertEquals(Intent.ACTION_CHOOSER, chooser.action)
        assertSame(target, chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT))
        val view = Intent(Intent.ACTION_VIEW, Uri.parse("https://example.com/watch?v=1"))
        assertEquals("https://example.com/watch?v=1", view.dataString)
        val copy = Intent(view).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        assertEquals(0, view.flags, "a copy is apart")
        assertEquals(Intent.FLAG_ACTIVITY_NEW_TASK, copy.flags)
    }

    @Test
    fun `the engine's own package is installed, and no other`() {
        val packages = Context().packageManager
        val own = packages.getPackageInfo(StubEnv.packageName(), 0)
        assertEquals(StubEnv.packageName(), own.packageName)
        assertEquals(StubEnv.packageName(), packages.getApplicationInfo(StubEnv.packageName(), 0).packageName)
        assertFailsWith<PackageManager.NameNotFoundException> { packages.getPackageInfo("com.other.app", 0) }
    }

    @Test
    fun `a context's folders are the engine's own, never null`() {
        // StreamCenter and AfterDark write under getExternalFilesDir and getDataDir: a null there made the file
        // relative to the engine's working directory.
        val context = ContextWrapper(Context())
        val root = StubEnv.root().canonicalPath
        val folders = listOf(
            context.dataDir, context.noBackupFilesDir, context.codeCacheDir, context.externalCacheDir, context.obbDir,
            context.getExternalFilesDir(null), context.getExternalFilesDir("Download"),
            context.getDatabasePath("cache.db"), context.getFileStreamPath("state.json"),
        ) + context.getExternalFilesDirs(null).toList() + context.externalCacheDirs.toList()
        for (folder in folders) assertTrue(folder.canonicalPath.startsWith(root), "$folder is the engine's")
        assertEquals("Download", context.getExternalFilesDir("Download")!!.name)
    }

    @Test
    fun `the app's label is SkyStream, as Android's manifest gives it, and a label is never null`() {
        val context = Context()
        val info = context.applicationInfo
        assertEquals("SkyStream", info.loadLabel(context.packageManager).toString())
        assertEquals("SkyStream", context.packageManager.getApplicationLabel(info).toString())
        // Without a label, Android's order: the class name, then the package.
        val bare = ApplicationInfo().apply { packageName = "a.b" }
        assertEquals("a.b", bare.loadLabel(context.packageManager).toString())
        bare.name = "a.b.App"
        assertEquals("a.b.App", bare.loadLabel(context.packageManager).toString())
    }
}
