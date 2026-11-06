package dev.akash.cs3engine.frameworkgen

import java.io.DataInputStream

/** Where the engine's jars keep the framework classes' signatures (one entry per class), and how they're read. */
object FrameworkIndex {
    const val FOLDER = "cs3-framework"

    fun path(internalName: String): String = "$FOLDER/$internalName.sig"

    /** [internalName]'s entry, from [loader]'s resources; null when the framework has no such class. */
    fun read(loader: ClassLoader, internalName: String): ClassSig? =
        loader.getResourceAsStream(path(internalName))?.use { ClassSig.read(DataInputStream(it.buffered())) }
}
