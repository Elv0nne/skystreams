package androidx.lifecycle;

/** Hears each step of a lifecycle as its own method. */
public interface DefaultLifecycleObserver extends LifecycleObserver {
    default void onCreate(LifecycleOwner owner) {}

    default void onStart(LifecycleOwner owner) {}

    default void onResume(LifecycleOwner owner) {}

    default void onPause(LifecycleOwner owner) {}

    default void onStop(LifecycleOwner owner) {}

    default void onDestroy(LifecycleOwner owner) {}
}
