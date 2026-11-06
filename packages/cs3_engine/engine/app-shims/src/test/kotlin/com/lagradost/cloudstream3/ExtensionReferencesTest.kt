package com.lagradost.cloudstream3

import java.lang.reflect.Member
import java.lang.reflect.Method
import java.lang.reflect.Modifier
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * The CloudStream app members extensions call, as their code calls them (extension-references.tsv,
 * from a scan of the surveyed extensions): a name or type that drifts from upstream's fails the
 * extension when it loads, on Android and the JVM alike.
 */
class ExtensionReferencesTest {
    private val references = javaClass.getResource("/extension-references.tsv")!!.readText().lines()
        .filter { it.isNotBlank() && !it.startsWith("#") }
        .map { it.split('\t').let { (kind, owner, name, descriptor, users) -> Reference(kind, owner, name, descriptor, users) } }

    private data class Reference(val kind: String, val owner: String, val name: String, val descriptor: String, val users: String) {
        override fun toString() = "$owner.$name$descriptor ($kind, for $users)"
    }

    @Test
    fun `every app member the surveyed extensions call is there, as they call it`() {
        val calls = references.filter { it.kind != "overridden" }
        val wrong = calls.mapNotNull { reference -> problem(reference)?.let { "$reference: $it" } }
        assertTrue(wrong.isEmpty(), wrong.joinToString("\n"))
    }

    @Test
    fun `what extensions' subclasses override stays overridable`() {
        val wrong = references.filter { it.kind == "overridden" }.mapNotNull { reference ->
            val method = methodsOf(load(reference.owner)).firstOrNull { it.name == reference.name && descriptor(it) == reference.descriptor }
            when {
                method == null -> null // The extension's own method: the stand-in has none to override.
                Modifier.isFinal(method.modifiers) || Modifier.isPrivate(method.modifiers) || Modifier.isStatic(method.modifiers) ->
                    "$reference: ${Modifier.toString(method.modifiers)}"
                else -> null
            }
        }
        assertTrue(wrong.isEmpty(), wrong.joinToString("\n"))
    }

    /** Why [reference] would fail to link, or null when it links. */
    private fun problem(reference: Reference): String? {
        val owner = try {
            load(reference.owner)
        } catch (e: ClassNotFoundException) {
            return "no class"
        }
        val member: Member = when {
            reference.kind == "field" -> generateSequence(owner) { it.superclass }.flatMap { it.declaredFields.asSequence() }
                .firstOrNull { it.name == reference.name && descriptor(it.type) == reference.descriptor }
            reference.name == "<init>" -> owner.declaredConstructors
                .firstOrNull { "(${it.parameterTypes.joinToString("") { type -> descriptor(type) }})V" == reference.descriptor }
            else -> methodsOf(owner).firstOrNull { it.name == reference.name && descriptor(it) == reference.descriptor }
        } ?: return "no such member"
        if (Modifier.isPrivate(member.modifiers)) return "private"
        val static = Modifier.isStatic(member.modifiers)
        return if (static != expectStatic(reference, owner)) "static is $static" else null
    }

    /**
     * Objects' INSTANCE, companions, enum constants, file-level functions and Kotlin's default-argument callers
     * (`name\$default`) are static; the rest belongs to instances.
     */
    private fun expectStatic(reference: Reference, owner: Class<*>): Boolean = when (reference.kind) {
        "field" -> true
        else -> reference.name != "<init>" && (owner.simpleName.endsWith("Kt") || reference.name == "values" ||
            reference.name == "valueOf" || reference.name.endsWith("\$default"))
    }

    private fun load(internalName: String): Class<*> = Class.forName(internalName.replace('/', '.'), false, javaClass.classLoader)

    /** Every method the JVM would find on [type]: its own, its superclasses' and its interfaces'. */
    private fun methodsOf(type: Class<*>): List<Method> {
        val seen = LinkedHashSet<Class<*>>()
        fun visit(c: Class<*>?) {
            if (c == null || !seen.add(c)) return
            visit(c.superclass)
            c.interfaces.forEach(::visit)
        }
        visit(type)
        return seen.flatMap { it.declaredMethods.asList() }
    }

    private fun descriptor(method: Method): String =
        "(${method.parameterTypes.joinToString("") { descriptor(it) }})${descriptor(method.returnType)}"

    private fun descriptor(type: Class<*>): String = when {
        type.isArray -> "[" + descriptor(type.componentType)
        type == Void.TYPE -> "V"
        type == Integer.TYPE -> "I"
        type == java.lang.Boolean.TYPE -> "Z"
        type == java.lang.Long.TYPE -> "J"
        type == java.lang.Float.TYPE -> "F"
        type == java.lang.Double.TYPE -> "D"
        type == java.lang.Byte.TYPE -> "B"
        type == Character.TYPE -> "C"
        type == java.lang.Short.TYPE -> "S"
        else -> "L" + type.name.replace('.', '/') + ";"
    }
}
