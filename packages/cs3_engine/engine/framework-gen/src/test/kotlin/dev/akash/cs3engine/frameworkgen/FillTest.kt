package dev.akash.cs3engine.frameworkgen

import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.Opcodes.ACC_ABSTRACT
import org.objectweb.asm.Opcodes.ACC_FINAL
import org.objectweb.asm.Opcodes.ACC_INTERFACE
import org.objectweb.asm.Opcodes.ACC_PRIVATE
import org.objectweb.asm.Opcodes.ACC_PUBLIC
import org.objectweb.asm.Opcodes.ACC_STATIC
import org.objectweb.asm.Opcodes.ACC_SUPER
import org.objectweb.asm.Opcodes.ALOAD
import org.objectweb.asm.Opcodes.ARETURN
import org.objectweb.asm.Opcodes.GETFIELD
import org.objectweb.asm.Opcodes.INVOKESPECIAL
import org.objectweb.asm.Opcodes.PUTFIELD
import org.objectweb.asm.Opcodes.RETURN
import java.io.DataInputStream
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class FillTest {
    private val pub = ACC_PUBLIC
    private val obj = "Ljava/lang/Object;"
    private val iface = ACC_PUBLIC or ACC_INTERFACE or ACC_ABSTRACT

    /** `public <init>()` calling `super()`. */
    private fun ClassVisitor.constructor(superName: String) {
        visitMethod(pub, "<init>", "()V", null, null).apply {
            visitCode()
            visitVarInsn(ALOAD, 0)
            visitMethodInsn(INVOKESPECIAL, superName, "<init>", "()V", false)
            visitInsn(RETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
    }

    /** A field with a setter that stores into it (returning `this` when [returns] is given) and a getter. */
    private fun ClassVisitor.property(owner: String, field: String, setter: String, getter: String, returns: String? = null) {
        visitField(ACC_PRIVATE, field, obj, null, null).visitEnd()
        visitMethod(pub, setter, "($obj)${returns ?: "V"}", null, null).apply {
            visitCode()
            visitVarInsn(ALOAD, 0)
            visitVarInsn(ALOAD, 1)
            visitFieldInsn(PUTFIELD, owner, field, obj)
            if (returns != null) {
                visitVarInsn(ALOAD, 0)
                visitInsn(ARETURN)
            } else {
                visitInsn(RETURN)
            }
            visitMaxs(0, 0)
            visitEnd()
        }
        visitMethod(pub, getter, "()$obj", null, null).apply {
            visitCode()
            visitVarInsn(ALOAD, 0)
            visitFieldInsn(GETFIELD, owner, field, obj)
            visitInsn(ARETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
    }

    private fun entries(vararg classes: Pair<String, ByteArray>) = classes.map { (name, bytes) -> "$name.class" to bytes }.toTypedArray()

    /** Hand-written View, TextView, Builder and MaterialBuilder, and Android's View, TextView, Button and builders. */
    private fun widgets(): Pair<File, File> {
        val standIns = jarOf(
            *entries(
                "android/test/View" to classBytes("android/test/View") {
                    constructor("java/lang/Object")
                    property("android/test/View", "tag", "setTag", "getTag")
                },
                "android/test/TextView" to classBytes("android/test/TextView", superName = "android/test/View") {
                    constructor("android/test/View")
                    property("android/test/TextView", "text", "setText", "getText")
                },
                "android/test/Builder" to classBytes("android/test/Builder") {
                    constructor("java/lang/Object")
                    property("android/test/Builder", "title", "setTitle", "getTitle", returns = "Landroid/test/Builder;")
                },
                "android/test/MaterialBuilder" to classBytes("android/test/MaterialBuilder", superName = "android/test/Builder") {
                    constructor("android/test/Builder")
                },
            ),
            "META-INF/MANIFEST.MF" to "Manifest-Version: 1.0\n".toByteArray(),
            "dev/akash/strings.txt" to "kept".toByteArray(),
        )
        val real = jarOf(
            *entries(
                "android/test/View" to classBytes("android/test/View") {
                    declare(pub, "<init>", "()V")
                    declare(pub, "setTag", "($obj)V")
                    declare(pub, "getTag", "()$obj")
                    declare(pub, "setAlpha", "(F)V")
                    declare(pub, "isShown", "()Z")
                },
                "android/test/TextView" to classBytes("android/test/TextView", superName = "android/test/View") {
                    declare(pub, "<init>", "($obj)V")
                    declare(pub, "setText", "($obj)V")
                    declare(pub, "getText", "()$obj")
                    declare(pub, "getTag", "()$obj")
                    declare(pub, "setTextColor", "(I)V")
                    declare(pub, "append", "($obj)Landroid/test/TextView;")
                },
                "android/test/Button" to classBytes("android/test/Button", superName = "android/test/TextView") {
                    declare(pub, "<init>", "($obj)V")
                    declare(pub, "setText", "($obj)V")
                    declare(pub, "getTag", "()$obj")
                    declare(pub, "performClick", "()Z")
                },
                "android/test/Builder" to classBytes("android/test/Builder") {
                    declare(pub, "<init>", "()V")
                    declare(pub, "setTitle", "($obj)Landroid/test/Builder;")
                },
                "android/test/MaterialBuilder" to classBytes("android/test/MaterialBuilder", superName = "android/test/Builder") {
                    declare(pub, "<init>", "()V")
                    declare(pub, "setTitle", "($obj)Landroid/test/MaterialBuilder;")
                },
                "android/test/OtherBuilder" to classBytes("android/test/OtherBuilder", superName = "android/test/Builder") {
                    declare(pub, "<init>", "()V")
                    declare(pub, "setTitle", "($obj)Landroid/test/OtherBuilder;")
                    declare(pub, "setIcon", "(I)Landroid/test/OtherBuilder;")
                },
            ),
            fileName = "android.jar",
        )
        return standIns to real
    }

    /** Loads the classes [dir] holds, the way the engine's host loads the filled stand-ins. */
    private class Loader(private val dir: File) : ClassLoader(FillTest::class.java.classLoader) {
        override fun findClass(name: String): Class<*> {
            val file = File(dir, name.replace('.', '/') + ".class")
            if (!file.isFile) throw ClassNotFoundException(name)
            val bytes = file.readBytes()
            return defineClass(name, bytes, 0, bytes.size)
        }

        override fun findResource(name: String) = File(dir, name).takeIf { it.isFile }?.toURI()?.toURL()
    }

    private fun indexed(out: File, name: String): ClassSig? =
        File(out, FrameworkIndex.path(name)).takeIf { it.isFile }?.inputStream()?.use { ClassSig.read(DataInputStream(it)) }

    private fun fill(standIns: File, real: File): Pair<Fill.Report, File> {
        val out = createTempDirectory("fill").toFile()
        return Fill.run(standIns, out, listOf(real)) to out
    }

    @Test
    fun `stand-ins get what they lack as no-ops, and keep what they implement`() {
        val (standIns, real) = widgets()
        val (report, out) = fill(standIns, real)
        assertEquals(4, report.standIns)
        assertEquals(6, report.methodsAdded, "View's setAlpha and isShown; TextView's constructor, setTextColor and append; MaterialBuilder's setTitle")
        val textView = Loader(out).loadClass("android.test.TextView")
        val view = textView.getConstructor(Any::class.java).newInstance("context")
        textView.getMethod("setText", Any::class.java).invoke(view, "hello")
        assertEquals("hello", textView.getMethod("getText").invoke(view), "the hand-written setter still stores")
        textView.getMethod("setTag", Any::class.java).invoke(view, "tag")
        assertEquals("tag", textView.getMethod("getTag").invoke(view), "TextView gets no no-op over View's hand-written getTag")
        textView.getMethod("setTextColor", Int::class.javaPrimitiveType).invoke(view, 1)
        assertSame(view, textView.getMethod("append", Any::class.java).invoke(view, "x"), "a no-op returning its own class returns the object")
        textView.getMethod("setAlpha", Float::class.javaPrimitiveType).invoke(view, 0.5f)
        assertEquals(false, textView.getMethod("isShown").invoke(view))
        assertEquals("kept", File(out, "dev/akash/strings.txt").readText(), "the stand-ins' other files go along")
    }

    @Test
    fun `a stand-in's covariant override calls the hand-written method it narrows`() {
        val (standIns, real) = widgets()
        val (_, out) = fill(standIns, real)
        val material = Loader(out).loadClass("android.test.MaterialBuilder")
        val builder = material.getConstructor().newInstance()
        val setTitle = material.declaredMethods.single { it.name == "setTitle" }
        assertEquals(material, setTitle.returnType)
        assertSame(builder, setTitle.invoke(builder, "Restart required"))
        assertEquals("Restart required", material.getMethod("getTitle").invoke(builder), "the title is kept, not dropped by a no-op")
    }

    @Test
    fun `the index has every other framework class, never covering hand-written behaviour`() {
        val (standIns, real) = widgets()
        val (report, out) = fill(standIns, real)
        assertEquals(2, report.indexed)
        assertNull(indexed(out, "android/test/View"), "hand-written classes come from the host, not the index")
        val button = assertNotNull(indexed(out, "android/test/Button"))
        assertEquals(listOf("<init>", "performClick"), button.methods.map { it.name }, "setText and getTag stay the stand-ins'")
        val other = assertNotNull(indexed(out, "android/test/OtherBuilder"))
        assertEquals("($obj)Landroid/test/Builder;", other.methods.single { it.name == "setTitle" }.delegate)
        assertNull(other.methods.single { it.name == "setIcon" }.delegate)
        assertEquals(other.name, FrameworkIndex.read(Loader(out), "android/test/OtherBuilder")?.name)
    }

    @Test
    fun `a framework supertype the host needs is written whole`() {
        val standIns = jarOf(
            *entries(
                "android/test/Host" to classBytes("android/test/Host", interfaces = listOf("android/test/Listener")) {
                    constructor("java/lang/Object")
                },
            ),
        )
        val real = jarOf(
            *entries(
                "android/test/Host" to classBytes("android/test/Host", interfaces = listOf("android/test/Listener")) {
                    declare(pub, "<init>", "()V")
                    declare(pub, "onDone", "()V")
                },
                "android/test/Listener" to classBytes("android/test/Listener", access = iface) {
                    declare(pub or ACC_ABSTRACT, "onDone", "()V")
                },
            ),
            fileName = "android.jar",
        )
        val (report, out) = fill(standIns, real)
        assertEquals(1, report.supertypes)
        assertNull(indexed(out, "android/test/Listener"), "the host has it: the index doesn't")
        val host = Loader(out).loadClass("android.test.Host")
        assertEquals(listOf("android.test.Listener"), host.interfaces.map { it.name })
        host.getMethod("onDone").invoke(host.getConstructor().newInstance())
    }

    @Test
    fun `framework types a stand-in's members name are written whole, so the host can resolve its methods`() {
        // Android's Fragment has getDefaultViewModelProviderFactory(): ViewModelProvider.Factory. Filled with it,
        // the stand-in names a class only the extensions' loader would make, and the host couldn't resolve its
        // methods (Class.getDeclaredMethods, as Java reflection and JUnit's discovery call it) without it.
        val standIns = jarOf(*entries("android/test/Holder" to classBytes("android/test/Holder") { constructor("java/lang/Object") }))
        val real = jarOf(
            *entries(
                "android/test/Holder" to classBytes("android/test/Holder") {
                    declare(pub, "<init>", "()V")
                    declare(pub, "factory", "()Landroid/test/Factory;")
                },
                "android/test/Factory" to classBytes("android/test/Factory", access = iface, interfaces = listOf("android/test/Base")),
                "android/test/Base" to classBytes("android/test/Base", access = iface),
                "android/test/Unrelated" to classBytes("android/test/Unrelated"),
            ),
            fileName = "android.jar",
        )
        val (report, out) = fill(standIns, real)
        assertEquals(2, report.supertypes, "Factory, and Base, which Factory needs to load")
        assertNull(indexed(out, "android/test/Factory"), "the host has it: the index doesn't")
        assertNotNull(indexed(out, "android/test/Unrelated"))
        val holder = Loader(out).loadClass("android.test.Holder")
        assertEquals("android.test.Factory", holder.declaredMethods.single { it.name == "factory" }.returnType.name)
    }

    @Test
    fun `stand-ins that disagree with Android stop the build`() {
        val standIns = jarOf(
            *entries(
                "android/test/Flags" to classBytes("android/test/Flags") {
                    visitField(pub or ACC_STATIC or ACC_FINAL, "FLAG", "I", null, 2).visitEnd()
                },
                "android/test/Other" to classBytes("android/test/Other"),
                "android/test/Widget" to classBytes("android/test/Widget", superName = "android/test/Other"),
                "android/test/Sealed" to classBytes("android/test/Sealed", access = pub or ACC_SUPER or ACC_FINAL),
                "android/test/Kind" to classBytes("android/test/Kind"),
                "android/test/Clock" to classBytes("android/test/Clock", superName = "java/lang/Thread"),
            ),
        )
        val real = jarOf(
            *entries(
                "android/test/Flags" to classBytes("android/test/Flags") {
                    visitField(pub or ACC_STATIC or ACC_FINAL, "FLAG", "I", null, 1).visitEnd()
                },
                "android/test/Other" to classBytes("android/test/Other"),
                "android/test/Base" to classBytes("android/test/Base"),
                "android/test/Widget" to classBytes("android/test/Widget", superName = "android/test/Base"),
                "android/test/Sealed" to classBytes("android/test/Sealed"),
                "android/test/Kind" to classBytes("android/test/Kind", access = iface),
                "android/test/Clock" to classBytes("android/test/Clock"),
            ),
            fileName = "android.jar",
        )
        val message = assertFailsWith<IllegalStateException> { fill(standIns, real) }.message.orEmpty()
        assertContains(message, "android/test/Flags.FLAG is 2, Android's is 1")
        assertContains(message, "android/test/Widget extends android/test/Other")
        assertContains(message, "android/test/Sealed is final")
        assertContains(message, "android/test/Kind is an interface in Android")
        assertFalse("android/test/Clock" in message, "a JDK superclass is the stand-in's own way of working")
    }

    @Test
    fun `a stand-in lacking what its interface asks stops the build`() {
        val standIns = jarOf(
            *entries(
                "android/test/Callback" to classBytes("android/test/Callback", access = iface),
                "dev/test/Impl" to classBytes("dev/test/Impl", interfaces = listOf("android/test/Callback")) {
                    constructor("java/lang/Object")
                },
            ),
        )
        val real = jarOf(
            *entries(
                "android/test/Callback" to classBytes("android/test/Callback", access = iface) {
                    declare(pub or ACC_ABSTRACT, "onEvent", "()V")
                },
            ),
            fileName = "android.jar",
        )
        val message = assertFailsWith<IllegalStateException> { fill(standIns, real) }.message.orEmpty()
        assertContains(message, "dev/test/Impl lacks android/test/Callback.onEvent()V")
        assertTrue(message.lines().size >= 2)
    }

    @Test
    fun `a concrete stand-in lacking an abstract method its superclass gains stops the build`() {
        // The fill gives an abstract stand-in Android's abstract methods (ActivityResultLauncher's), which a
        // concrete stand-in below it, the engine's own launcher, must then implement.
        val abstractClass = pub or ACC_SUPER or ACC_ABSTRACT
        val standIns = jarOf(
            *entries(
                "android/test/Base" to classBytes("android/test/Base", access = abstractClass) {
                    constructor("java/lang/Object")
                },
                "dev/test/Concrete" to classBytes("dev/test/Concrete", superName = "android/test/Base") {
                    constructor("android/test/Base")
                },
            ),
        )
        val real = jarOf(
            *entries(
                "android/test/Base" to classBytes("android/test/Base", access = abstractClass) {
                    declare(pub, "<init>", "()V")
                    declare(pub or ACC_ABSTRACT, "run", "()V")
                },
            ),
            fileName = "android.jar",
        )
        val message = assertFailsWith<IllegalStateException> { fill(standIns, real) }.message.orEmpty()
        assertContains(message, "dev/test/Concrete lacks android/test/Base.run()V")
    }

    @Test
    fun `a stand-in on a JDK superclass keeps the JDK's methods, final ones included`() {
        // android.icu's SimpleDateFormat stand-in works through java.text's: a no-op over parse answered null,
        // and one over DateFormat's final format(Date) stopped the class loading at all.
        val standIns = jarOf(
            *entries(
                "android/icu/test/Dates" to classBytes("android/icu/test/Dates", superName = "java/text/SimpleDateFormat") {
                    constructor("java/text/SimpleDateFormat")
                },
            ),
        )
        val real = jarOf(
            *entries(
                "android/icu/test/Dates" to classBytes("android/icu/test/Dates", superName = "android/icu/test/UFormat") {
                    declare(pub, "<init>", "()V")
                    declare(pub, "parse", "(Ljava/lang/String;)Ljava/util/Date;")
                    declare(pub or ACC_FINAL, "format", "(Ljava/util/Date;)Ljava/lang/String;")
                    declare(pub, "setIcuCalendar", "(I)V")
                },
            ),
            fileName = "android.jar",
        )
        val (report, out) = fill(standIns, real)
        assertEquals(1, report.methodsAdded, "ICU's own method only")
        val dates = Loader(out).loadClass("android.icu.test.Dates").getConstructor().newInstance() as java.text.SimpleDateFormat
        dates.applyPattern("yyyy-MM-dd")
        assertEquals("2024-01-02", dates.format(dates.parse("2024-01-02")))
    }

    @Test
    fun `Object's equals, hashCode and toString are never replaced by no-ops`() {
        // Android's Fragment declares all three. A no-op equals answers false even for the same object, so
        // `list.remove(fragment)` would never remove it.
        val objectMethods: ClassVisitor.() -> Unit = {
            declare(pub, "<init>", "()V")
            declare(pub, "equals", "($obj)Z")
            declare(pub, "hashCode", "()I")
            declare(pub, "toString", "()Ljava/lang/String;")
        }
        val standIns = jarOf(*entries("android/test/Token" to classBytes("android/test/Token") { constructor("java/lang/Object") }))
        val real = jarOf(
            *entries(
                "android/test/Token" to classBytes("android/test/Token", members = objectMethods),
                "android/test/Pair" to classBytes("android/test/Pair", members = objectMethods),
            ),
            fileName = "android.jar",
        )
        val (report, out) = fill(standIns, real)
        assertEquals(0, report.methodsAdded)
        val token = Loader(out).loadClass("android.test.Token")
        val one = token.getConstructor().newInstance()
        assertTrue(one == one && one != token.getConstructor().newInstance())
        assertEquals(System.identityHashCode(one), one.hashCode())
        assertTrue(one.toString().startsWith("android.test.Token@"))
        assertEquals(listOf("<init>"), assertNotNull(indexed(out, "android/test/Pair")).methods.map { it.name })
    }
}
