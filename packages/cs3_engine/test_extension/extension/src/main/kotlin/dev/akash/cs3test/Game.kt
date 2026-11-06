package dev.akash.cs3test

import android.app.Dialog
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.ActivityInfo
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.JavascriptInterface
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.widget.FrameLayout
import android.widget.Toast
import com.lagradost.cloudstream3.CommonActivity
import kotlinx.coroutines.CompletableDeferred
import java.io.File

/**
 * A game, made as Ayu's are (Phase 7c's tests). Play:
 * - writes its page, and a 1 MB file beside it, into the extension's own files;
 * - opens a full-screen dialog holding a page that loads them, file access on;
 * - turns the activity to landscape, and keeps the screen on;
 * - waits until the dialog closes, with no timeout of its own.
 *
 * The page reads the file, calls its interface's answering and one-way methods, and opens an alert, a confirm and a
 * prompt. It then reports what it saw: [report], which Home's fourth page reads.
 *
 * Back once says "Press back again to save & exit"; twice within 2.5 s saves and closes the game 250 ms later. The
 * page's EXIT GAME button calls `closeGame`, which saves and closes it too.
 *
 * A stuck game's key listener swallows every Back, for SkyStream's escape. Who takes the page's dialogs is [Dialogs]'s:
 * by default no chrome client (the page gets cancel). What happened is kept in [STATE], which Home's third page reads
 * ([state]).
 */
object Game {
    const val STATE = "game_state"
    const val REPORT = "game_report"
    private const val SAVED = "game_saved"
    private const val DATA_SIZE = 1_048_576

    /** What the page's `name()` answers: a non-ASCII letter, an emoji and a NUL, which no answer may lose. */
    private const val NAME = "Test Game ü 🎮\u0000!"
    private val main = Handler(Looper.getMainLooper())

    /** What the last game did, for the tests: none, playing, saved by back, saved by its exit, closed. */
    fun state(): String = prefs()?.getString(STATE, null) ?: "none"

    /** What the last game's page saw, as JSON: none until it reports. */
    fun report(): String = prefs()?.getString(REPORT, null) ?: "none"

    private fun prefs(): SharedPreferences? = CommonActivity.activity?.getSharedPreferences(TestPlugin.PREFS, Context.MODE_PRIVATE)

    /**
     * Who takes the page's dialogs: no chrome client, so the page gets cancel ([NONE]); [Chrome], which takes them
     * ([TAKEN], the dialogs title); or a plain chrome client, which leaves them to the app ([LEFT], the app dialogs
     * title): Android's WebView shows its own, SkyStream its own off Android.
     */
    enum class Dialogs { NONE, TAKEN, LEFT }

    suspend fun play(stuck: Boolean, dialogs: Dialogs = Dialogs.NONE) {
        val activity = CommonActivity.activity ?: return
        val prefs = activity.getSharedPreferences(TestPlugin.PREFS, Context.MODE_PRIVATE)
        // Its page and a 1 MB file beside it, in the extension's own files, as Ayu's games unpack theirs.
        val folder = File(activity.filesDir, "cs3test-game").apply { mkdirs() }
        File(folder, "index.html").writeText(PAGE)
        File(folder, "data.bin").writeBytes(ByteArray(DATA_SIZE) { (it % 251).toByte() })
        prefs.edit().remove(REPORT).apply()
        val closed = CompletableDeferred<Unit>()
        main.post {
            val before = activity.requestedOrientation
            activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            val dialog = Dialog(activity, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
            dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or WindowManager.LayoutParams.FLAG_FULLSCREEN)
            val page = WebView(activity).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.allowFileAccess = true
                // Android: a file page's XHR of the file beside it, as Ayu's games ask for.
                @Suppress("DEPRECATION")
                settings.setAllowFileAccessFromFileURLs(true)
                addJavascriptInterface(Bridge(dialog, prefs), "TestGame")
                when (dialogs) {
                    Dialogs.NONE -> {}
                    Dialogs.TAKEN -> webChromeClient = Chrome()
                    Dialogs.LEFT -> webChromeClient = WebChromeClient()
                }
                // As Ayu's launchers make it: a desktop's path goes in as it is (file://C:\… on Windows).
                loadUrl("file://" + File(folder, "index.html").absolutePath + "?game=test")
            }
            dialog.setContentView(
                FrameLayout(activity).apply { addView(page, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT) },
            )
            var firstBack = 0L
            dialog.setOnKeyListener { _, code, event ->
                if (code != KeyEvent.KEYCODE_BACK) return@setOnKeyListener false
                // It takes Back's down and up, and acts on the up, as Ayu's Pokémon does.
                if (stuck || event.action != KeyEvent.ACTION_UP) return@setOnKeyListener true
                val now = System.currentTimeMillis()
                if (now - firstBack < 2_500) {
                    prefs.edit().putString(STATE, "saved by back").apply()
                    main.postDelayed({ dialog.dismiss() }, 250)
                } else {
                    firstBack = now
                    Toast.makeText(activity, "Press back again to save & exit", Toast.LENGTH_SHORT).show()
                }
                true
            }
            dialog.setOnDismissListener {
                activity.requestedOrientation = before
                if (prefs.getString(STATE, null) == "playing") prefs.edit().putString(STATE, "closed").apply()
                page.destroy()
                closed.complete(Unit)
            }
            prefs.edit().putString(STATE, "playing").apply()
            dialog.show()
        }
        closed.await()
    }

    /** The page's interface: EXIT GAME and saves one way, and the values its page asks for. Public: the JVM engine calls it by reflection. */
    class Bridge(private val dialog: Dialog, private val prefs: SharedPreferences) {
        @JavascriptInterface
        fun closeGame() {
            prefs.edit().putString(STATE, "saved by its exit").apply()
            main.post { dialog.dismiss() }
        }

        @JavascriptInterface
        fun saveState(state: String) {
            prefs.edit().putString(SAVED, state).apply()
        }

        @JavascriptInterface
        fun loadState(): String = prefs.getString(SAVED, null) ?: ""

        @JavascriptInterface
        fun report(json: String) {
            prefs.edit().putString(REPORT, json).apply()
        }

        @JavascriptInterface
        fun isReady(): Boolean = true

        @JavascriptInterface
        fun name(): String = NAME

        @JavascriptInterface
        fun level(): Int = 42

        @JavascriptInterface
        fun half(): Double = 2.5

        @JavascriptInterface
        fun big(): String = "x".repeat(DATA_SIZE)

        @JavascriptInterface
        fun broken(): String = throw IllegalStateException("broken on purpose")

        @JavascriptInterface
        fun nothing(): String? = null
    }

    /** Takes the page's dialogs (the dialogs title): the alert and the confirm at once, the prompt a moment later. */
    private class Chrome : WebChromeClient() {
        @Volatile private var heard = ""

        override fun onJsAlert(view: WebView, url: String, message: String, result: JsResult): Boolean {
            heard = message
            result.confirm()
            return true
        }

        override fun onJsConfirm(view: WebView, url: String, message: String, result: JsResult): Boolean {
            result.confirm()
            return true
        }

        override fun onJsPrompt(view: WebView, url: String, message: String, defaultValue: String?, result: JsPromptResult): Boolean {
            main.postDelayed({ result.confirm("heard: $heard") }, 300)
            return true
        }
    }

    /** The game's page: what it checks, in order, and its report. */
    private val PAGE = """
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Test Game</title>
  <style>
    html, body { margin: 0; height: 100%; background: #000; color: #fff; font: 16px sans-serif; }
    #frames { position: fixed; top: 40%; width: 100%; text-align: center; font-size: 32px; }
    #status { position: fixed; top: 55%; width: 100%; text-align: center; }
    #exit { position: fixed; bottom: 16px; left: 50%; transform: translateX(-50%); font-size: 18px; padding: 8px 24px; }
  </style>
</head>
<body>
  <div id="frames">0</div>
  <div id="status">checking</div>
  <button id="exit">EXIT GAME</button>
  <script>
    // SkyStream's test game (Phase 7c): it draws frames, reads the file beside it, asks its interface, opens its
    // dialogs, and reports what it saw; its EXIT GAME button calls the extension's closeGame.
    var frames = 0;
    (function tick() { frames++; document.getElementById('frames').textContent = String(frames); requestAnimationFrame(tick); })();
    document.getElementById('exit').addEventListener('click', function () { TestGame.closeGame(); });
    function attempt(f) {
      try { var v = f(); return v === undefined ? 'undefined' : v; } catch (e) { return 'threw: ' + e.message; }
    }
    // A call made while the page has replaced the built-ins a call could use answers as any other (Android's bridge
    // uses none of the page's).
    function replaced(f) {
      var kept = [JSON.stringify, JSON.parse, Array.prototype.slice, Function.prototype.call, window.Error];
      var broken = function () { throw new TypeError('replaced'); };
      JSON.stringify = JSON.parse = Array.prototype.slice = Function.prototype.call = window.Error = broken;
      try { return attempt(f); } finally {
        JSON.stringify = kept[0]; JSON.parse = kept[1]; Array.prototype.slice = kept[2];
        Function.prototype.call = kept[3]; window.Error = kept[4];
      }
    }
    var seen = {};
    function check() {
      seen.ready = attempt(function () { return TestGame.isReady(); });
      seen.name = attempt(function () { return TestGame.name(); });
      seen.level = attempt(function () { return TestGame.level(); });
      seen.half = attempt(function () { return TestGame.half(); });
      var big = attempt(function () { return TestGame.big(); });
      seen.big = typeof big === 'string' ? big.length : big;
      seen.broken = attempt(function () { return TestGame.broken(); });
      seen.nothing = attempt(function () { return TestGame.nothing(); });
      seen.replaced = replaced(function () { return TestGame.level(); });
      seen.replacedThrow = replaced(function () { return TestGame.broken(); });
      TestGame.saveState('{"level":3}');
      seen.loaded = attempt(function () { return TestGame.loadState(); });
      seen.alert = attempt(function () { return alert('Game ready'); });
      seen.confirm = attempt(function () { return confirm('Keep playing?'); });
      seen.prompt = attempt(function () { return prompt('Your name?', 'Player'); });
      TestGame.report(JSON.stringify(seen));
      document.getElementById('status').textContent = 'checked';
    }
    var xhr = new XMLHttpRequest();
    xhr.open('GET', 'data.bin');
    xhr.responseType = 'arraybuffer';
    xhr.onload = function () {
      var bytes = new Uint8Array(xhr.response || new ArrayBuffer(0));
      var same = bytes.length === 1048576;
      for (var i = 0; same && i < bytes.length; i += 4099) same = bytes[i] === i % 251;
      seen.file = same ? bytes.length : 'wrong: ' + bytes.length;
      check();
    };
    xhr.onerror = function () { seen.file = 'error'; check(); };
    xhr.send();
  </script>
</body>
</html>
""".trimStart()
}
