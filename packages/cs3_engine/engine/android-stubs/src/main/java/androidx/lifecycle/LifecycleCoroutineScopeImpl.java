package androidx.lifecycle;

import dev.akash.cs3engine.stubs.MainThread;
import java.util.concurrent.CancellationException;
import kotlin.coroutines.CoroutineContext;
import kotlinx.coroutines.JobKt;

/** The scope a lifecycle gives: its job is cancelled when the lifecycle is destroyed. */
public final class LifecycleCoroutineScopeImpl extends LifecycleCoroutineScope implements LifecycleEventObserver {
    private final Lifecycle lifecycle;
    private final CoroutineContext coroutineContext;

    public LifecycleCoroutineScopeImpl(Lifecycle lifecycle, CoroutineContext coroutineContext) {
        this.lifecycle = lifecycle;
        this.coroutineContext = coroutineContext;
        if (lifecycle.getCurrentState() == Lifecycle.State.DESTROYED) JobKt.cancel(coroutineContext, (CancellationException) null);
    }

    @Override public Lifecycle getLifecycle$lifecycle_common() { return lifecycle; }

    @Override public CoroutineContext getCoroutineContext() { return coroutineContext; }

    /** Starts watching the lifecycle, on the main thread, where stand-in lifecycles move. */
    public final void register() {
        Runnable watch = () -> {
            if (lifecycle.getCurrentState().isAtLeast(Lifecycle.State.INITIALIZED)) lifecycle.addObserver(this);
            else JobKt.cancel(coroutineContext, (CancellationException) null);
        };
        if (MainThread.isMainThread()) watch.run();
        else MainThread.post(watch);
    }

    @Override public void onStateChanged(LifecycleOwner source, Lifecycle.Event event) {
        if (lifecycle.getCurrentState().compareTo(Lifecycle.State.DESTROYED) <= 0) {
            lifecycle.removeObserver(this);
            JobKt.cancel(coroutineContext, (CancellationException) null);
        }
    }
}
