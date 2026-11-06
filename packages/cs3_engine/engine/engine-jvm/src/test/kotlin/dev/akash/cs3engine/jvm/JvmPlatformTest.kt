package dev.akash.cs3engine.jvm

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.host.RestartRequested
import dev.akash.cs3engine.stubs.Exits
import dev.akash.cs3engine.stubs.Platform
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertSame
import kotlin.test.assertTrue

class JvmPlatformTest {
    private val plugin = File("/plugins/Test.cs3")
    /** The extension whose code is calling: the platform asks the engine; here, the test says. */
    private var calling: File? = plugin
    private val notices = mutableListOf<Triple<String, File?, Map<String, Any?>>>()
    private val restarts = mutableListOf<Throwable>()
    private val crashes = mutableListOf<Throwable>()
    private val context = Context()
    private val platform = JvmPlatform(pluginIn = { calling }, notice = { type, from, fields -> notices += Triple(type, from, fields) })

    @BeforeTest
    fun install() {
        Platform.install(platform)
        HostHooks.restartRequested = { restarts += it }
        HostHooks.pluginCrashed = { crashes += it }
    }

    @AfterTest
    fun uninstall() {
        Platform.install(null)
        HostHooks.restartRequested = {}
        HostHooks.pluginCrashed = {}
    }

    private fun restartIntent() =
        Intent.makeRestartActivityTask(context.packageManager.getLaunchIntentForPackage(context.packageName)!!.component)

    @Test
    fun `an extension's restart is reported and stops its code, and the engine's own is let be`() {
        val error = assertFailsWith<RestartRequested> { context.startActivity(restartIntent()) }
        assertTrue(error.reported, "told before it's thrown: an extension catching Throwable can't hide it")
        assertEquals(listOf<Throwable>(error), restarts)
        calling = null
        context.startActivity(restartIntent())
        assertEquals(1, restarts.size)
    }

    @Test
    fun `links, shares, copies and toasts go to the app, with their extension`() {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://example.com/help")))
        context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, "a token"), "Share"))
        context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("token", "abc"))
        Toast.makeText(context, "Saved", Toast.LENGTH_SHORT).show()
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=x")))
        assertEquals(
            listOf<Triple<String, File?, Map<String, Any?>>>(
                Triple("openUrl", plugin, mapOf<String, Any?>("url" to "https://example.com/help")),
                Triple("copy", plugin, mapOf<String, Any?>("text" to "a token")),
                Triple("copy", plugin, mapOf<String, Any?>("text" to "abc")),
                Triple("toast", plugin, mapOf<String, Any?>("text" to "Saved")),
            ),
            notices,
            "a store link, which nothing here opens, is only logged",
        )
    }

    @Test
    fun `an exit is a restart, and an extension's crash on the main thread ends its screen`() {
        assertFailsWith<RestartRequested> { Exits.exit(0) }
        assertEquals(1, restarts.size)
        val crash = IllegalStateException("boom")
        platform.uncaught(crash)
        assertEquals(listOf<Throwable>(crash), crashes)
        calling = null
        platform.uncaught(IllegalStateException("the engine's own"))
        assertEquals(1, crashes.size, "the engine's own failure is only logged")
        val later = RestartRequested()
        platform.uncaught(later)
        assertSame(later, restarts.last(), "a restart from a later task (an alert's button) is reported there")
    }
}
