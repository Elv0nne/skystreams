package dev.akash.cs3engine.android

import android.content.Context
import android.webkit.WebSettings
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

@RunWith(RobolectricTestRunner::class)
class BrowserAgentTest {
    @Test
    fun `the browser's agent is the WebView's own, as CloudStream's resolver read it`() {
        // The browser-requests review: WebViewResolver.webViewUserAgent stayed null once resolves moved to the app's
        // browser; Android's engine hands PageResolver the WebView's default agent (HostHooks.browserAgent).
        val context = ApplicationProvider.getApplicationContext<Context>()
        val agent = browserAgent(context)
        assertNotNull(agent)
        assertEquals(WebSettings.getDefaultUserAgent(context), agent)
    }
}
