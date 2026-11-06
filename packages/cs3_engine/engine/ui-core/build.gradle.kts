// The screens' tree and actions (part 1), the same code on every platform: Android compiles these sources
// into its plugin (packages/cs3_engine/android), and the JVM engine uses this module, on the stand-ins.
plugins {
    kotlin("jvm")
}

dependencies {
    compileOnly(project(":android-stubs"))
    testImplementation(project(":android-stubs"))
    testImplementation(kotlin("test"))
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
}
