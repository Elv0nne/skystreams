package android.webkit;

import dev.akash.cs3engine.stubs.WebCookies;

/** Reads and writes the engine's cookie jar; there is no browser behind it yet. */
public class CookieManager {
    private static final CookieManager INSTANCE = new CookieManager();

    public static CookieManager getInstance() { return INSTANCE; }

    public String getCookie(String url) { return WebCookies.get(url); }
    public void setCookie(String url, String value) { WebCookies.set(url, value); }
    public boolean hasCookies() { return !WebCookies.isEmpty(); }
    public void setAcceptCookie(boolean accept) {}
    public boolean acceptCookie() { return true; }
    public void flush() {}
    public void removeAllCookie() { WebCookies.clear(); }

    public void removeAllCookies(ValueCallback<Boolean> callback) {
        WebCookies.clear();
        if (callback != null) callback.onReceiveValue(true);
    }
}
