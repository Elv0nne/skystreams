package android.webkit;

/**
 * A web view's client: Android's defaults, the request forms asking the older ones as Android's do. framework-gen fills
 * the rest (onPageStarted, which takes a Bitmap no stand-in is written for, among them).
 */
public class WebViewClient {
    public void onPageFinished(WebView view, String url) {}

    public boolean shouldOverrideUrlLoading(WebView view, String url) { return false; }

    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
        return shouldOverrideUrlLoading(view, request.getUrl().toString());
    }

    public WebResourceResponse shouldInterceptRequest(WebView view, String url) { return null; }

    public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
        return shouldInterceptRequest(view, request.getUrl().toString());
    }

    public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) {}

    public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
        if (request.isForMainFrame()) {
            onReceivedError(view, error.getErrorCode(), String.valueOf(error.getDescription()), request.getUrl().toString());
        }
    }

    public void doUpdateVisitedHistory(WebView view, String url, boolean isReload) {}
}
