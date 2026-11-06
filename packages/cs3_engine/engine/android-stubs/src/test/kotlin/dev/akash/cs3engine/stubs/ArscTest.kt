package dev.akash.cs3engine.stubs

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ArscTest {
    private fun table(language: String = "en", bytes: ByteArray = Fixtures.arsc) = ResourceTable(Arsc.read(bytes), language)

    private fun ResourceTable.string(name: String): String? = entry(identifier("string", name))?.value?.string

    @Test
    fun `the test extension's table has its package, its ids by name, its strings, arrays and files`() {
        val table = table()
        assertEquals("dev.akash.cs3test", table.packageName())
        assertEquals(0x7f, table.packageId())
        assertEquals("SkyStream test settings", table.string("title"))
        val qualities = table.entry(table.identifier("array", "qualities"))!!
        assertTrue(qualities.isBag)
        assertEquals(listOf("480p", "720p", "1080p"), qualities.bagValues.map { it.string })
        assertEquals("res/layout/test_settings.xml", table.entry(table.identifier("layout", "test_settings"))!!.value.string)
        assertEquals(0, table.identifier("string", "missing"))
        assertNull(table.entry(0x7f7f0001))
    }

    @Test
    fun `values of every kind keep their types`() {
        val table = table()
        val accent = table.entry(table.identifier("color", "accent"))!!.value
        assertTrue(accent.type in Arsc.TYPE_FIRST_COLOR_INT..Arsc.TYPE_LAST_COLOR_INT)
        assertEquals(0xFF336699.toInt(), accent.data)
        val gap = table.entry(table.identifier("dimen", "gap"))!!.value
        assertEquals(Arsc.TYPE_DIMENSION, gap.type)
        assertEquals(16f, Arsc.complexToFloat(gap.data))
        assertEquals(1, gap.data and 0xf, "dp")
        assertEquals(Arsc.TYPE_INT_BOOLEAN, table.entry(table.identifier("bool", "flag"))!!.value.type)
        assertEquals(7, table.entry(table.identifier("integer", "count"))!!.value.data)
    }

    @Test
    fun `emoji survive the way aapt2 writes them`() {
        assertEquals("Movies 🎬", table().string("emoji"))
    }

    @Test
    fun `night values win over default ones`() {
        assertEquals("night", table().string("theme_probe"))
    }

    @Test
    fun `the app's language wins only where the extension ships it`() {
        assertEquals("हिन्दी", table("hi").string("language_probe"))
        assertEquals("SkyStream test settings", table("hi").string("title"), "not shipped in Hindi: the default")
        assertEquals("English", table("de").string("language_probe"))
    }

    @Test
    fun `sparse and compact tables read the same`() {
        assertTrue(0x01 in typeFlags(Fixtures.compactArsc), "the fixture has sparse entries to read")
        val plain = table()
        val compact = table(bytes = Fixtures.compactArsc)
        for (name in listOf("title", "emoji", "theme_probe", "language_probe", "save")) {
            assertEquals(plain.string(name), compact.string(name), name)
        }
        assertEquals(
            plain.entry(plain.identifier("array", "qualities"))!!.bagValues.map { it.string },
            compact.entry(compact.identifier("array", "qualities"))!!.bagValues.map { it.string },
        )
        assertEquals(7, compact.entry(compact.identifier("integer", "count"))!!.value.data)
    }

    /** The flags of each type chunk in [arsc] (0x01 sparse, 0x02 16-bit offsets). */
    private fun typeFlags(arsc: ByteArray): Set<Int> {
        val b = ByteBuffer.wrap(arsc).order(ByteOrder.LITTLE_ENDIAN)
        val flags = HashSet<Int>()
        var pos = b.getShort(2).toInt() and 0xffff
        while (pos + 8 <= arsc.size) {
            val size = b.getInt(pos + 4)
            if (b.getShort(pos).toInt() and 0xffff == 0x0200) {
                var inner = pos + (b.getShort(pos + 2).toInt() and 0xffff)
                while (inner < pos + size) {
                    if (b.getShort(inner).toInt() and 0xffff == 0x0201) flags += arsc[inner + 9].toInt() and 0xff
                    inner += b.getInt(inner + 4)
                }
            }
            pos += size
        }
        return flags
    }
}
