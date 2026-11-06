package dev.akash.cs3engine.frameworkgen

import org.objectweb.asm.Opcodes.ACC_ABSTRACT
import org.objectweb.asm.Opcodes.ACC_ENUM
import org.objectweb.asm.Opcodes.ACC_FINAL
import org.objectweb.asm.Opcodes.ACC_INTERFACE
import org.objectweb.asm.Opcodes.ACC_PUBLIC
import org.objectweb.asm.Opcodes.ACC_STATIC
import org.objectweb.asm.Opcodes.ACC_SUPER
import org.objectweb.asm.Type
import java.lang.reflect.Modifier
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** A hand-written stand-in's shape, for generated subclasses to chain to and inherit from. */
open class HandView(val context: Any?) {
    open fun title(): String = "hand"
}

open class HandBuilder {
    var title: CharSequence? = null

    open fun setTitle(title: CharSequence?): HandBuilder {
        this.title = title
        return this
    }
}

class NoOpClassTest {
    private class Loader : ClassLoader(NoOpClassTest::class.java.classLoader) {
        fun define(bytes: ByteArray, name: String): Class<*> = defineClass(name.replace('/', '.'), bytes, 0, bytes.size)
    }

    private val hand = Type.getInternalName(HandView::class.java)
    private val handBuilder = Type.getInternalName(HandBuilder::class.java)

    /** A host class's constructors, as the runtime finds them: by reflection. */
    private fun constructorsOf(internalName: String): List<String> =
        Class.forName(internalName.replace('/', '.')).declaredConstructors
            .filter { Modifier.isPublic(it.modifiers) || Modifier.isProtected(it.modifiers) }
            .map { Type.getConstructorDescriptor(it) }

    private fun load(sig: ClassSig): Class<*> = Loader().define(NoOpClass.generate(sig, ::constructorsOf), sig.name)

    private fun newInstance(type: Class<*>): Any = type.getDeclaredConstructor().apply { isAccessible = true }.newInstance()

    @Test
    fun `methods do nothing — defaults, null, or the object itself where they return its own class`() {
        val sig = ClassSig(
            "android/test/Builder", ACC_PUBLIC or ACC_SUPER, "java/lang/Object", emptyList(), emptyList(),
            listOf(
                MethodSig(ACC_PUBLIC, "setTitle", "(Ljava/lang/CharSequence;)Landroid/test/Builder;"),
                MethodSig(ACC_PUBLIC, "count", "()I"),
                MethodSig(ACC_PUBLIC, "ratio", "()F"),
                MethodSig(ACC_PUBLIC, "size", "()J"),
                MethodSig(ACC_PUBLIC, "label", "()Ljava/lang/String;"),
                MethodSig(ACC_PUBLIC, "getValue", "()Ljava/lang/Object;"),
                MethodSig(ACC_PUBLIC, "run", "()V"),
                MethodSig(ACC_PUBLIC or ACC_STATIC, "make", "()Landroid/test/Builder;"),
            ),
        )
        val type = load(sig)
        val builder = newInstance(type)
        assertSame(builder, type.getMethod("setTitle", CharSequence::class.java).invoke(builder, "x"))
        assertEquals(0, type.getMethod("count").invoke(builder))
        assertEquals(0f, type.getMethod("ratio").invoke(builder))
        assertEquals(0L, type.getMethod("size").invoke(builder))
        assertNull(type.getMethod("label").invoke(builder))
        assertNull(type.getMethod("getValue").invoke(builder), "a supertype isn't its own class: LiveData.getValue() is no builder")
        type.getMethod("run").invoke(builder)
        assertNull(type.getMethod("make").invoke(null))
    }

    @Test
    fun `constructors chain to the closest one the superclass has, passing what they share`() {
        val sig = ClassSig(
            "android/test/Card", ACC_PUBLIC or ACC_SUPER, hand, emptyList(), emptyList(),
            listOf(MethodSig(ACC_PUBLIC, "<init>", "(Ljava/lang/Object;)V"), MethodSig(ACC_PUBLIC, "<init>", "(Ljava/lang/Object;I)V")),
        )
        val type = load(sig)
        val one = type.getConstructor(Any::class.java).newInstance("ctx") as HandView
        val two = type.getConstructor(Any::class.java, Int::class.javaPrimitiveType).newInstance("ctx", 3) as HandView
        assertEquals("ctx", one.context)
        assertEquals("ctx", two.context)
        assertEquals("hand", two.title(), "what the class doesn't declare stays the stand-in's")
        val bare = newInstance(type) as HandView
        assertNull(bare.context, "the generated no-argument constructor passes defaults")
    }

    @Test
    fun `abstract methods stay abstract, so an extension's subclass supplies them`() {
        val sig = ClassSig(
            "android/test/Callback", ACC_PUBLIC or ACC_SUPER or ACC_ABSTRACT, "java/lang/Object", emptyList(), emptyList(),
            listOf(MethodSig(ACC_PUBLIC or ACC_ABSTRACT, "onEvent", "(I)V"), MethodSig(ACC_PUBLIC, "other", "()V")),
        )
        val type = load(sig)
        assertTrue(Modifier.isAbstract(type.modifiers))
        assertTrue(Modifier.isAbstract(type.getMethod("onEvent", Int::class.javaPrimitiveType).modifiers))
        assertTrue(!Modifier.isAbstract(type.getMethod("other").modifiers))
    }

    @Test
    fun `an enum has its constants, in order, with values and valueOf`() {
        val own = "android/test/ScaleType"
        val constant = ACC_PUBLIC or ACC_STATIC or ACC_FINAL or ACC_ENUM
        val sig = ClassSig(
            own, ACC_PUBLIC or ACC_FINAL or ACC_SUPER or ACC_ENUM, "java/lang/Enum", emptyList(),
            listOf(FieldSig(constant, "CENTER", "L$own;"), FieldSig(constant, "FIT_XY", "L$own;")),
            listOf(
                MethodSig(ACC_PUBLIC or ACC_STATIC, "values", "()[L$own;"),
                MethodSig(ACC_PUBLIC or ACC_STATIC, "valueOf", "(Ljava/lang/String;)L$own;"),
            ),
        )
        val type = load(sig)
        assertEquals(listOf("CENTER", "FIT_XY"), type.enumConstants.map { (it as Enum<*>).name })
        assertSame(type.enumConstants[1], type.getMethod("valueOf", String::class.java).invoke(null, "FIT_XY"))
        assertEquals(2, (type.getMethod("values").invoke(null) as Array<*>).size)
        assertSame(type.enumConstants[0], type.getField("CENTER").get(null))
    }

    @Test
    fun `constants keep their values, as R ids do`() {
        val sig = ClassSig(
            "android/test/R\$id", ACC_PUBLIC or ACC_FINAL or ACC_SUPER, "java/lang/Object", emptyList(),
            listOf(FieldSig(ACC_PUBLIC or ACC_STATIC or ACC_FINAL, "design_bottom_sheet", "I", 0x7e010000)),
            emptyList(),
        )
        assertEquals(0x7e010000, load(sig).getField("design_bottom_sheet").get(null))
    }

    @Test
    fun `a covariant override of a hand-written method reaches it`() {
        val own = "android/test/MaterialBuilder"
        val sig = ClassSig(
            own, ACC_PUBLIC or ACC_SUPER, handBuilder, emptyList(), emptyList(),
            listOf(
                MethodSig(ACC_PUBLIC, "<init>", "()V"),
                MethodSig(ACC_PUBLIC, "setTitle", "(Ljava/lang/CharSequence;)L$own;", delegate = "(Ljava/lang/CharSequence;)L$handBuilder;"),
            ),
        )
        val type = load(sig)
        val builder = type.getConstructor().newInstance() as HandBuilder
        val method = type.methods.first { it.name == "setTitle" && it.returnType == type }
        assertSame(builder, method.invoke(builder, "Restart required"))
        assertEquals("Restart required", builder.title)
    }

    @Test
    fun `an interface's default and static methods do nothing, its abstract ones stay abstract`() {
        val sig = ClassSig(
            "android/test/Listener", ACC_PUBLIC or ACC_INTERFACE or ACC_ABSTRACT, "java/lang/Object", emptyList(), emptyList(),
            listOf(
                MethodSig(ACC_PUBLIC or ACC_ABSTRACT, "onChanged", "(I)V"),
                MethodSig(ACC_PUBLIC, "onReset", "()V"),
                MethodSig(ACC_PUBLIC or ACC_STATIC, "empty", "()Landroid/test/Listener;"),
            ),
        )
        val type = load(sig)
        assertTrue(type.isInterface)
        assertTrue(Modifier.isAbstract(type.getMethod("onChanged", Int::class.javaPrimitiveType).modifiers))
        assertTrue(type.getMethod("onReset").isDefault)
        assertNull(type.getMethod("empty").invoke(null))
    }
}
