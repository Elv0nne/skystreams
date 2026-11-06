package dev.akash.cs3engine.ui

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class KeptWindowsTest {
    private val plugin = File("/plugins/Test.cs3")
    private val other = File("/plugins/Other.cs3")

    @Test
    fun `an extension keeps three windows at most, newest first, and the oldest goes`() {
        val kept = KeptWindows<String>()
        assertEquals(emptyList(), kept.keep(plugin, "a", "A", listOf("A")))
        assertEquals(emptyList(), kept.keep(plugin, "b", "B", listOf("B")))
        assertEquals(emptyList(), kept.keep(plugin, "c", "C", listOf("C")))
        assertEquals(listOf("a"), kept.keep(plugin, "d", "D", listOf("D")), "pushed out, for the caller to dismiss")
        assertEquals(listOf("D", "C", "B"), kept.titles(plugin))
    }

    @Test
    fun `a window with the same words as one kept takes its place`() {
        val kept = KeptWindows<String>()
        kept.keep(plugin, "first", "Support us", listOf("Support us", "Donate"))
        kept.keep(plugin, "news", "News", listOf("News"))
        assertEquals(listOf("first"), kept.keep(plugin, "again", "Support us", listOf("Support us", "Donate")))
        assertEquals(listOf("Support us", "News"), kept.titles(plugin))
        assertEquals("news", kept.find { it == "news" })
        assertEquals(listOf("again", "news"), kept.take(plugin))
    }

    @Test
    fun `extensions keep their own, Support takes them all, and a window that went by itself is forgotten`() {
        val kept = KeptWindows<String>()
        kept.keep(plugin, "a", "A", listOf("A"))
        kept.keep(plugin, "b", "B", listOf("B"))
        kept.keep(other, "x", "X", listOf("X"))
        assertEquals(plugin, kept.gone { it == "a" })
        assertNull(kept.gone { it == "a" }, "only once")
        assertEquals(listOf("B"), kept.titles(plugin))
        assertEquals(listOf("b"), kept.take(plugin))
        assertEquals(emptyList(), kept.titles(plugin), "taken: no longer kept")
        assertNull(kept.find { it == "b" })
        assertEquals(listOf("X"), kept.titles(other))
    }

    @Test
    fun `a window Support showed goes back as the oldest, unless a newer one has its words or there's no room`() {
        val kept = KeptWindows<String>()
        kept.keep(plugin, "new", "New", listOf("New"))
        assertEquals(emptyList(), kept.putBack(plugin, "support", "Support us", listOf("Support us")))
        assertEquals(listOf("New", "Support us"), kept.titles(plugin), "older than what came while Support showed it")
        assertEquals(listOf("again"), kept.putBack(plugin, "again", "New", listOf("New")), "a newer one with its words stays")
        kept.keep(plugin, "third", "Third", listOf("Third"))
        assertEquals(listOf("full"), kept.putBack(plugin, "full", "Full", listOf("Full")), "no room: it goes, as the oldest")
        assertEquals(listOf("Third", "New", "Support us"), kept.titles(plugin))
        assertEquals(emptyList(), kept.putBack(other, "x", "X", listOf("X")))
        assertEquals(listOf("X"), kept.titles(other))
    }
}
