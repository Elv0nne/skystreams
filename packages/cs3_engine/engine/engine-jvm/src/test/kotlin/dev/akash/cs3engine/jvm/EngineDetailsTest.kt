package dev.akash.cs3engine.jvm

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import dev.akash.cs3engine.Engine
import dev.akash.cs3engine.host.HostHooks
import dev.akash.cs3engine.stubs.MainThread
import dev.akash.cs3engine.stubs.Platform
import dev.akash.cs3engine.stubs.Ui
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The test extension's rich title through the engine's protocol: what SkyStream's details page reads (Part 1). */
class EngineDetailsTest {
    private val mapper = jacksonObjectMapper()
    private var nextId = 0

    @AfterTest
    fun restore() {
        HostHooks.event = {}
        Platform.install(null)
        Ui.setListener(null)
        MainThread.setAfterTask(null)
        Ui.windows().forEach { Ui.dismissed(it.owner) }
    }

    private fun Engine.call(method: String, vararg params: Pair<String, Any?>): JsonNode {
        val request = mapper.writeValueAsString(mapOf("id" to ++nextId, "method" to method, "params" to mapOf(*params)))
        val response = mapper.readTree(runBlocking { respond(request) })
        check(response.has("result")) { "$method failed: $response" }
        return response["result"]
    }

    @Test
    fun `an extension's rich title comes through load with everything SkyStream shows`() {
        val dataDir = createTempDirectory("engine-details").toFile()
        val engine = JvmEngine.create(dataDir, "test")
        val fixture = File(javaClass.getResource("/SkyStreamTest.cs3")!!.toURI())
        val plugin = File(dataDir, "plugins/SkyStreamTest.cs3").apply { parentFile.mkdirs(); fixture.copyTo(this) }
        engine.call("loadPlugin", "path" to plugin.path)

        val title = engine.call(
            "load",
            "provider" to "SkyStream Test A",
            "url" to "https://skystream.invalid/anime/rich",
            "plugin" to plugin.path,
        )

        assertEquals("Rich Title", title["name"].asText())
        assertEquals(8.81, title["score"].asDouble(), 1e-9)
        assertEquals("Ongoing", title["showStatus"].asText())
        assertEquals("52991", title["syncIds"]["mal"].asText())
        assertEquals("154587", title["syncIds"]["anilist"].asText())
        assertEquals(3, title["actors"].size())
        assertEquals("Atsumi Tanezaki", title["actors"][0]["voiceActor"]["name"].asText())
        assertEquals("Second Arc", title["seasonNames"][1]["name"].asText())
        assertEquals("Rich Sequel", title["recommendations"][0]["name"].asText())
        assertEquals(24, title["episodes"][0]["runTime"].asInt())
        assertTrue(title["nextAiring"]["unixTime"].asLong() > System.currentTimeMillis() / 1000)
    }
}
