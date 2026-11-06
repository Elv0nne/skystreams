package dev.akash.cs3engine.jvm

import dev.akash.cs3engine.frameworkgen.ClassSig
import dev.akash.cs3engine.frameworkgen.FrameworkIndex
import dev.akash.cs3engine.frameworkgen.NoOpClass
import org.objectweb.asm.Type
import java.lang.reflect.Modifier

/**
 * Makes the framework classes extensions mention that the engine's jars don't have (the spec's "Generated
 * API"), from the signature index: complete no-ops with their real superclasses, interfaces, enum constants
 * and R ids, extending the hand-written stand-ins where Android's classes extend those. One serves every
 * extension, between the engine's classes and each extension's loader: a class two extensions both hand to
 * a stand-in must be one class, or the JVM refuses the second (a loader constraint). Names outside the index
 * fall through to each extension's loader, which makes empty placeholders as before.
 */
class FrameworkClassLoader(
    parent: ClassLoader,
    private val index: (internalName: String) -> ClassSig? = { FrameworkIndex.read(parent, it) },
) : ClassLoader(parent) {
    override fun findClass(name: String): Class<*> {
        val sig = index(name.replace('.', '/')) ?: throw ClassNotFoundException(name)
        val bytes = NoOpClass.generate(sig, ::constructorsOf)
        return try {
            defineClass(name, bytes, 0, bytes.size)
        } catch (e: LinkageError) {
            // A supertype nothing has (outside the framework, or a newer API's): the extension's own placeholder serves.
            throw ClassNotFoundException(name, e)
        }
    }

    /** A superclass's constructors: a generated one's from the index (with the one every generated class has), else by reflection. */
    private fun constructorsOf(internalName: String): List<String> {
        index(internalName)?.let { sig -> return sig.methods.filter { it.isConstructor }.map { it.desc } + "()V" }
        val type = runCatching { loadClass(internalName.replace('/', '.')) }.getOrNull() ?: return listOf("()V")
        return try {
            type.declaredConstructors
                .filter { Modifier.isPublic(it.modifiers) || Modifier.isProtected(it.modifiers) }
                .map { Type.getConstructorDescriptor(it) }
        } catch (e: LinkageError) {
            // A constructor naming a class the host lacks (Layout's Layout.Alignment) can't be read by reflection:
            // chain to the no-argument one every generated class has.
            listOf("()V")
        }
    }
}
