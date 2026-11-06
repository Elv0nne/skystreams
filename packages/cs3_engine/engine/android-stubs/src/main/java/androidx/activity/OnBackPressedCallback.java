package androidx.activity;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/** Handles Back while enabled. Among a dispatcher's enabled callbacks, the newest wins. */
public abstract class OnBackPressedCallback {
    private volatile boolean enabled;
    final List<OnBackPressedDispatcher> dispatchers = new CopyOnWriteArrayList<>();

    public OnBackPressedCallback(boolean enabled) {
        this.enabled = enabled;
    }

    public final boolean isEnabled() { return enabled; }

    public final void setEnabled(boolean enabled) { this.enabled = enabled; }

    /** Leaves every dispatcher it was added to. */
    public final void remove() {
        for (OnBackPressedDispatcher dispatcher : dispatchers) dispatcher.removeCallback(this);
    }

    public abstract void handleOnBackPressed();
}
