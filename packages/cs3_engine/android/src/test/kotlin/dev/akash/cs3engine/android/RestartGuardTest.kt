package dev.akash.cs3engine.android

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.test.core.app.ApplicationProvider
import com.lagradost.cloudstream3.MainActivity
import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.host.RestartRequested
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** The CloudStream activity SkyStream's extends, themed. */
class GuardedActivity : MainActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(com.google.android.material.R.style.Theme_MaterialComponents_DayNight_NoActionBar)
        super.onCreate(savedInstanceState)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(application = ExtensionHostApplication::class)
class RestartGuardTest {
    private val app: Application = ApplicationProvider.getApplicationContext()

    private fun restart(context: Context) =
        Intent.makeRestartActivityTask(ComponentName(context.packageName, "dev.akash.skystream.MainActivity"))

    @After
    fun reset() = RestartGuard.reset()

    @Test
    fun `a restart is the app's own component as a new task clearing the old one`() {
        assertTrue(RestartGuard.isRestart(app, restart(app)))
        assertFalse(RestartGuard.isRestart(app, Intent(Intent.ACTION_VIEW, Uri.parse("https://example.invalid"))))
        assertFalse(RestartGuard.isRestart(app, Intent.makeRestartActivityTask(ComponentName("other.app", "Main"))))
    }

    @Test
    fun `an extension's restart through the application context stops before its exit`() {
        RestartGuard.start(extensionCalling = { true })
        assertFailsWith<RestartRequested> { app.startActivity(restart(app)) }
        assertFailsWith<RestartRequested> { app.startActivity(restart(app), null) }
    }

    @Test
    fun `a restart an extension swallows is still heard, once, before its error is thrown`() {
        val heard = mutableListOf<Throwable>()
        HostHooks.restartRequested = { heard += it }
        try {
            RestartGuard.start(extensionCalling = { true })
            // As NetNaija's restart does: its catch of Throwable takes the error, and its exit never runs.
            val swallowed = runCatching { app.startActivity(restart(app)) }.exceptionOrNull()
            assertIs<RestartRequested>(swallowed)
            assertTrue(swallowed.reported)
            assertSame(swallowed, heard.single())
        } finally {
            HostHooks.restartRequested = {}
        }
    }

    @Test
    fun `the app's own restart, and an extension's other intents, go through`() {
        RestartGuard.start(extensionCalling = { false })
        app.startActivity(restart(app))
        RestartGuard.start(extensionCalling = { true })
        app.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://example.invalid")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        assertEquals(2, generateSequence { shadowOf(app).nextStartedActivity }.count())
    }

    @Test
    fun `an extension's restart through the activity stops too`() {
        val activity = Robolectric.buildActivity(GuardedActivity::class.java).setup().get()
        RestartGuard.start(extensionCalling = { true })
        assertFailsWith<RestartRequested> { activity.startActivity(restart(activity)) }
    }

    @Test
    fun `an extension casting its context to Application gets the real one, and a restart through it stops`() {
        val activity = Robolectric.buildActivity(GuardedActivity::class.java).setup().get()
        RestartGuard.start(extensionCalling = { true })
        val context = activity.applicationContext
        assertIs<Application>(context, "extensions cast it (a file picker's does)")
        assertFailsWith<RestartRequested> { context.startActivity(restart(activity)) }
        assertFailsWith<RestartRequested> { activity.application.startActivity(restart(activity)) }
    }
}
