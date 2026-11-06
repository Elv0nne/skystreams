// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3

import androidx.appcompat.app.AppCompatActivity

/**
 * Off Android there is no real activity; plugins receive an instance of this as their
 * Context, so `context as AppCompatActivity` casts still succeed.
 */
open class MainActivity : AppCompatActivity() {
    companion object {
        val afterPluginsLoadedEvent get() = MainActivityEvents.afterPluginsLoadedEvent
        val mainPluginsLoadedEvent get() = MainActivityEvents.mainPluginsLoadedEvent
        val afterRepositoryLoadedEvent get() = MainActivityEvents.afterRepositoryLoadedEvent
        val bookmarksUpdatedEvent get() = MainActivityEvents.bookmarksUpdatedEvent
        val reloadHomeEvent get() = MainActivityEvents.reloadHomeEvent
        val reloadLibraryEvent get() = MainActivityEvents.reloadLibraryEvent
        val reloadAccountEvent get() = MainActivityEvents.reloadAccountEvent
    }
}
