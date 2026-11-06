// Platform-neutral engine: the JSON protocol, plugin registry and result mapping.
// Compiled into the desktop/iOS jar and, as sources, into the Android host.
plugins {
    kotlin("jvm")
}

dependencies {
    api(project(":app-shims"))
    compileOnly(project(":android-stubs"))
    testImplementation(project(":android-stubs"))
    testImplementation(kotlin("test"))
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
}
