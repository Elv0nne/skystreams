// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3

import com.lagradost.cloudstream3.utils.Event

/**
 * App-wide events plugins subscribe to through `MainActivity.Companion`. Each platform's
 * `MainActivity` stand-in exposes these from its companion object.
 */
object MainActivityEvents {
    val afterPluginsLoadedEvent = Event<Boolean>()
    val mainPluginsLoadedEvent = Event<Boolean>()
    val afterRepositoryLoadedEvent = Event<Boolean>()
    val bookmarksUpdatedEvent = Event<Boolean>()
    val reloadHomeEvent = Event<Boolean>()
    val reloadLibraryEvent = Event<Boolean>()
    val reloadAccountEvent = Event<Boolean>()
}
