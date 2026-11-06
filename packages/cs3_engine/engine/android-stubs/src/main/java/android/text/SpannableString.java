package android.text;

import java.lang.reflect.Array;

/** Fixed text that takes spans (and keeps none). */
public class SpannableString implements Spannable {
    private final String text;

    public SpannableString(CharSequence source) {
        this.text = source == null ? "" : source.toString();
    }

    public static SpannableString valueOf(CharSequence source) {
        return source instanceof SpannableString ? (SpannableString) source : new SpannableString(source);
    }

    @Override public int length() { return text.length(); }
    @Override public char charAt(int index) { return text.charAt(index); }
    @Override public CharSequence subSequence(int start, int end) { return new SpannableString(text.substring(start, end)); }
    @Override public String toString() { return text; }
    @Override public void setSpan(Object what, int start, int end, int flags) {}
    @Override public void removeSpan(Object what) {}

    @SuppressWarnings("unchecked")
    @Override public <T> T[] getSpans(int start, int end, Class<T> type) { return (T[]) Array.newInstance(type, 0); }

    @Override public int getSpanStart(Object tag) { return -1; }
    @Override public int getSpanEnd(Object tag) { return -1; }
    @Override public int getSpanFlags(Object tag) { return 0; }
    @Override public int nextSpanTransition(int start, int limit, Class type) { return limit; }
    @Override public boolean equals(Object o) { return o instanceof Spanned && text.equals(o.toString()); }
    @Override public int hashCode() { return text.hashCode(); }
}
