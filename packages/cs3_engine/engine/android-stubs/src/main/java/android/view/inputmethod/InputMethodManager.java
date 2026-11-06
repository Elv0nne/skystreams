package android.view.inputmethod;

/** The keyboard: SkyStream's sheet has its own, so nothing here shows or hides one. */
public final class InputMethodManager {
    public static final int HIDE_IMPLICIT_ONLY = 0x0001;
    public static final int HIDE_NOT_ALWAYS = 0x0002;
    public static final int SHOW_IMPLICIT = 0x0001;
    public static final int SHOW_FORCED = 0x0002;

    public boolean isActive() { return false; }
    public boolean isAcceptingText() { return false; }
}
