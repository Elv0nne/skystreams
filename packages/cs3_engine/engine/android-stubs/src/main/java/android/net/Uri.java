package android.net;

import java.io.UnsupportedEncodingException;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** The parsing half of android.net.Uri. Uses the RFC 3986 regex, so malformed URLs still parse. */
public class Uri {
    private static final Pattern RFC3986 = Pattern.compile("^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\\?([^#]*))?(#(.*))?");

    private final String value;
    private final String scheme;
    private final String authority;
    private final String path;
    private final String query;
    private final String fragment;

    private Uri(String value) {
        this.value = value;
        Matcher m = RFC3986.matcher(value);
        m.matches();
        scheme = m.group(2);
        authority = m.group(4);
        path = m.group(5);
        query = m.group(7);
        fragment = m.group(9);
    }

    public static Uri parse(String uriString) { return new Uri(uriString); }

    public String getScheme() { return scheme; }
    public String getAuthority() { return authority; }
    public String getEncodedPath() { return path; }
    public String getPath() { return path == null ? null : decode(path); }
    public String getEncodedQuery() { return query; }
    public String getQuery() { return query == null ? null : decode(query); }
    public String getFragment() { return fragment == null ? null : decode(fragment); }

    public String getHost() {
        if (authority == null) return null;
        String host = authority.substring(authority.lastIndexOf('@') + 1);
        if (host.startsWith("[")) return host.substring(0, host.indexOf(']') + 1);
        int colon = host.lastIndexOf(':');
        return colon >= 0 ? host.substring(0, colon) : host;
    }

    public int getPort() {
        String host = authority == null ? "" : authority.substring(authority.lastIndexOf('@') + 1);
        int colon = host.lastIndexOf(':');
        if (colon < 0 || host.endsWith("]")) return -1;
        try {
            return Integer.parseInt(host.substring(colon + 1));
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    public List<String> getPathSegments() {
        List<String> segments = new ArrayList<>();
        if (path != null) {
            for (String s : path.split("/")) if (!s.isEmpty()) segments.add(decode(s));
        }
        return Collections.unmodifiableList(segments);
    }

    public String getLastPathSegment() {
        List<String> segments = getPathSegments();
        return segments.isEmpty() ? null : segments.get(segments.size() - 1);
    }

    public List<String> getQueryParameters(String key) {
        List<String> values = new ArrayList<>();
        if (query == null) return values;
        for (String pair : query.split("&")) {
            int eq = pair.indexOf('=');
            String k = decode(eq >= 0 ? pair.substring(0, eq) : pair);
            if (k.equals(key)) values.add(eq >= 0 ? decode(pair.substring(eq + 1)) : "");
        }
        return values;
    }

    public String getQueryParameter(String key) {
        List<String> values = getQueryParameters(key);
        return values.isEmpty() ? null : values.get(0);
    }

    public Set<String> getQueryParameterNames() {
        Set<String> names = new LinkedHashSet<>();
        if (query == null) return names;
        for (String pair : query.split("&")) {
            int eq = pair.indexOf('=');
            names.add(decode(eq >= 0 ? pair.substring(0, eq) : pair));
        }
        return names;
    }

    public static String encode(String s) {
        return encode(s, null);
    }

    public static String encode(String s, String allow) {
        if (s == null) return null;
        StringBuilder out = new StringBuilder();
        s.codePoints().forEach(cp -> {
            boolean ascii = cp < 128;
            boolean unreserved = ascii && (Character.isLetterOrDigit(cp) || "_-!.~'()*".indexOf(cp) >= 0);
            if (unreserved || (ascii && allow != null && allow.indexOf(cp) >= 0)) {
                out.appendCodePoint(cp);
            } else {
                try {
                    out.append(URLEncoder.encode(new String(Character.toChars(cp)), "UTF-8").replace("+", "%20"));
                } catch (UnsupportedEncodingException e) {
                    throw new AssertionError(e);
                }
            }
        });
        return out.toString();
    }

    public static String decode(String s) {
        if (s == null) return null;
        try {
            return URLDecoder.decode(s.replace("+", "%2B"), StandardCharsets.UTF_8.name());
        } catch (UnsupportedEncodingException | IllegalArgumentException e) {
            return s;
        }
    }

    @Override public String toString() { return value; }
    @Override public boolean equals(Object o) { return o instanceof Uri && value.equals(((Uri) o).value); }
    @Override public int hashCode() { return value.hashCode(); }
}
