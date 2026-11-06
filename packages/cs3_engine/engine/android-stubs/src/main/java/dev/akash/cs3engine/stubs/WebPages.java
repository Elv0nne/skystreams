package dev.akash.cs3engine.stubs;

import android.webkit.ValueCallback;
import android.webkit.WebView;

/**
 * Where the WebView stand-in's pages come from: the engine's ({@code JvmPages}), once installed. A page opens only
 * for a web view in an open screen's window; with none installed, or for any other web view, nothing loads and
 * scripts answer "null" (part 2's stand-in, and Phase 3b's decision: scrapers' web views stay headless).
 */
public final class WebPages {
    /** The engine's side. Called on the thread the extension calls from: the main thread, for views. */
    public interface Listener {
        /** {@code view} loads its URL: loadUrl, or reload. */
        void loading(WebView view);

        /** Runs {@code script} in {@code view}'s page; {@code callback} (may be null) hears the result on the main thread. */
        void evaluate(WebView view, String script, ValueCallback<String> callback);

        /** {@code view} was destroyed: its page goes. */
        void destroyed(WebView view);
    }

    private static volatile Listener listener;

    private WebPages() {}

    public static void install(Listener value) {
        listener = value;
    }

    public static void loading(WebView view) {
        Listener current = listener;
        if (current != null) current.loading(view);
    }

    public static void evaluate(WebView view, String script, ValueCallback<String> callback) {
        Listener current = listener;
        if (current != null) {
            current.evaluate(view, script, callback);
            return;
        }
        // No page: "null", after the current task, as a page's answer would come.
        if (callback != null) MainThread.post(() -> callback.onReceiveValue("null"));
    }

    public static void destroyed(WebView view) {
        Listener current = listener;
        if (current != null) current.destroyed(view);
    }
}
