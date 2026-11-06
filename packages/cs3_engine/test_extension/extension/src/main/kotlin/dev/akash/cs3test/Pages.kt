package dev.akash.cs3test

import android.app.Dialog
import android.os.Handler
import android.os.Looper
import android.webkit.WebView
import android.widget.LinearLayout
import android.widget.TextView
import com.lagradost.cloudstream3.CommonActivity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/** The test extension's pages outside its settings (the spec's §7 for pages). */
object Pages {
    private val main = Handler(Looper.getMainLooper())

    /** A promotion that is mostly a page, from the home page's second page, as Desi's: nothing waits on it. */
    fun promo() {
        val activity = CommonActivity.activity ?: return
        val site = SignIn.site() ?: return
        main.post {
            Dialog(activity).apply {
                setContentView(
                    LinearLayout(activity).apply {
                        orientation = LinearLayout.VERTICAL
                        // Its words title it behind Support.
                        addView(TextView(activity).apply { text = "Test promotion" })
                        addView(WebView(activity).apply { loadUrl("${site}promo.html") })
                    },
                )
                show()
            }
        }
    }

    /** A page the person waits on as a title opens, as an extension's own check: the call waits until it closes, 30 s at most. */
    suspend fun verify() {
        val activity = CommonActivity.activity ?: return
        val site = SignIn.site() ?: return
        val closed = CompletableDeferred<Unit>()
        main.post {
            Dialog(activity).apply {
                setContentView(
                    LinearLayout(activity).apply {
                        orientation = LinearLayout.VERTICAL
                        addView(TextView(activity).apply { text = "Verify you're human" })
                        addView(WebView(activity).apply { loadUrl("${site}verify.html") })
                    },
                )
                setOnDismissListener { closed.complete(Unit) }
                show()
            }
        }
        withTimeoutOrNull(30_000) { closed.await() }
    }
}
