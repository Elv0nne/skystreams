package android.webkit;

/** A web view's chrome client: Android's defaults (framework-gen fills the rest); a page's dialogs are left to the app. */
public class WebChromeClient {
    public void onProgressChanged(WebView view, int newProgress) {}

    public void onReceivedTitle(WebView view, String title) {}

    public boolean onJsAlert(WebView view, String url, String message, JsResult result) { return false; }

    public boolean onJsConfirm(WebView view, String url, String message, JsResult result) { return false; }

    public boolean onJsPrompt(WebView view, String url, String message, String defaultValue, JsPromptResult result) { return false; }
}
