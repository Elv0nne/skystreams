package android.webkit;

/** A web view's settings, kept for when pages come (part 5). */
public class WebSettings {
    private boolean javaScriptEnabled;
    private boolean domStorageEnabled;
    private boolean allowFileAccess;
    private String userAgent;

    public synchronized void setJavaScriptEnabled(boolean flag) { javaScriptEnabled = flag; }
    public synchronized boolean getJavaScriptEnabled() { return javaScriptEnabled; }
    public synchronized void setDomStorageEnabled(boolean flag) { domStorageEnabled = flag; }
    public synchronized boolean getDomStorageEnabled() { return domStorageEnabled; }
    /** Off by default, as Android's since API 30: a page of the extension's own files is served only with it on (Phase 7c's §6). */
    public synchronized void setAllowFileAccess(boolean allow) { allowFileAccess = allow; }
    public synchronized boolean getAllowFileAccess() { return allowFileAccess; }
    public synchronized void setUserAgentString(String ua) { userAgent = ua; }
    public synchronized String getUserAgentString() { return userAgent; }
}
