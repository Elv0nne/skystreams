package android.text;

import java.util.Iterator;

public class TextUtils {
    private TextUtils() {}

    public static boolean isEmpty(CharSequence str) { return str == null || str.length() == 0; }

    public static boolean equals(CharSequence a, CharSequence b) {
        if (a == b) return true;
        return a != null && b != null && a.toString().contentEquals(b);
    }

    public static boolean isDigitsOnly(CharSequence str) {
        for (int i = 0; i < str.length(); i++) if (!Character.isDigit(str.charAt(i))) return false;
        return true;
    }

    public static String join(CharSequence delimiter, Object[] tokens) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < tokens.length; i++) sb.append(i == 0 ? "" : delimiter).append(tokens[i]);
        return sb.toString();
    }

    public static String join(CharSequence delimiter, Iterable<?> tokens) {
        StringBuilder sb = new StringBuilder();
        Iterator<?> it = tokens.iterator();
        while (it.hasNext()) sb.append(sb.length() == 0 ? "" : delimiter).append(it.next());
        return sb.toString();
    }

    public static String htmlEncode(String s) {
        StringBuilder sb = new StringBuilder(s.length());
        for (char c : s.toCharArray()) {
            switch (c) {
                case '<': sb.append("&lt;"); break;
                case '>': sb.append("&gt;"); break;
                case '&': sb.append("&amp;"); break;
                case '\'': sb.append("&#39;"); break;
                case '"': sb.append("&quot;"); break;
                default: sb.append(c);
            }
        }
        return sb.toString();
    }
}
