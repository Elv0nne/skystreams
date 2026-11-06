package dev.akash.cs3engine.jvm

import android.content.Context
import android.content.res.Resources
import android.graphics.drawable.Drawable
import java.io.File
import java.lang.invoke.MethodHandles
import java.lang.invoke.MethodType
import java.util.zip.ZipFile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The stand-ins as shipped, filled: what the engine's host gives every extension. */
class FilledStandInsTest {
    @Test
    fun `every class in the filled stand-ins loads`() {
        val jar = File(Context::class.java.protectionDomain.codeSource.location.toURI())
        val failures = ZipFile(jar).use { zip ->
            zip.entries().toList().filter { it.name.endsWith(".class") }.mapNotNull { entry ->
                val name = entry.name.removeSuffix(".class").replace('/', '.')
                try {
                    Class.forName(name, false, javaClass.classLoader)
                    null
                } catch (e: Throwable) {
                    "$name: $e"
                }
            }
        }
        assertTrue(jar.name == "android-stubs.jar" && jar.path.contains("filled"), "the filled jar comes first: $jar")
        assertTrue(failures.isEmpty(), failures.joinToString("\n"))
    }

    @Test
    fun `ResourcesCompat's drawables are Resources', never null — 35 extensions' icons`() {
        // As an extension gets it, and linked as its call links: only the method it names.
        val compat = FrameworkClassLoader(javaClass.classLoader).loadClass("androidx.core.content.res.ResourcesCompat")
        val type = MethodType.methodType(Drawable::class.java, Resources::class.java, Int::class.java, Resources.Theme::class.java)
        val getDrawable = MethodHandles.publicLookup().findStatic(compat, "getDrawable", type)
        val resources = Resources.of(File(javaClass.getResource("/SkyStreamTest.cs3")!!.toURI()), javaClass.classLoader)
        val accent = resources.getIdentifier("accent", "color", "dev.akash.cs3test")
        val drawable = getDrawable.invoke(resources, accent, null) as Drawable?
        assertEquals(resources.getDrawable(accent, null).javaClass, drawable?.javaClass)
    }
}
