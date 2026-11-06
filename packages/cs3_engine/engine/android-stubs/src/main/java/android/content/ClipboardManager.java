package android.content;

import dev.akash.cs3engine.stubs.Platform;

/** The clipboard: a clip set here goes to the platform, which copies its text in the app. */
public class ClipboardManager {
    private volatile ClipData clip;

    public void setPrimaryClip(ClipData clip) {
        this.clip = clip;
        CharSequence text = clip == null || clip.getItemCount() == 0 ? null : clip.getItemAt(0).coerceToText(null);
        if (text != null && text.length() > 0) Platform.host().copy(text);
    }

    public ClipData getPrimaryClip() { return clip; }
    public boolean hasPrimaryClip() { return clip != null; }
    public void clearPrimaryClip() { clip = null; }

    /** @deprecated as Android's: use setPrimaryClip. */
    @Deprecated
    public void setText(CharSequence text) {
        setPrimaryClip(ClipData.newPlainText(null, text));
    }

    /** @deprecated as Android's: use getPrimaryClip. */
    @Deprecated
    public CharSequence getText() {
        ClipData current = clip;
        return current == null || current.getItemCount() == 0 ? null : current.getItemAt(0).getText();
    }

    @Deprecated
    public boolean hasText() {
        return getText() != null;
    }
}
