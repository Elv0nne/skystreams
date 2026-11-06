package androidx.lifecycle;

/** Hears each step of a lifecycle as an event. */
public interface LifecycleEventObserver extends LifecycleObserver {
    void onStateChanged(LifecycleOwner source, Lifecycle.Event event);
}
