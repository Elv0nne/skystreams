package dev.akash.cs3engine.android.ui

import android.os.Looper
import dev.akash.cs3engine.ui.UiSession
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.io.File
import java.time.Duration
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
class FragmentFallbackTest {
    private val controller = Robolectric.buildActivity(ThemedActivity::class.java).setup()
    private val activity = controller.get()
    private val plugin = File("/plugins/Test.cs3")
    private val published = mutableListOf<List<Map<String, Any?>>>()
    private val ended = mutableListOf<String>()
    private val session = UiSession(
        1,
        plugin,
        object : UiSession.Listener {
            override fun published(session: UiSession, windows: List<Map<String, Any?>>) {
                published += windows
            }

            override fun ended(session: UiSession, reason: String) {
                ended += reason
            }
        },
    )

    private fun idle(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))

    @Test
    fun `an open screen's dialog fragment is hidden and read from its start, once, and its end ends the screen`() = runBlocking {
        val host = AndroidUiHost(
            WindowOwners(pluginIn = { null }, pluginOf = { if (it == ExtensionDialog::class.java) plugin else null }, activity = { activity }),
        )
        host.watchFragments(activity)
        host.open(session, plugin) {}
        val fragment = ExtensionDialog()
        fragment.show(activity.supportFragmentManager, "settings")
        activity.supportFragmentManager.executePendingTransactions()
        idle(100)
        assertTrue(Hiding.isHidden(fragment.dialog!!.window!!.attributes))
        assertEquals(true, published.last().single()["hidden"])
        // The app going to the background and back starts the fragment again: it's still one window.
        controller.pause().stop()
        controller.start().resume()
        idle(100)
        assertEquals(1, published.last().size)
        fragment.dismiss()
        activity.supportFragmentManager.executePendingTransactions()
        idle(400)
        assertEquals(listOf("closed"), ended)
    }
}
