package dev.akash.cs3engine.ui

import java.io.File

/**
 * What a platform does with extensions' windows. Android keeps the real ones invisible and reads them;
 * the JVM keeps stand-in views (the spec's part 2).
 */
interface ExtensionUiHost {
    /**
     * Runs [open] (the extension's `openSettings`) on the platform's main thread. From then on, each
     * window [plugin] shows belongs to [session], until the session ends. Returns once [open] has run,
     * throwing what it threw.
     */
    suspend fun open(session: UiSession, plugin: File, open: () -> Unit)

    /**
     * Returns once the main thread has run what [open] posted to it (a dialog fragment's show), however
     * slow the device: the wait for [session]'s first window starts from there.
     */
    suspend fun settled(session: UiSession) {}

    /** Applies [action] (with [value]) to node [node] of [session], on the main thread; throws if the node is gone. */
    suspend fun act(session: UiSession, node: Int, action: String, value: Any?)

    /**
     * Closes [session]'s windows, top first: as Back, then dismissed if one stays. [force] dismisses at once. A
     * screen Support opened ([openKept]) puts the windows it took back behind Support instead, the extension never
     * told (the spec's §7); a window that joined it meanwhile closes as above.
     */
    suspend fun close(session: UiSession, force: Boolean)

    /** Hands the host the pop-up rules ([Popups]) for windows of extensions with no screen open, once, at start. */
    fun attach(popups: Popups) {}

    /**
     * Takes [plugin]'s kept windows into [session] and publishes them, the oldest at the bottom (Support opens
     * them); false when it has none. They're no longer kept while they show: closing them, or one of them, puts
     * them back (the spec's §7).
     */
    suspend fun openKept(session: UiSession, plugin: File): Boolean = false

    /** [plugin] is unloading: its kept windows, and its pages waiting for their sort, are dismissed, and its Support button goes. */
    suspend fun forgetKept(plugin: File) {}
}
