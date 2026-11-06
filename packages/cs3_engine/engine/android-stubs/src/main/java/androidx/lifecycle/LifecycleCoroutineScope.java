package androidx.lifecycle;

import kotlin.Unit;
import kotlin.coroutines.Continuation;
import kotlin.coroutines.EmptyCoroutineContext;
import kotlin.jvm.functions.Function2;
import kotlinx.coroutines.BuildersKt;
import kotlinx.coroutines.CoroutineScope;
import kotlinx.coroutines.CoroutineStart;
import kotlinx.coroutines.Job;

/**
 * A coroutine scope tied to a lifecycle. Stand-in fragments reach their resumed state in the task that adds
 * them, so launchWhenCreated, …Started and …Resumed launch at once.
 */
public abstract class LifecycleCoroutineScope implements CoroutineScope {
    public LifecycleCoroutineScope() {}

    public abstract Lifecycle getLifecycle$lifecycle_common();

    public final Job launchWhenCreated(Function2<? super CoroutineScope, ? super Continuation<? super Unit>, ?> block) {
        return launch(block);
    }

    public final Job launchWhenStarted(Function2<? super CoroutineScope, ? super Continuation<? super Unit>, ?> block) {
        return launch(block);
    }

    public final Job launchWhenResumed(Function2<? super CoroutineScope, ? super Continuation<? super Unit>, ?> block) {
        return launch(block);
    }

    private Job launch(Function2<? super CoroutineScope, ? super Continuation<? super Unit>, ?> block) {
        return BuildersKt.launch(this, EmptyCoroutineContext.INSTANCE, CoroutineStart.DEFAULT, block);
    }
}
