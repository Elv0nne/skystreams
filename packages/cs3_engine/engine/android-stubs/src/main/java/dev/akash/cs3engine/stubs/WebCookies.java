package dev.akash.cs3engine.stubs;

import java.net.URI;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Cookie jar behind the {@code android.webkit.CookieManager} stand-in, by the domain each cookie is for: a host's own,
 * or a Set-Cookie line's Domain, or the domain a page's browser reports. A request's cookies are its host's and its
 * parent domains', as Android's store answers, the parent domains' first. Cloudflare clearances the host WebView
 * solves land here too (see WebClearanceStore), and so do extension pages' cookies (JvmPages).
 */
public final class WebCookies {
    private static final Map<String, Map<String, String>> BY_DOMAIN = new ConcurrentHashMap<>();

    private WebCookies() {}

    static String host(String url) {
        try {
            String host = URI.create(url.trim()).getHost();
            return (host != null ? host : url).toLowerCase(Locale.ROOT);
        } catch (IllegalArgumentException e) {
            return url.toLowerCase(Locale.ROOT);
        }
    }

    private static String domain(String domain) {
        String d = domain.trim().toLowerCase(Locale.ROOT);
        return d.startsWith(".") ? d.substring(1) : d;
    }

    /** The cookies a request to {@code url} carries, or null when there are none. */
    public static String get(String url) {
        String host = host(url);
        List<String> domains = new ArrayList<>();
        for (String domain : BY_DOMAIN.keySet()) {
            if (host.equals(domain) || host.endsWith("." + domain)) domains.add(domain);
        }
        // Parent domains first, then the host's own: a fixed order, whatever the map's.
        domains.sort(Comparator.comparingInt(String::length));
        Map<String, String> out = new LinkedHashMap<>();
        for (String domain : domains) {
            Map<String, String> cookies = BY_DOMAIN.get(domain);
            if (cookies == null) continue;
            synchronized (cookies) {
                out.putAll(cookies);
            }
        }
        if (out.isEmpty()) return null;
        StringBuilder sb = new StringBuilder();
        out.forEach((k, v) -> sb.append(sb.length() == 0 ? "" : "; ").append(k).append('=').append(v));
        return sb.toString();
    }

    /** A Set-Cookie line for {@code url}: kept for its Domain attribute when that covers the host, else for the host. */
    public static void set(String url, String cookieLine) {
        String[] parts = cookieLine.split(";");
        String pair = parts[0];
        int eq = pair.indexOf('=');
        if (eq <= 0) return;
        String host = host(url);
        String domain = host;
        for (int i = 1; i < parts.length; i++) {
            String attribute = parts[i].trim();
            if (!attribute.regionMatches(true, 0, "domain=", 0, 7)) continue;
            String covered = domain(attribute.substring(7));
            if (!covered.isEmpty() && (host.equals(covered) || host.endsWith("." + covered))) domain = covered;
        }
        put(domain, pair.substring(0, eq).trim(), pair.substring(eq + 1).trim());
    }

    /** A page's cookie, for the {@code domain} its browser reports. */
    public static void setFor(String domain, String name, String value) {
        put(domain(domain), name, value);
    }

    private static void put(String domain, String name, String value) {
        Map<String, String> cookies = BY_DOMAIN.computeIfAbsent(domain, d -> Collections.synchronizedMap(new LinkedHashMap<>()));
        cookies.put(name, value);
    }

    public static boolean isEmpty() {
        return BY_DOMAIN.isEmpty();
    }

    public static void clear() {
        BY_DOMAIN.clear();
    }
}
