package dev.akash.cs3test

import android.app.Activity
import android.app.Dialog
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import android.widget.TextView
import com.lagradost.cloudstream3.plugins.PluginManager

/**
 * A sign-in page against the test site, as FebBox's, Cinemacity's and Kartoons' logins work (the spec's §9 tests): its
 * cookie is read once the page finishes, the Authorization header its script sends is caught in
 * shouldInterceptRequest, its script calls the extension's JavaScript interface, the extension reads the page's title
 * with evaluateJavascript, and the redirect it ends on is taken over in shouldOverrideUrlLoading. The page's user agent
 * is the extension's own.
 */
object SignIn {
    const val AGENT = "SkyStreamTest/1.0 (sign-in)"
    private val main = Handler(Looper.getMainLooper())
    private val needed = listOf("cookie", "token", "name", "title", "code", "agent")

    /** The test site: where the extension was downloaded from (the test server), or null. */
    fun site(): String? =
        PluginManager.getPluginsOnline().firstOrNull { it.internalName == "SkyStreamTest" }?.url?.substringBeforeLast('/')?.plus('/')

    /** Opens the sign-in; [status] hears its last line, "Signed in: …", once every part has come. */
    fun open(activity: Activity, prefs: SharedPreferences, status: (String) -> Unit) {
        val site = site() ?: return status("No test site")
        // A sign-in starts afresh: what an earlier one noted goes, so its line can't stand for this one.
        prefs.edit().remove("signed_in").apply()
        status("Signing in…")
        val found = linkedMapOf<String, String>()
        lateinit var dialog: Dialog
        fun note(key: String, value: String) {
            if (found.containsKey(key)) return
            found[key] = value
            if (!found.keys.containsAll(needed)) {
                // What has come so far, as it comes: a sign-in that stalls says where.
                status("Signing in… " + found.keys.joinToString(", "))
                return
            }
            val line = "Signed in: " + needed.joinToString(", ") { "$it ${found[it]}" }
            prefs.edit().putString("signed_in", line).apply()
            status(line)
            dialog.dismiss()
        }
        val page = WebView(activity).apply {
            settings.javaScriptEnabled = true
            settings.userAgentString = AGENT
            addJavascriptInterface(
                Bridge { name, agent ->
                    main.post {
                        note("name", name)
                        note("agent", if ("SkyStreamTest/1.0" in agent) "ok" else agent)
                    }
                },
                "SkyStreamTest",
            )
            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, url: String) {
                    if ("cs3test_session=signed-in" in CookieManager.getInstance().getCookie(url).orEmpty()) note("cookie", "ok")
                    view.evaluateJavascript("document.title") { title -> note("title", title.trim('"')) }
                }

                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                    val auth = request.requestHeaders.entries.firstOrNull { it.key.equals("Authorization", ignoreCase = true) }?.value
                    if (auth != null) main.post { note("token", auth.removePrefix("Bearer ")) }
                    return null
                }

                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val code = request.url.toString().substringAfter("code=", "").substringBefore('&')
                    if (code.isEmpty()) return false
                    note("code", code)
                    return true
                }
            }
        }
        dialog = Dialog(activity).apply {
            setContentView(
                LinearLayout(activity).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(TextView(activity).apply { text = "Sign in to the test site" })
                    addView(page, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 900))
                },
            )
            show()
        }
        page.loadUrl("${site}signin.html")
    }

    /** What the page's script calls: a method that returns nothing, as most extensions' are. */
    class Bridge(private val signedIn: (String, String) -> Unit) {
        @JavascriptInterface
        fun signedIn(name: String, agent: String) = signedIn.invoke(name, agent)
    }
}
