@file:JvmName("LifecycleKt")

package androidx.lifecycle

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/**
 * The lifecycle's coroutine scope, made once: a supervisor job on the main thread (the engine's), cancelled
 * when the lifecycle is destroyed.
 */
val Lifecycle.coroutineScope: LifecycleCoroutineScope
    get() {
        while (true) {
            (scope.get() as LifecycleCoroutineScope?)?.let { return it }
            val made = LifecycleCoroutineScopeImpl(this, SupervisorJob() + Dispatchers.Main.immediate)
            if (scope.compareAndSet(null, made)) {
                made.register()
                return made
            }
        }
    }
