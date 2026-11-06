package dev.akash.cs3engine.stubs

import kotlin.test.Test
import kotlin.test.assertFailsWith
import kotlin.test.assertSame

class ClassProbesTest {
    /** As the engine's class loader makes one for an app class SkyStream lacks. */
    private class Made : Placeholder

    @Test
    fun `a probe finds a class as Class forName does`() {
        assertSame(String::class.java, ClassProbes.forName("java.lang.String"))
        assertSame(ClassProbesTest::class.java, ClassProbes.forName(ClassProbesTest::class.java.name, false, javaClass.classLoader))
    }

    @Test
    fun `a probe answers a placeholder as missing, as Android does for a class it lacks`() {
        assertFailsWith<ClassNotFoundException> { ClassProbes.forName(Made::class.java.name) }
        assertFailsWith<ClassNotFoundException> { ClassProbes.forName(Made::class.java.name, true, javaClass.classLoader) }
    }
}
