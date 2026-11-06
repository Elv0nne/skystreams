package dev.akash.cs3engine.frameworkgen

import org.objectweb.asm.Opcodes
import org.objectweb.asm.tree.ClassNode
import java.io.DataInputStream
import java.io.DataOutputStream

/** A field of a framework class; [value] is a constant's (Int, Long, Float, Double or String), else null. */
class FieldSig(val access: Int, val name: String, val desc: String, val value: Any? = null)

/**
 * A method or constructor of a framework class. [delegate] is set on a covariant override of a hand-written
 * method (that method's descriptor): the generated method calls it, where it would otherwise do nothing.
 */
class MethodSig(val access: Int, val name: String, val desc: String, val delegate: String? = null) {
    val isStatic: Boolean get() = access and Opcodes.ACC_STATIC != 0
    val isAbstract: Boolean get() = access and Opcodes.ACC_ABSTRACT != 0
    val isConstructor: Boolean get() = name == "<init>"

    /** Its name and parameters: what an override shares with it, whatever it returns. */
    val parameters: String get() = name + desc.substring(0, desc.indexOf(')') + 1)
}

/** A framework class as the stand-ins and the generated classes need it: its type, and its public and protected members. */
class ClassSig(
    val name: String,
    val access: Int,
    val superName: String?,
    val interfaces: List<String>,
    val fields: List<FieldSig>,
    val methods: List<MethodSig>,
) {
    val isInterface: Boolean get() = access and Opcodes.ACC_INTERFACE != 0
    val isEnum: Boolean get() = access and Opcodes.ACC_ENUM != 0
    val isAbstract: Boolean get() = access and Opcodes.ACC_ABSTRACT != 0

    fun copy(methods: List<MethodSig> = this.methods) = ClassSig(name, access, superName, interfaces, fields, methods)

    fun write(out: DataOutputStream) {
        out.writeInt(FORMAT)
        out.writeUTF(name)
        out.writeInt(access)
        out.writeUTF(superName.orEmpty())
        out.writeInt(interfaces.size)
        interfaces.forEach(out::writeUTF)
        out.writeInt(fields.size)
        for (field in fields) {
            out.writeInt(field.access)
            out.writeUTF(field.name)
            out.writeUTF(field.desc)
            when (val value = field.value) {
                is Int -> out.writeByte(1).also { out.writeInt(value) }
                is Long -> out.writeByte(2).also { out.writeLong(value) }
                is Float -> out.writeByte(3).also { out.writeFloat(value) }
                is Double -> out.writeByte(4).also { out.writeDouble(value) }
                // writeUTF holds 64 KB; a longer constant (none known) loses its value.
                is String -> if (value.length < 16_384) out.writeByte(5).also { out.writeUTF(value) } else out.writeByte(0)
                else -> out.writeByte(0)
            }
        }
        out.writeInt(methods.size)
        for (method in methods) {
            out.writeInt(method.access)
            out.writeUTF(method.name)
            out.writeUTF(method.desc)
            out.writeUTF(method.delegate.orEmpty())
        }
    }

    companion object {
        private const val FORMAT = 1
        private const val VISIBLE = Opcodes.ACC_PUBLIC or Opcodes.ACC_PROTECTED

        /**
         * [node]'s signature: public and protected members only, without `<clinit>` or synthetic ones other than
         * bridges. A class made from the index keeps its bridges, so it answers through a hand-written generic
         * superclass's erased signature (an `ActivityResultContracts` contract's `parseResult`, for one).
         */
        fun of(node: ClassNode): ClassSig = ClassSig(
            node.name,
            node.access,
            node.superName,
            node.interfaces.orEmpty().toList(),
            node.fields.orEmpty()
                .filter { it.access and VISIBLE != 0 && it.access and Opcodes.ACC_SYNTHETIC == 0 }
                .map { FieldSig(it.access, it.name, it.desc, it.value) },
            node.methods.orEmpty()
                .filter { it.access and VISIBLE != 0 && it.name != "<clinit>" }
                .filter { it.access and Opcodes.ACC_BRIDGE != 0 || it.access and Opcodes.ACC_SYNTHETIC == 0 }
                .map { MethodSig(it.access, it.name, it.desc) },
        )

        fun read(input: DataInputStream): ClassSig {
            check(input.readInt() == FORMAT) { "unknown framework index format" }
            val name = input.readUTF()
            val access = input.readInt()
            val superName = input.readUTF().ifEmpty { null }
            val interfaces = List(input.readInt()) { input.readUTF() }
            val fields = List(input.readInt()) {
                val fieldAccess = input.readInt()
                val fieldName = input.readUTF()
                val desc = input.readUTF()
                val value: Any? = when (input.readByte().toInt()) {
                    1 -> input.readInt()
                    2 -> input.readLong()
                    3 -> input.readFloat()
                    4 -> input.readDouble()
                    5 -> input.readUTF()
                    else -> null
                }
                FieldSig(fieldAccess, fieldName, desc, value)
            }
            val methods = List(input.readInt()) {
                MethodSig(input.readInt(), input.readUTF(), input.readUTF(), input.readUTF().ifEmpty { null })
            }
            return ClassSig(name, access, superName, interfaces, fields, methods)
        }
    }
}

/**
 * Numbers the libraries' resource ids in package 0x7e, apart from every extension's own (0x7f), and unique
 * across all the libraries numbered with it: a library id only finds the views a stand-in gives it.
 */
class RIds {
    private val types = HashMap<String, Int>()
    private val counts = HashMap<String, Int>()

    fun next(type: String): Int {
        val typeIndex = types.getOrPut(type) { types.size + 1 }
        check(typeIndex < HAND_TYPE) { "too many resource types" }
        val entry = counts.merge(type, 1, Int::plus)!! - 1
        return (0x7e shl 24) or (typeIndex shl 16) or entry
    }

    companion object {
        /** The type of the ids hand-written stand-ins give their views (Material's `R.id.design_bottom_sheet`). */
        const val HAND_TYPE = 0xff
    }
}

object Signatures {
    /**
     * A library's R classes from its `R.txt` (`int id design_bottom_sheet 0x7f0a00b2`, `int[] styleable X { … }`):
     * the package's `R` and one class per type, with ids from [ids]. A styleable's ints are indexes into its
     * array, kept as they are; arrays have no value.
     */
    fun rClasses(rTxt: String, pkg: String, ids: RIds = RIds()): List<ClassSig> {
        val base = pkg.replace('.', '/') + "/R"
        val byType = LinkedHashMap<String, MutableList<FieldSig>>()
        for (line in rTxt.lineSequence()) {
            val parts = line.trim().split(' ', limit = 4)
            if (parts.size < 3) continue
            val (kind, type, name) = parts
            val fields = byType.getOrPut(type) { mutableListOf() }
            val access = Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC or Opcodes.ACC_FINAL
            if (kind == "int[]") {
                fields += FieldSig(access, name, "[I")
            } else if (kind == "int" && type == "styleable") {
                fields += FieldSig(access, name, "I", parts.getOrNull(3)?.let(Integer::decode) ?: 0)
            } else if (kind == "int") {
                fields += FieldSig(access, name, "I", ids.next(type))
            }
        }
        val classAccess = Opcodes.ACC_PUBLIC or Opcodes.ACC_FINAL or Opcodes.ACC_SUPER
        return listOf(ClassSig(base, classAccess, "java/lang/Object", emptyList(), emptyList(), emptyList())) +
            byType.map { (type, fields) -> ClassSig("$base\$$type", classAccess, "java/lang/Object", emptyList(), fields, emptyList()) }
    }
}
