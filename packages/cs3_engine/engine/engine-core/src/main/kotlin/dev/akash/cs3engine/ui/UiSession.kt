package dev.akash.cs3engine.ui

import java.io.File

/**
 * One extension screen open in the app: the windows [plugin] shows, from when the screen opens until
 * its last window closes. The platform's [ExtensionUiHost] publishes the windows and ends the session.
 */
class UiSession internal constructor(val id: Int, val plugin: File, private val listener: Listener) {
    internal interface Listener {
        fun published(session: UiSession, windows: List<Map<String, Any?>>)

        fun ended(session: UiSession, reason: String)

        /** Keyboard or D-pad focus left the page at [node] towards [direction]: the app moves its focus on. */
        fun pageFocusLeft(session: UiSession, node: Int, direction: String) {}
    }

    @Volatile
    var ended: Boolean = false
        private set

    /** Actions the person sent, closing aside. */
    @Volatile
    var actions: Int = 0
        internal set

    /** The session's windows now, bottom to top, as the protocol describes them. */
    fun publish(windows: List<Map<String, Any?>>) {
        if (!ended) listener.published(this, windows)
    }

    /** Focus left the page at [node] (Android's lent WebView) towards [direction]: forward, backward, up, down, left or right. */
    fun pageFocusLeft(node: Int, direction: String) {
        if (!ended) listener.pageFocusLeft(this, node, direction)
    }

    /** Ends the session: "closed" when its last window has gone, or another [reason]. Once only. */
    fun end(reason: String) {
        synchronized(this) {
            if (ended) return
            ended = true
        }
        listener.ended(this, reason)
    }
}
