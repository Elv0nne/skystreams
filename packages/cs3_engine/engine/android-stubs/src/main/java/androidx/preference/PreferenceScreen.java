package androidx.preference;

import android.content.Context;
import android.util.AttributeSet;

/** A screen's preferences: its fragment's list shows them. Opening a nested one isn't supported. */
public final class PreferenceScreen extends PreferenceGroup {
    public PreferenceScreen(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    @Override protected boolean isOnSameScreenAsChildren() { return false; }
}
