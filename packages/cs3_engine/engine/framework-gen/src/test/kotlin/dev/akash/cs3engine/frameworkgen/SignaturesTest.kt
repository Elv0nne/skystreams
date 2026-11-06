package dev.akash.cs3engine.frameworkgen

import org.objectweb.asm.ClassReader
import org.objectweb.asm.Opcodes.ACC_ABSTRACT
import org.objectweb.asm.Opcodes.ACC_BRIDGE
import org.objectweb.asm.Opcodes.ACC_ENUM
import org.objectweb.asm.Opcodes.ACC_FINAL
import org.objectweb.asm.Opcodes.ACC_PRIVATE
import org.objectweb.asm.Opcodes.ACC_PROTECTED
import org.objectweb.asm.Opcodes.ACC_PUBLIC
import org.objectweb.asm.Opcodes.ACC_STATIC
import org.objectweb.asm.Opcodes.ACC_SUPER
import org.objectweb.asm.Opcodes.ACC_SYNTHETIC
import org.objectweb.asm.tree.ClassNode
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SignaturesTest {
    private fun node(bytes: ByteArray) = ClassNode().also { ClassReader(bytes).accept(it, ClassReader.SKIP_CODE) }

    @Test
    fun `a class's signature keeps its public and protected members and its bridges, without private or other synthetic ones`() {
        val bytes = classBytes("android/widget/Thing", superName = "android/view/View", interfaces = listOf("android/widget/Checkable")) {
            visitField(ACC_PUBLIC or ACC_STATIC or ACC_FINAL, "MODE", "I", null, 3).visitEnd()
            visitField(ACC_PRIVATE, "secret", "I", null, null).visitEnd()
            declare(ACC_PUBLIC, "<init>", "(Landroid/content/Context;)V")
            declare(ACC_PROTECTED, "onDraw", "(Landroid/graphics/Canvas;)V")
            declare(ACC_PRIVATE, "hidden", "()V")
            declare(ACC_PUBLIC or ACC_SYNTHETIC, "access\$000", "()V")
            declare(ACC_PUBLIC or ACC_BRIDGE or ACC_SYNTHETIC, "getText", "()Ljava/lang/Object;")
            declare(ACC_STATIC, "<clinit>", "()V")
        }
        val sig = ClassSig.of(node(bytes))
        assertEquals("android/view/View", sig.superName)
        assertEquals(listOf("android/widget/Checkable"), sig.interfaces)
        assertEquals(listOf("MODE"), sig.fields.map { it.name })
        assertEquals(3, sig.fields.single().value)
        assertEquals(listOf("<init>", "onDraw", "getText"), sig.methods.map { it.name })
        assertEquals("onDraw(Landroid/graphics/Canvas;)", sig.methods[1].parameters)
    }

    @Test
    fun `a signature survives being written and read back, constants and delegates included`() {
        val sig = ClassSig(
            "android/widget/ImageView\$ScaleType",
            ACC_PUBLIC or ACC_FINAL or ACC_SUPER or ACC_ENUM,
            "java/lang/Enum",
            listOf("java/io/Serializable"),
            listOf(
                FieldSig(ACC_PUBLIC or ACC_STATIC or ACC_FINAL or ACC_ENUM, "CENTER", "Landroid/widget/ImageView\$ScaleType;"),
                FieldSig(ACC_PUBLIC or ACC_STATIC or ACC_FINAL, "I", "I", 7),
                FieldSig(ACC_PUBLIC or ACC_STATIC or ACC_FINAL, "L", "J", 8L),
                FieldSig(ACC_PUBLIC or ACC_STATIC or ACC_FINAL, "F", "F", 1.5f),
                FieldSig(ACC_PUBLIC or ACC_STATIC or ACC_FINAL, "D", "D", 2.5),
                FieldSig(ACC_PUBLIC or ACC_STATIC or ACC_FINAL, "S", "Ljava/lang/String;", "café 🎬"),
            ),
            listOf(MethodSig(ACC_PUBLIC, "setTitle", "(Ljava/lang/CharSequence;)Lx/Builder;", delegate = "(Ljava/lang/CharSequence;)Ly/Builder;")),
        )
        val bytes = ByteArrayOutputStream().also { sig.write(DataOutputStream(it)) }.toByteArray()
        val back = ClassSig.read(DataInputStream(ByteArrayInputStream(bytes)))
        assertEquals(sig.name, back.name)
        assertEquals(sig.access, back.access)
        assertEquals(sig.superName, back.superName)
        assertEquals(sig.interfaces, back.interfaces)
        assertEquals(sig.fields.map { it.name to it.value }, back.fields.map { it.name to it.value })
        assertEquals("(Ljava/lang/CharSequence;)Ly/Builder;", back.methods.single().delegate)
        assertTrue(back.isEnum)
    }

    @Test
    fun `a library's R txt becomes its R classes, their ids apart from the extensions' own`() {
        val rTxt = """
            int id design_bottom_sheet 0x7f0a00b2
            int id touch_outside 0x7f0a01c0
            int string mtrl_picker_save 0x7f13004a
            int[] styleable BottomSheetBehavior_Layout { 0x7f040042, 0x7f040043 }
            int styleable BottomSheetBehavior_Layout_behavior_peekHeight 1
        """.trimIndent()
        val numbering = RIds()
        val classes = Signatures.rClasses(rTxt, "com.google.android.material", numbering).associateBy { it.name }
        val ids = classes.getValue("com/google/android/material/R\$id").fields
        assertEquals(listOf("design_bottom_sheet", "touch_outside"), ids.map { it.name })
        val values = ids.map { it.value as Int }
        assertEquals(2, values.toSet().size)
        assertTrue(values.all { it ushr 24 == 0x7e }, "package 0x7e: never an extension's own (0x7f) id")
        assertTrue(values.none { (it shr 16) and 0xff == RIds.HAND_TYPE }, "type 0xff is the stand-ins' own")
        val styleable = classes.getValue("com/google/android/material/R\$styleable").fields
        assertNull(styleable.first { it.desc == "[I" }.value)
        assertEquals(1, styleable.first { it.name == "BottomSheetBehavior_Layout_behavior_peekHeight" }.value, "an index, kept as it is")
        assertTrue("com/google/android/material/R" in classes)
        // Another library's ids never repeat these: a view one library's id names isn't found by another's.
        val other = Signatures.rClasses("int id buttonPanel 0x7f0a0042\n", "androidx.appcompat", numbering)
        assertTrue(other.single { it.name.endsWith("R\$id") }.fields.single().value as Int !in values)
    }

    @Test
    fun `reference jars give framework classes only, from plain jars and from AARs with their R classes`() {
        val thing = classBytes("androidx/test/Thing")
        val anonymous = classBytes("androidx/test/Thing\$1")
        val other = classBytes("org/other/X")
        val hidden = classBytes("androidx/test/Hidden", access = ACC_SUPER)
        val aar = jarOf(
            "classes.jar" to zipBytes("androidx/test/Thing.class" to thing, "androidx/test/Thing\$1.class" to anonymous, "androidx/test/Hidden.class" to hidden),
            "R.txt" to "int id thing_view 0x7f0a0001\n".toByteArray(),
            "AndroidManifest.xml" to """<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="androidx.test" />""".toByteArray(),
            fileName = "thing.aar",
        )
        val jar = jarOf("android/os/Thing.class" to classBytes("android/os/Thing"), "org/other/X.class" to other)
        val classes = ReferenceJars.read(listOf(jar, aar))
        assertEquals(setOf("android/os/Thing", "androidx/test/Thing", "androidx/test/R", "androidx/test/R\$id"), classes.keys)
        assertTrue(ReferenceJars.isFramework("com/google/android/material/R\$id"))
    }
}
