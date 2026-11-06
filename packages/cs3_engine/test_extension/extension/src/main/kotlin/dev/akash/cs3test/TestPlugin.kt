package dev.akash.cs3test

import android.content.Context
import androidx.appcompat.app.AppCompatActivity
import com.lagradost.cloudstream3.plugins.Plugin

/** SkyStream's own extension for tests: two providers, and a settings screen with every kind of control. */
class TestPlugin : Plugin() {
    override fun load(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        registerMainAPI(TestProvider("SkyStream Test A"))
        if (prefs.getBoolean(SECOND, true)) registerMainAPI(TestProvider("SkyStream Test B"))
        openSettings = { activity ->
            TestSettings(this).show((activity as AppCompatActivity).supportFragmentManager, "skystream-test-settings")
        }
    }

    /** One of this extension's resources, by name: extensions look theirs up so, since their R ids aren't the app's. */
    fun id(type: String, name: String): Int = resources!!.getIdentifier(name, type, PACKAGE)

    companion object {
        const val PACKAGE = "dev.akash.cs3test"
        const val PREFS = "skystream_test"
        const val SECOND = "second_provider"
    }
}
