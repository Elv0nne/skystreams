package android.webkit;

import android.content.Context;
import android.util.AttributeSet;
import android.view.ViewGroup;
import dev.akash.cs3engine.stubs.WebPages;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * A stand-in web view (the sheet shows a "page" node). Its page is the app's ({@link WebPages}): one opens once it's
 * in an open screen's window, and its events reach the clients set here. A web view no screen holds loads nothing:
 * it keeps its URL, and scripts answer "null".
 */
public class WebView extends ViewGroup {
    private final WebSettings settings = new WebSettings();
    private final Map<String, Object> interfaces = new LinkedHashMap<>();
    private WebViewClient client = new WebViewClient();
    private WebChromeClient chrome;
    private String url;
    private Map<String, String> headers = Collections.emptyMap();
    private String title;
    private int progress;
    private boolean destroyed;

    public WebView(Context context) {
        this(context, null);
    }

    public WebView(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public WebView(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public WebView(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    public WebSettings getSettings() { return settings; }
    public void setWebViewClient(WebViewClient client) { this.client = client; }
    public WebViewClient getWebViewClient() { return client; }
    public void setWebChromeClient(WebChromeClient client) { chrome = client; }
    public WebChromeClient getWebChromeClient() { return chrome; }

    public void loadUrl(String url) {
        loadUrl(url, Collections.emptyMap());
    }

    public void loadUrl(String url, Map<String, String> additionalHttpHeaders) {
        this.url = url;
        headers = additionalHttpHeaders == null ? Collections.emptyMap() : new LinkedHashMap<>(additionalHttpHeaders);
        changed();
        WebPages.loading(this);
    }

    public void loadData(String data, String mimeType, String encoding) {}
    public void loadDataWithBaseURL(String baseUrl, String data, String mimeType, String encoding, String historyUrl) {}
    public String getUrl() { return url; }
    public String getTitle() { return title; }
    public int getProgress() { return progress; }

    public void reload() {
        if (url != null) WebPages.loading(this);
    }

    public void stopLoading() {
        WebPages.evaluate(this, "window.stop()", null);
    }

    public boolean canGoBack() { return false; }
    public void goBack() {}

    public void destroy() {
        destroyed = true;
        WebPages.destroyed(this);
    }

    public void onPause() {}
    public void onResume() {}
    public void clearCache(boolean includeDiskFiles) {}
    public void clearHistory() {}

    public void evaluateJavascript(String script, ValueCallback<String> resultCallback) {
        WebPages.evaluate(this, script, resultCallback);
    }

    public void addJavascriptInterface(Object object, String name) { interfaces.put(name, object); }
    public void removeJavascriptInterface(String name) { interfaces.remove(name); }
    public static void setWebContentsDebuggingEnabled(boolean enabled) {}
    @Override protected void onLayout(boolean changed, int l, int t, int r, int b) {}

    /** SkyStream's own: the headers its last load asked for. */
    public Map<String, String> cs3Headers() { return headers; }

    /** SkyStream's own: its JavaScript interfaces, by name. */
    public Map<String, Object> cs3Interfaces() { return Collections.unmodifiableMap(interfaces); }

    /** SkyStream's own: whether it was destroyed. */
    public boolean cs3Destroyed() { return destroyed; }

    /** SkyStream's own: its page's address, progress and title (null: unchanged), as the page reports them. */
    public void cs3Page(String url, int progress, String title) {
        if (url != null) this.url = url;
        this.progress = progress;
        if (title != null) this.title = title;
        changed();
    }
}
