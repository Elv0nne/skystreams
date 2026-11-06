package com.lingjhf.vlc_player

import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class VlcFontWarmupTest {
    private val home = createTempDirectory("vlc-home").toFile()
    private val cache = VlcFontWarmup.cacheDirectory(home)

    @AfterTest
    fun cleanUp() {
        home.deleteRecursively()
    }

    @Test
    fun theCacheLivesUnderLibVlcsHome() {
        assertEquals(File(home, ".cache/fontconfig"), cache)
    }

    @Test
    fun aMissingCacheNeedsTheDatabase() {
        assertTrue(VlcFontWarmup.needsDatabase(cache))
    }

    @Test
    fun aCacheWithOnlyItsTagNeedsTheDatabase() {
        cache.mkdirs()
        File(cache, "CACHEDIR.TAG").writeText("Signature: 8a477f597d28d172789f06886806bc55")
        assertTrue(VlcFontWarmup.needsDatabase(cache))
    }

    @Test
    fun aCacheFileMeansTheDatabaseIsBuilt() {
        cache.mkdirs()
        File(cache, "3336a65c52528c9c368e942d3dd307f8-aarch64.cache-7").writeBytes(ByteArray(8))
        assertFalse(VlcFontWarmup.needsDatabase(cache))
    }

    @Test
    fun startsOnceHoweverOftenAsked() {
        val started = AtomicBoolean(false)
        var launches = 0
        repeat(3) { VlcFontWarmup.startOnce(started, cache) { launches += 1 } }
        assertEquals(1, launches)
    }

    @Test
    fun doesNotStartWhenTheDatabaseIsBuilt() {
        cache.mkdirs()
        File(cache, "3336a65c52528c9c368e942d3dd307f8-aarch64.cache-7").writeBytes(ByteArray(8))
        val started = AtomicBoolean(false)
        var launches = 0
        assertFalse(VlcFontWarmup.startOnce(started, cache) { launches += 1 })
        assertEquals(0, launches)
        assertFalse(started.get())
    }
}
