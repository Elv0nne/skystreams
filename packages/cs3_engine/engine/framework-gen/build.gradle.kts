// The generated half of the JVM's Android stand-ins (the spec's "Generated API"). At engine build time it
// reads Android's and the libraries' class signatures, makes the hand-written stand-ins API-complete with
// no-ops, and writes an index; at run time the plugin class loader makes the other framework classes from
// that index. ASM only: the engine's runtime carries it.
plugins {
    kotlin("jvm")
}

dependencies {
    api("org.ow2.asm:asm:9.10.1")
    api("org.ow2.asm:asm-tree:9.10.1")
    testImplementation(kotlin("test"))
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
}
