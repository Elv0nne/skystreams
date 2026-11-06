package android.text;

/** Text whose spans can change. */
public interface Spannable extends Spanned {
    void setSpan(Object what, int start, int end, int flags);
    void removeSpan(Object what);
}
