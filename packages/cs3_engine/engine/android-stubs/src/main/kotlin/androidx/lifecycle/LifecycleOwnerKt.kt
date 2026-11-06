@file:JvmName("LifecycleOwnerKt")

package androidx.lifecycle

/** The owner's lifecycle's coroutine scope. */
val LifecycleOwner.lifecycleScope: LifecycleCoroutineScope
    get() = lifecycle.coroutineScope
