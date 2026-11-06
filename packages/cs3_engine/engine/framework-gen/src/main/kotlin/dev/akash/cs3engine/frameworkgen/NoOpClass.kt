package dev.akash.cs3engine.frameworkgen

import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes.AASTORE
import org.objectweb.asm.Opcodes.ACC_ABSTRACT
import org.objectweb.asm.Opcodes.ACC_ANNOTATION
import org.objectweb.asm.Opcodes.ACC_ENUM
import org.objectweb.asm.Opcodes.ACC_FINAL
import org.objectweb.asm.Opcodes.ACC_INTERFACE
import org.objectweb.asm.Opcodes.ACC_PRIVATE
import org.objectweb.asm.Opcodes.ACC_PROTECTED
import org.objectweb.asm.Opcodes.ACC_PUBLIC
import org.objectweb.asm.Opcodes.ACC_STATIC
import org.objectweb.asm.Opcodes.ACC_SUPER
import org.objectweb.asm.Opcodes.ACC_SYNTHETIC
import org.objectweb.asm.Opcodes.ACC_TRANSIENT
import org.objectweb.asm.Opcodes.ACC_VARARGS
import org.objectweb.asm.Opcodes.ACC_VOLATILE
import org.objectweb.asm.Opcodes.ACONST_NULL
import org.objectweb.asm.Opcodes.ALOAD
import org.objectweb.asm.Opcodes.ANEWARRAY
import org.objectweb.asm.Opcodes.ARETURN
import org.objectweb.asm.Opcodes.BIPUSH
import org.objectweb.asm.Opcodes.CHECKCAST
import org.objectweb.asm.Opcodes.DCONST_0
import org.objectweb.asm.Opcodes.DUP
import org.objectweb.asm.Opcodes.FCONST_0
import org.objectweb.asm.Opcodes.GETSTATIC
import org.objectweb.asm.Opcodes.ICONST_0
import org.objectweb.asm.Opcodes.ILOAD
import org.objectweb.asm.Opcodes.INVOKESPECIAL
import org.objectweb.asm.Opcodes.INVOKESTATIC
import org.objectweb.asm.Opcodes.INVOKEVIRTUAL
import org.objectweb.asm.Opcodes.IRETURN
import org.objectweb.asm.Opcodes.LCONST_0
import org.objectweb.asm.Opcodes.NEW
import org.objectweb.asm.Opcodes.PUTSTATIC
import org.objectweb.asm.Opcodes.RETURN
import org.objectweb.asm.Opcodes.SIPUSH
import org.objectweb.asm.Opcodes.V1_8
import org.objectweb.asm.Type

/**
 * A framework class that does nothing (the spec's "Generated API"): each method returns a default, or the
 * object itself where it returns its own class (builders). Constructors chain to the closest one the
 * superclass has. Abstract methods stay abstract, enums get their constants, constants keep their values,
 * and a covariant override of a hand-written method calls it. The code is straight-line, so the class needs
 * no stack map frames.
 */
object NoOpClass {
    private const val FIELD_FLAGS = ACC_PUBLIC or ACC_PROTECTED or ACC_STATIC or ACC_FINAL or ACC_ENUM or ACC_VOLATILE or ACC_TRANSIENT
    private const val METHOD_FLAGS = ACC_PUBLIC or ACC_PROTECTED or ACC_STATIC or ACC_VARARGS

    fun generate(sig: ClassSig, constructorsOf: (String) -> List<String>): ByteArray {
        val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
        val enum = sig.isEnum
        // An enum's constants are plain instances here, so it is never abstract.
        var access = sig.access and (ACC_PUBLIC or ACC_INTERFACE or ACC_ABSTRACT or ACC_ENUM or ACC_ANNOTATION)
        if (enum) access = access and ACC_ABSTRACT.inv()
        if (!sig.isInterface) access = access or ACC_SUPER
        val superName = sig.superName ?: "java/lang/Object"
        writer.visit(V1_8, access, sig.name, null, superName, sig.interfaces.toTypedArray().takeIf { it.isNotEmpty() })
        for (field in sig.fields) {
            val value = if (field.access and ACC_STATIC != 0 && field.access and ACC_FINAL != 0) field.value else null
            writer.visitField(field.access and FIELD_FLAGS, field.name, field.desc, null, value)?.visitEnd()
        }
        val superConstructors = if (sig.isInterface) emptyList() else constructorsOf(superName)
        if (enum) writeEnum(writer, sig)
        val declared = HashSet<String>()
        for (method in sig.methods) {
            if (enum && (method.isConstructor || isEnumMethod(sig.name, method))) continue
            if (sig.isInterface && method.isConstructor) continue
            if (!declared.add(method.name + method.desc)) continue
            val returnType = Type.getReturnType(method.desc)
            val returnsSelf = !method.isStatic && returnType.sort == Type.OBJECT && returnType.internalName == sig.name
            val keepAbstract = method.isAbstract && (sig.isInterface || (sig.isAbstract && !enum))
            val shape = if (keepAbstract) method else MethodSig(method.access and ACC_ABSTRACT.inv(), method.name, method.desc, method.delegate)
            writeMethod(writer, sig.name, superName, shape, returnsSelf, superConstructors)
        }
        if (!sig.isInterface && !enum && "<init>()V" !in declared) {
            writeMethod(writer, sig.name, superName, MethodSig(ACC_PROTECTED, "<init>", "()V"), false, superConstructors)
        }
        writer.visitEnd()
        return writer.toByteArray()
    }

    /**
     * Writes [method] on [owner]: abstract if it is, a chained constructor, a call to the hand-written method
     * it overrides covariantly ([MethodSig.delegate]), or a body that does nothing.
     */
    fun writeMethod(cv: ClassVisitor, owner: String, superName: String?, method: MethodSig, returnsSelf: Boolean, constructors: List<String>) {
        val abstract = method.isAbstract
        val access = (method.access and METHOD_FLAGS) or (if (abstract) ACC_ABSTRACT else 0)
        val mv = cv.visitMethod(access, method.name, method.desc, null, null)
        if (abstract) {
            mv.visitEnd()
            return
        }
        mv.visitCode()
        val returnType = Type.getReturnType(method.desc)
        when {
            method.isConstructor -> {
                chain(mv, superName ?: "java/lang/Object", Type.getArgumentTypes(method.desc), constructors)
                mv.visitInsn(RETURN)
            }
            method.delegate != null && superName != null -> {
                mv.visitVarInsn(ALOAD, 0)
                var slot = 1
                for (type in Type.getArgumentTypes(method.desc)) {
                    mv.visitVarInsn(type.getOpcode(ILOAD), slot)
                    slot += type.size
                }
                mv.visitMethodInsn(INVOKESPECIAL, superName, method.name, method.delegate, false)
                if (returnType.sort == Type.OBJECT || returnType.sort == Type.ARRAY) {
                    if (Type.getReturnType(method.delegate) != returnType) mv.visitTypeInsn(CHECKCAST, returnType.internalName)
                }
                mv.visitInsn(returnType.getOpcode(IRETURN))
            }
            returnType.sort == Type.VOID -> mv.visitInsn(RETURN)
            returnsSelf -> {
                mv.visitVarInsn(ALOAD, 0)
                mv.visitInsn(ARETURN)
            }
            else -> {
                pushDefault(mv, returnType)
                mv.visitInsn(returnType.getOpcode(IRETURN))
            }
        }
        mv.visitMaxs(0, 0)
        mv.visitEnd()
    }

    /** A zero, false or null of [type]. */
    fun pushDefault(mv: MethodVisitor, type: Type) {
        mv.visitInsn(
            when (type.sort) {
                Type.LONG -> LCONST_0
                Type.FLOAT -> FCONST_0
                Type.DOUBLE -> DCONST_0
                Type.OBJECT, Type.ARRAY -> ACONST_NULL
                else -> ICONST_0
            },
        )
    }

    /** `super(...)`: the superclass constructor whose parameters begin [params] the longest; else the shortest, with defaults. */
    private fun chain(mv: MethodVisitor, superName: String, params: Array<Type>, candidates: List<String>) {
        fun prefixOf(desc: String): Boolean {
            val theirs = Type.getArgumentTypes(desc)
            return theirs.size <= params.size && theirs.indices.all { theirs[it] == params[it] }
        }
        val best = candidates.maxByOrNull { desc ->
            val size = Type.getArgumentTypes(desc).size
            if (prefixOf(desc)) 1_000 + size else -size
        } ?: "()V"
        mv.visitVarInsn(ALOAD, 0)
        val theirs = Type.getArgumentTypes(best)
        if (prefixOf(best)) {
            var slot = 1
            for (type in theirs) {
                mv.visitVarInsn(type.getOpcode(ILOAD), slot)
                slot += type.size
            }
        } else {
            theirs.forEach { pushDefault(mv, it) }
        }
        mv.visitMethodInsn(INVOKESPECIAL, superName, "<init>", best, false)
    }

    private fun isEnumMethod(owner: String, method: MethodSig): Boolean =
        method.isStatic && ((method.name == "values" && method.desc == "()[L$owner;") ||
            (method.name == "valueOf" && method.desc == "(Ljava/lang/String;)L$owner;"))

    /** An enum's constants (its own-typed enum fields, in order), `$VALUES`, `values()`, `valueOf()` and constructor. */
    private fun writeEnum(cw: ClassWriter, sig: ClassSig) {
        val own = sig.name
        val array = "[L$own;"
        val constants = sig.fields.filter { it.access and ACC_ENUM != 0 && it.desc == "L$own;" }.map { it.name }
        cw.visitField(ACC_PRIVATE or ACC_STATIC or ACC_FINAL or ACC_SYNTHETIC, "\$VALUES", array, null, null).visitEnd()

        cw.visitMethod(ACC_PRIVATE, "<init>", "(Ljava/lang/String;I)V", null, null).apply {
            visitCode()
            visitVarInsn(ALOAD, 0)
            visitVarInsn(ALOAD, 1)
            visitVarInsn(ILOAD, 2)
            visitMethodInsn(INVOKESPECIAL, "java/lang/Enum", "<init>", "(Ljava/lang/String;I)V", false)
            visitInsn(RETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        cw.visitMethod(ACC_PUBLIC or ACC_STATIC, "values", "()$array", null, null).apply {
            visitCode()
            visitFieldInsn(GETSTATIC, own, "\$VALUES", array)
            visitMethodInsn(INVOKEVIRTUAL, array, "clone", "()Ljava/lang/Object;", false)
            visitTypeInsn(CHECKCAST, array)
            visitInsn(ARETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        cw.visitMethod(ACC_PUBLIC or ACC_STATIC, "valueOf", "(Ljava/lang/String;)L$own;", null, null).apply {
            visitCode()
            visitLdcInsn(Type.getObjectType(own))
            visitVarInsn(ALOAD, 0)
            visitMethodInsn(INVOKESTATIC, "java/lang/Enum", "valueOf", "(Ljava/lang/Class;Ljava/lang/String;)Ljava/lang/Enum;", false)
            visitTypeInsn(CHECKCAST, own)
            visitInsn(ARETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        cw.visitMethod(ACC_STATIC, "<clinit>", "()V", null, null).apply {
            visitCode()
            constants.forEachIndexed { index, name ->
                visitTypeInsn(NEW, own)
                visitInsn(DUP)
                visitLdcInsn(name)
                pushInt(this, index)
                visitMethodInsn(INVOKESPECIAL, own, "<init>", "(Ljava/lang/String;I)V", false)
                visitFieldInsn(PUTSTATIC, own, name, "L$own;")
            }
            pushInt(this, constants.size)
            visitTypeInsn(ANEWARRAY, own)
            constants.forEachIndexed { index, name ->
                visitInsn(DUP)
                pushInt(this, index)
                visitFieldInsn(GETSTATIC, own, name, "L$own;")
                visitInsn(AASTORE)
            }
            visitFieldInsn(PUTSTATIC, own, "\$VALUES", array)
            visitInsn(RETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
    }

    private fun pushInt(mv: MethodVisitor, value: Int) = when {
        value in -1..5 -> mv.visitInsn(ICONST_0 + value)
        value in Byte.MIN_VALUE..Byte.MAX_VALUE -> mv.visitIntInsn(BIPUSH, value)
        value in Short.MIN_VALUE..Short.MAX_VALUE -> mv.visitIntInsn(SIPUSH, value)
        else -> mv.visitLdcInsn(value)
    }
}
