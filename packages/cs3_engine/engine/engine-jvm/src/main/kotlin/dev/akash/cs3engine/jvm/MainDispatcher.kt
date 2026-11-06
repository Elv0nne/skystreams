@file:OptIn(InternalCoroutinesApi::class)

package dev.akash.cs3engine.jvm

import dev.akash.cs3engine.stubs.MainThread
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.MainCoroutineDispatcher
import kotlinx.coroutines.Runnable
import kotlinx.coroutines.internal.MainDispatcherFactory
import kotlin.coroutines.CoroutineContext

/**
 * Gives `Dispatchers.Main` a home off Android: CloudStream's library and some plugins
 * launch UI-side work on it. Registered through META-INF/services.
 */
class EngineMainDispatcherFactory : MainDispatcherFactory {
    override val loadPriority: Int = 0

    override fun createDispatcher(allFactories: List<MainDispatcherFactory>): MainCoroutineDispatcher =
        EngineMainDispatcher(invokeImmediately = false)
}

private class EngineMainDispatcher(private val invokeImmediately: Boolean) : MainCoroutineDispatcher() {
    override val immediate: MainCoroutineDispatcher =
        if (invokeImmediately) this else EngineMainDispatcher(invokeImmediately = true)

    override fun isDispatchNeeded(context: CoroutineContext): Boolean =
        !invokeImmediately || !MainThread.isMainThread()

    override fun dispatch(context: CoroutineContext, block: Runnable) = MainThread.post(block)
}
