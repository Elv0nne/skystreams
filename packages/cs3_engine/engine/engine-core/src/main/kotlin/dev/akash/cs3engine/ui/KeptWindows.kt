package dev.akash.cs3engine.ui

import java.io.File

/**
 * Windows SkyStream keeps for extensions' Support buttons (the spec's pop-up rules): at most [max] per
 * extension, newest first; one with the same words as one kept already takes its place. The platform's main
 * thread only.
 */
class KeptWindows<W>(private val max: Int = MAX) {
    private class Kept<W>(val window: W, val title: String, val words: List<String>)

    private val byPlugin = LinkedHashMap<String, ArrayDeque<Kept<W>>>()

    /** Keeps [window], titled [title] and told by its [words]. Returns the windows it pushes out, for the caller to dismiss. */
    fun keep(plugin: File, window: W, title: String, words: List<String>): List<W> {
        val kept = byPlugin.getOrPut(plugin.absolutePath) { ArrayDeque() }
        val out = kept.filter { it.words == words }.map { it.window }.toMutableList()
        kept.removeAll { it.words == words }
        kept.addFirst(Kept(window, title, words))
        while (kept.size > max) out += kept.removeLast().window
        return out
    }

    /** [plugin]'s kept windows' titles, newest first. */
    fun titles(plugin: File): List<String> = byPlugin[plugin.absolutePath]?.map { it.title }.orEmpty()

    /** Takes [plugin]'s kept windows, newest first: Support shows them, and they're no longer kept until it puts them back ([putBack]). */
    fun take(plugin: File): List<W> = byPlugin.remove(plugin.absolutePath)?.map { it.window }.orEmpty()

    /**
     * Puts [window], which Support showed, back as the oldest of [plugin]'s (the spec's §7): whatever came while it
     * showed stays newer. A kept window with the same words (a newer one), or no room, and it's returned for the
     * caller to dismiss instead.
     */
    fun putBack(plugin: File, window: W, title: String, words: List<String>): List<W> {
        val kept = byPlugin[plugin.absolutePath]
        if (kept != null && (kept.any { it.words == words } || kept.size >= max)) return listOf(window)
        byPlugin.getOrPut(plugin.absolutePath) { ArrayDeque() }.addLast(Kept(window, title, words))
        return emptyList()
    }

    /** The kept window [test] accepts, if any. */
    fun find(test: (W) -> Boolean): W? = byPlugin.values.firstNotNullOfOrNull { kept -> kept.firstOrNull { test(it.window) }?.window }

    /** A kept window [test] accepts went by itself: it's no longer kept. Returns its extension, or null when none was. */
    fun gone(test: (W) -> Boolean): File? {
        val path = byPlugin.entries.firstOrNull { (_, kept) -> kept.any { test(it.window) } }?.key ?: return null
        val kept = byPlugin.getValue(path)
        kept.removeAll { test(it.window) }
        if (kept.isEmpty()) byPlugin.remove(path)
        return File(path)
    }

    companion object {
        /** The spec's "at most 3 per extension". */
        const val MAX = 3
    }
}
