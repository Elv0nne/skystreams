package dev.akash.cs3engine.ui

import java.io.File

/**
 * The spec's pop-up rules, as the platforms ask them about a window of an extension that has no screen open:
 * a background call's, or one the person waits on. [ExtensionUi] answers; hosts call on their main thread.
 */
interface Popups {
    /**
     * What to do with [plugin]'s window; [holdsPage]: it has a web page in it; [unseen]: its extension made it
     * invisible (alpha 0, or a side of a pixel or less), so no one reads it. See [Sorting].
     */
    fun sort(plugin: File, holdsPage: Boolean, unseen: Boolean = false): Sorting

    /**
     * [plugin]'s background window holding a page, parked since [sort] answered [Sorting.Later]: [Sorting.Drop]
     * while a call of its extension still runs (the call waits on it: a bot check), else [Sorting.Keep] (a promotion).
     */
    fun sortPage(plugin: File): Sorting

    /** [plugin]'s kept windows are now [titles], newest first; [added] is the title of the one just kept, if one was. */
    fun kept(plugin: File, titles: List<String>, added: String?)

    /** [plugin]'s window was dismissed as if the person closed it, for [reason] (`page`). */
    fun dropped(plugin: File, reason: String)

    /** [plugin]'s window shows as the platform draws it, for [why]: the rules couldn't hold it (Android: `thread`). */
    fun escaped(plugin: File, why: String)
}

/** How a window of an extension with no screen open is handled. */
sealed interface Sorting {
    /** The person waits on the extension: the window shows in [session], which the app opens (`uiOpened`). */
    class Show(val session: UiSession) : Sorting

    /** A page a call of its extension waits on: dismissed as if closed (`popupDropped`). SkyStream's own bot checks cover the site. */
    data object Drop : Sorting

    /** Anything else (support, donate, a promo, a notice): kept out of sight for the Support button (`popupKept`). */
    data object Keep : Sorting

    /** A page in the background: parked out of sight, then sorted again in [afterMs] with [Popups.sortPage] (the spec's §7). */
    data class Later(val afterMs: Long) : Sorting
}
