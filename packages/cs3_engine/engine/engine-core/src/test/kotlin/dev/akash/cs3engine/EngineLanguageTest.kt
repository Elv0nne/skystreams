package dev.akash.cs3engine

import android.content.Context
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals

class EngineLanguageTest {
    private object NoPlugins : PluginLoader {
        override fun prepare(file: File) = PreparedPlugin(EngineLanguageTest::class.java.classLoader)
    }

    @AfterTest
    fun clear() {
        System.clearProperty("cs3.language")
    }

    @Test
    fun `the app's language is what extensions' resources follow from then on`() = runBlocking {
        val engine = Engine(NoPlugins, { Context() }, "test")
        assertEquals(mapOf("language" to "hi"), engine.execute("setLanguage", Json.mapper.valueToTree(mapOf("language" to "hi"))))
        assertEquals("hi", System.getProperty("cs3.language"))
        Unit
    }
}
