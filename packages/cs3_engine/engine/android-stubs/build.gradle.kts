// Working stand-ins for the Android framework classes CloudStream plugins touch, the settings screens'
// views included (the spec's part 2). Only used on the JVM and iOS; Android has the real classes.
// framework-gen fills them with no-ops for the rest of Android's API at engine build time, and the plugin
// class loader makes every other framework class from its index (see engine-jvm). Java sources; Kotlin tests.
plugins {
    `java-library`
    kotlin("jvm")
}

dependencies {
    // A lifecycle's coroutine scope is a kotlinx CoroutineScope. The engine ships kotlinx.coroutines
    // (app-shims), so the stand-ins only compile against it.
    compileOnly("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
    testImplementation(kotlin("test"))
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

sourceSets.test {
    // The test extension and its resources (tool/build_test_extension.sh).
    resources.srcDir("../test-fixtures")
}

tasks.test {
    useJUnitPlatform()
}
