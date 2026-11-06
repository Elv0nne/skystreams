package androidx.lifecycle;

/** Something with a lifecycle: a fragment, its view, an activity, a dialog. */
public interface LifecycleOwner {
    Lifecycle getLifecycle();
}
