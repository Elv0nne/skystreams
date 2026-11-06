package dev.akash.cs3engine.android.ui

import android.os.Bundle
import android.os.Looper
import androidx.fragment.app.DialogFragment
import androidx.fragment.app.FragmentFactory
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** The app's class loader: an extension's classes are its plugin's, which it can't see. */
private class WithoutExtensions(parent: ClassLoader) : ClassLoader(parent) {
    override fun loadClass(name: String, resolve: Boolean): Class<*> =
        if (name == ExtensionSettings::class.java.name) throw ClassNotFoundException(name) else super.loadClass(name, resolve)
}

/** An activity on CloudStream's MainActivity, as SkyStream's is, with the app's class loader. */
class HostActivity : com.lagradost.cloudstream3.MainActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(com.google.android.material.R.style.Theme_MaterialComponents_DayNight_NoActionBar)
        super.onCreate(savedInstanceState)
    }

    override fun getClassLoader(): ClassLoader = WithoutExtensions(super.getClassLoader())
}

/** Stands for an extension's settings screen, open when Android saved the activity. */
class ExtensionSettings : DialogFragment()

@RunWith(RobolectricTestRunner::class)
class RestoredFragmentsTest {
    @Test
    fun `fragments the app's class loader can't see come back as placeholders, the app's own as themselves`() {
        val factory = RestoredFragments(FragmentFactory())
        val loader = WithoutExtensions(javaClass.classLoader!!)
        assertIs<RestoredFragments.Gone>(factory.instantiate(loader, ExtensionSettings::class.java.name))
        assertIs<ExtensionDialog>(factory.instantiate(loader, ExtensionDialog::class.java.name))
    }

    @Test
    fun `an activity Android restores with an extension's fragment open comes back, without it`() {
        val controller = Robolectric.buildActivity(HostActivity::class.java).setup()
        val shown = controller.get().supportFragmentManager
        ExtensionSettings().show(shown, "settings")
        shown.executePendingTransactions()
        assertNotNull(shown.findFragmentByTag("settings"))
        // Don't keep activities, a configuration change it doesn't handle, or the process dying in the background.
        controller.recreate()
        shadowOf(Looper.getMainLooper()).idle()
        val fragments = controller.get().supportFragmentManager
        fragments.executePendingTransactions()
        assertNull(fragments.findFragmentByTag("settings"))
    }
}
