package dev.akash.cs3test

import android.app.Dialog
import android.os.Handler
import android.os.Looper
import android.webkit.WebView
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import com.lagradost.cloudstream3.CommonActivity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The test extension's own windows outside its settings, shown as real extensions show theirs: from their
 * calls, on the main thread, over the app's activity (the spec's pop-up tests).
 */
object Popups {
    private val main = Handler(Looper.getMainLooper())

    /** A support pop-up, from the home page, as StreamPlay's and HDrezka's: its first button thanks in place. */
    fun support() {
        val activity = CommonActivity.activity ?: return
        main.post {
            val message = TextView(activity).apply { text = "Keep the test extension alive." }
            lateinit var dialog: AlertDialog
            val buttons = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(Button(activity).apply {
                    text = "Count me in"
                    setOnClickListener { message.text = "Thanks!" }
                })
                addView(Button(activity).apply {
                    text = "Later"
                    setOnClickListener { dialog.dismiss() }
                })
            }
            val body = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(message)
                addView(buttons)
            }
            dialog = AlertDialog.Builder(activity).setTitle("Support SkyStream Test").setView(body).create()
            dialog.show()
        }
    }

    /** Its own bot check, with a page in it, from search, as AnimePahe's: the call waits until it closes, 20 s at most. */
    suspend fun check() {
        val activity = CommonActivity.activity ?: return
        val closed = CompletableDeferred<Unit>()
        main.post {
            Dialog(activity).apply {
                setContentView(WebView(activity))
                setOnDismissListener { closed.complete(Unit) }
                show()
            }
        }
        withTimeoutOrNull(20_000) { closed.await() }
    }

    /** A choice of server, from loadLinks: the person picks one. Null when they don't within a minute. */
    suspend fun chooseServer(): Int? {
        val activity = CommonActivity.activity ?: return null
        val chosen = CompletableDeferred<Int?>()
        main.post {
            lateinit var dialog: AlertDialog
            val body = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                for (server in 1..2) {
                    addView(Button(activity).apply {
                        text = "Server $server"
                        setOnClickListener {
                            chosen.complete(server)
                            dialog.dismiss()
                        }
                    })
                }
            }
            dialog = AlertDialog.Builder(activity)
                .setTitle("Pick a server")
                .setView(body)
                .setOnCancelListener { chosen.complete(null) }
                .create()
            dialog.show()
        }
        return withTimeoutOrNull(60_000) { chosen.await() }
    }
}
