package dev.akash.cs3engine.stubs

import android.content.res.Resources
import org.xmlpull.v1.XmlPullParser
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertSame
import kotlin.test.assertTrue

class ResourcesTest {
    private val loader = ResourcesTest::class.java.classLoader
    private val res = Resources.of(Fixtures.cs3, loader)
    private fun id(type: String, name: String) = res.getIdentifier(name, type, "dev.akash.cs3test")

    @AfterTest
    fun language() {
        System.clearProperty("cs3.language")
    }

    @Test
    fun `an extension's words and values come from its own table`() {
        assertEquals("SkyStream test settings", res.getString(id("string", "title")))
        assertEquals(listOf("480p", "720p", "1080p"), res.getStringArray(id("array", "qualities")).toList())
        assertEquals(0xFF336699.toInt(), res.getColor(id("color", "accent")))
        assertEquals(32, res.getDimensionPixelSize(id("dimen", "gap")), "16dp at density 2")
        assertEquals(32f, res.getDimension(id("dimen", "gap")))
        assertTrue(res.getBoolean(id("bool", "flag")))
        assertEquals(7, res.getInteger(id("integer", "count")))
        assertEquals("Hello, Akash", res.getString(id("string", "greeting"), "Akash"))
        assertEquals("dev.akash.cs3test:string/title", res.getResourceName(id("string", "title")))
        assertEquals("title", res.getResourceEntryName(id("string", "title")))
        assertEquals("string", res.getResourceTypeName(id("string", "title")))
    }

    @Test
    fun `a missing id throws NotFoundException, as on Android`() {
        assertFailsWith<Resources.NotFoundException> { res.getString(0x7f7f0001) }
        assertFailsWith<Resources.NotFoundException> { res.getColor(id("string", "title")) }
        assertFailsWith<Resources.NotFoundException> { res.getLayout(id("string", "title")) }
        assertEquals(0, id("string", "missing"))
    }

    @Test
    fun `night values win, and the app's language where the extension ships it, emoji intact`() {
        assertEquals("night", res.getString(id("string", "theme_probe")))
        assertEquals("English", res.getString(id("string", "language_probe")))
        assertEquals("Movies 🎬", res.getString(id("string", "emoji")))
        System.setProperty("cs3.language", "hi")
        val hindi = Resources.of(Fixtures.cs3, loader)
        assertEquals("हिन्दी", hindi.getString(id("string", "language_probe")))
        assertEquals("SkyStream test settings", hindi.getString(id("string", "title")), "not shipped in Hindi: the default")
        assertEquals("hi", hindi.configuration.locales[0].language)
    }

    @Test
    fun `the app's language finds the extension's strings by language, region and script, old codes too`() {
        fun probe(tag: String): String {
            System.setProperty("cs3.language", tag)
            return Resources.of(Fixtures.cs3, loader).getString(id("string", "language_probe"))
        }
        assertEquals("Português (Brasil)", probe("pt-BR"), "a region's own values first")
        assertEquals("Português", probe("pt"), "a bare language takes the values without a region")
        assertEquals("Português", probe("pt-PT"), "another region falls back to the language's")
        assertEquals("繁體中文", probe("zh-Hant"))
        assertEquals("עברית", probe("he"), "Hebrew's old code iw")
        assertEquals("English", probe("de"), "not shipped: the default")
    }

    @Test
    fun `Android's common strings are there for the app and every extension`() {
        assertEquals("OK", Resources.getSystem().getString(android.R.string.ok))
        assertEquals("Cancel", res.getString(android.R.string.cancel))
        assertEquals("Yes", res.getText(android.R.string.yes).toString())
        assertFailsWith<Resources.NotFoundException> { Resources.getSystem().getString(0x7f010001) }
    }

    @Test
    fun `a layout opens as a parser that knows where it came from`() {
        val parser = res.getLayout(id("layout", "test_settings")) as Axml
        assertSame(res, parser.resources)
        assertSame(loader, parser.classLoader)
        assertEquals(XmlPullParser.START_TAG, parser.nextTag())
        assertEquals("LinearLayout", parser.name)
    }

    @Test
    fun `getIdentifier takes a full name or a type, in the extension's package only`() {
        val title = id("string", "title")
        assertEquals(title, res.getIdentifier("dev.akash.cs3test:string/title", null, null))
        assertEquals(title, res.getIdentifier("string/title", null, "dev.akash.cs3test"))
        assertEquals(title, res.getIdentifier("title", "string", null))
        assertEquals(0, res.getIdentifier("title", "string", "dev.akash.cs3engine"), "the app's package isn't the extension's")
    }

    @Test
    fun `an extension without a table gets inert resources, not a crash`() {
        val dir = createTempDirectory("no-table").toFile()
        val bare = zip(File(dir, "Bare.cs3"), "manifest.json" to "{}".toByteArray())
        val broken = zip(File(dir, "Broken.cs3"), "resources.arsc" to byteArrayOf(1, 2, 3))
        for (file in listOf(bare, broken)) {
            val inert = Resources.of(file, loader)
            assertEquals(0, inert.getIdentifier("title", "string", "dev.akash.cs3test"))
            assertFailsWith<Resources.NotFoundException> { inert.getString(0x7f010001) }
            assertEquals("OK", inert.getString(android.R.string.ok))
        }
    }

    @Test
    fun `assets open from the extension's file`() {
        val arsc = ZipFile(Fixtures.cs3).use { zip -> zip.getInputStream(zip.getEntry("resources.arsc")).readBytes() }
        val file = zip(
            File(createTempDirectory("assets").toFile(), "Assets.cs3"),
            "resources.arsc" to arsc,
            "assets/providers.json" to """["a","b"]""".toByteArray(),
        )
        val assets = Resources.of(file, loader).assets
        assertEquals("""["a","b"]""", assets.open("providers.json").reader().readText())
        assertEquals(listOf("providers.json"), assets.list("").toList())
        assertFailsWith<java.io.FileNotFoundException> { assets.open("missing.json") }
    }

    @Test
    fun `a theme answers with what Android gives for unset attributes`() {
        val theme = res.newTheme()
        assertEquals(2, theme.obtainStyledAttributes(intArrayOf(1, 2)).length())
        assertEquals(false, theme.resolveAttribute(1, android.util.TypedValue(), true))
        assertSame(res, theme.resources)
    }

    @Test
    fun `a context's theme is its resources', the same each time, and a wrapper's is its base's`() {
        val context = android.content.Context()
        assertSame(context.theme, context.theme)
        assertSame(context.resources, context.theme.resources)
        assertSame(context.theme, android.content.ContextWrapper(context).theme)
    }

    @Test
    fun `a context's strings come through its own resources, a wrapper's too, as Android's final methods go`() {
        val title = id("string", "title")
        val wrapper = object : android.content.ContextWrapper(android.content.Context()) {
            override fun getResources(): Resources = res
        }
        assertEquals(res.getString(title), wrapper.getString(title))
        assertEquals(res.getString(title), wrapper.getText(title).toString())
        assertEquals(res.getString(title), wrapper.getString(title, "unused"))
    }

    private fun zip(file: File, vararg entries: Pair<String, ByteArray>): File {
        ZipOutputStream(file.outputStream()).use { out ->
            for ((name, bytes) in entries) {
                out.putNextEntry(ZipEntry(name))
                out.write(bytes)
                out.closeEntry()
            }
        }
        return file
    }
}
