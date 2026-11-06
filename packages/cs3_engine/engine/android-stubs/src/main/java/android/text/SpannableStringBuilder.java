package android.text;

import java.lang.reflect.Array;

/** Editable text backed by a StringBuilder. Spans are accepted and not kept: the sheet draws plain text. */
public class SpannableStringBuilder implements Editable {
    private final StringBuilder text;

    public SpannableStringBuilder() {
        this("");
    }

    public SpannableStringBuilder(CharSequence text) {
        this.text = new StringBuilder(text == null ? "" : text);
    }

    public SpannableStringBuilder(CharSequence text, int start, int end) {
        this(text == null ? "" : text.subSequence(start, end));
    }

    public static SpannableStringBuilder valueOf(CharSequence source) {
        return source instanceof SpannableStringBuilder ? (SpannableStringBuilder) source : new SpannableStringBuilder(source);
    }

    @Override public int length() { return text.length(); }
    @Override public char charAt(int index) { return text.charAt(index); }
    @Override public CharSequence subSequence(int start, int end) { return new SpannableStringBuilder(text.substring(start, end)); }
    @Override public String toString() { return text.toString(); }

    public void getChars(int start, int end, char[] dest, int destoff) {
        text.getChars(start, end, dest, destoff);
    }

    @Override public SpannableStringBuilder replace(int st, int en, CharSequence source, int start, int end) {
        text.replace(st, en, source.subSequence(start, end).toString());
        return this;
    }

    @Override public SpannableStringBuilder replace(int st, int en, CharSequence source) { return replace(st, en, source, 0, source.length()); }
    @Override public SpannableStringBuilder insert(int where, CharSequence source, int start, int end) { return replace(where, where, source, start, end); }
    @Override public SpannableStringBuilder insert(int where, CharSequence source) { return replace(where, where, source); }

    @Override public SpannableStringBuilder delete(int st, int en) {
        text.delete(st, en);
        return this;
    }

    @Override public SpannableStringBuilder append(CharSequence source) { return replace(length(), length(), source == null ? "null" : source); }
    @Override public SpannableStringBuilder append(CharSequence source, int start, int end) { return replace(length(), length(), source, start, end); }

    @Override public SpannableStringBuilder append(char c) {
        text.append(c);
        return this;
    }

    @Override public void clear() { text.setLength(0); }
    @Override public void clearSpans() {}
    @Override public void setSpan(Object what, int start, int end, int flags) {}
    @Override public void removeSpan(Object what) {}

    @SuppressWarnings("unchecked")
    @Override public <T> T[] getSpans(int start, int end, Class<T> type) { return (T[]) Array.newInstance(type, 0); }

    @Override public int getSpanStart(Object tag) { return -1; }
    @Override public int getSpanEnd(Object tag) { return -1; }
    @Override public int getSpanFlags(Object tag) { return 0; }
    @Override public int nextSpanTransition(int start, int limit, Class type) { return limit; }

    @Override public boolean equals(Object o) {
        return o instanceof Spanned && toString().equals(o.toString());
    }

    @Override public int hashCode() { return toString().hashCode(); }
}
