package androidx.activity;

import androidx.lifecycle.Lifecycle;
import androidx.lifecycle.LifecycleEventObserver;
import androidx.lifecycle.LifecycleOwner;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/** Gives Back to the newest enabled callback, else to its fallback (a dialog's own Back: cancel). */
public final class OnBackPressedDispatcher {
    private final Runnable fallback;
    private final List<OnBackPressedCallback> callbacks = new CopyOnWriteArrayList<>();

    public OnBackPressedDispatcher() {
        this(null);
    }

    public OnBackPressedDispatcher(Runnable fallbackOnBackPressed) {
        this.fallback = fallbackOnBackPressed;
    }

    public final void addCallback(OnBackPressedCallback callback) {
        callbacks.add(callback);
        callback.dispatchers.add(this);
    }

    /** [callback] takes part while [owner] is started, and leaves for good when it's destroyed, as Android's. */
    public final void addCallback(LifecycleOwner owner, OnBackPressedCallback callback) {
        Lifecycle lifecycle = owner.getLifecycle();
        if (lifecycle.getCurrentState() == Lifecycle.State.DESTROYED) return;
        lifecycle.addObserver(new LifecycleEventObserver() {
            @Override public void onStateChanged(LifecycleOwner source, Lifecycle.Event event) {
                if (event == Lifecycle.Event.ON_START) {
                    addCallback(callback);
                } else if (event == Lifecycle.Event.ON_STOP) {
                    removeCallback(callback);
                } else if (event == Lifecycle.Event.ON_DESTROY) {
                    removeCallback(callback);
                    lifecycle.removeObserver(this);
                }
            }
        });
    }

    public final boolean hasEnabledCallbacks() {
        for (OnBackPressedCallback callback : callbacks) if (callback.isEnabled()) return true;
        return false;
    }

    public final void onBackPressed() {
        List<OnBackPressedCallback> now = new ArrayList<>(callbacks);
        for (int i = now.size() - 1; i >= 0; i--) {
            OnBackPressedCallback callback = now.get(i);
            if (callback.isEnabled()) {
                callback.handleOnBackPressed();
                return;
            }
        }
        if (fallback != null) fallback.run();
    }

    void removeCallback(OnBackPressedCallback callback) {
        callbacks.remove(callback);
        callback.dispatchers.remove(this);
    }
}
