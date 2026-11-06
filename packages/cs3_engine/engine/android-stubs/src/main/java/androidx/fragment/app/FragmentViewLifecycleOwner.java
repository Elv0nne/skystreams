package androidx.fragment.app;

import androidx.lifecycle.Lifecycle;
import androidx.lifecycle.LifecycleOwner;
import androidx.lifecycle.LifecycleRegistry;

/** A fragment's view's lifecycle: from its view's creation to its destruction. */
class FragmentViewLifecycleOwner implements LifecycleOwner {
    final LifecycleRegistry registry = new LifecycleRegistry(this);

    @Override public Lifecycle getLifecycle() { return registry; }
}
