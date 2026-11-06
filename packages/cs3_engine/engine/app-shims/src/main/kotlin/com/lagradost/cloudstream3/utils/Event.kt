// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.utils

class Event<T> {
    private val observers = mutableSetOf<(T) -> Unit>()

    init {
        synchronized(all) { all += this }
    }

    val size: Int get() = observers.size

    operator fun plusAssign(observer: (T) -> Unit) {
        synchronized(observers) { observers.add(observer) }
    }

    operator fun minusAssign(observer: (T) -> Unit) {
        synchronized(observers) { observers.remove(observer) }
    }

    operator fun invoke(value: T) {
        synchronized(observers) { observers.toList() }.forEach { it(value) }
    }

    companion object {
        // Every event, so an unloaded plugin's observers can be found; weak, as events come and go.
        private val all: MutableSet<Event<*>> = java.util.Collections.newSetFromMap(java.util.WeakHashMap())

        /** Removes the observers whose code [classLoader] loaded: a plugin being unloaded. */
        fun removeObserversFrom(classLoader: ClassLoader) {
            for (event in synchronized(all) { all.toList() }) {
                synchronized(event.observers) { event.observers.removeAll { it.javaClass.classLoader === classLoader } }
            }
        }
    }
}
