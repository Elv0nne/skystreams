package androidx.activity;

import android.app.Dialog;
import android.content.Context;
import android.os.Bundle;
import androidx.lifecycle.Lifecycle;
import androidx.lifecycle.LifecycleOwner;
import androidx.lifecycle.LifecycleRegistry;

/**
 * A dialog with a lifecycle (created, resumed while it shows, destroyed when it's dismissed, and new for its
 * next show, as Android's) and a Back dispatcher whose fallback is the dialog's own Back: cancel.
 */
public class ComponentDialog extends Dialog implements LifecycleOwner, OnBackPressedDispatcherOwner {
    private LifecycleRegistry lifecycle;
    private final OnBackPressedDispatcher dispatcher = new OnBackPressedDispatcher(() -> ComponentDialog.super.onBackPressed());

    public ComponentDialog(Context context) {
        this(context, 0);
    }

    public ComponentDialog(Context context, int themeResId) {
        super(context, themeResId);
    }

    private LifecycleRegistry registry() {
        if (lifecycle == null) lifecycle = new LifecycleRegistry(this);
        return lifecycle;
    }

    @Override public Lifecycle getLifecycle() { return registry(); }

    @Override public final OnBackPressedDispatcher getOnBackPressedDispatcher() { return dispatcher; }

    @Override public void onBackPressed() { dispatcher.onBackPressed(); }

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        registry().handleLifecycleEvent(Lifecycle.Event.ON_CREATE);
    }

    @Override protected void onStart() {
        super.onStart();
        registry().handleLifecycleEvent(Lifecycle.Event.ON_RESUME);
    }

    @Override protected void onStop() {
        registry().handleLifecycleEvent(Lifecycle.Event.ON_DESTROY);
        lifecycle = null;
        super.onStop();
    }
}
