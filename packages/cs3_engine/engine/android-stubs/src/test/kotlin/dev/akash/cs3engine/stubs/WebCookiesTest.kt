package dev.akash.cs3engine.stubs

import android.webkit.CookieManager
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class WebCookiesTest {
    @AfterTest
    fun clear() = WebCookies.clear()

    @Test
    fun `a cookie set for a domain reaches that domain and its subdomains, not other hosts`() {
        WebCookies.setFor(".febbox.com", "ui", "token")
        WebCookies.set("https://www.febbox.com/login", "lang=en; Path=/")
        val cookies = CookieManager.getInstance()
        assertEquals("ui=token", cookies.getCookie("https://febbox.com/"))
        assertEquals("ui=token; lang=en", cookies.getCookie("https://www.febbox.com/console"))
        assertNull(cookies.getCookie("https://notfebbox.com/"))
        assertNull(cookies.getCookie("https://example.com/"))
    }

    @Test
    fun `a Set-Cookie line's Domain attribute is kept, if it covers the page's host`() {
        WebCookies.set("https://www.site.test/", "session=ok; Domain=.site.test; Path=/")
        WebCookies.set("https://www.site.test/", "evil=1; Domain=other.test")
        assertEquals("session=ok", CookieManager.getInstance().getCookie("https://api.site.test/"))
        assertEquals("session=ok; evil=1", CookieManager.getInstance().getCookie("https://www.site.test/"))
        assertNull(CookieManager.getInstance().getCookie("https://other.test/"))
    }
}
