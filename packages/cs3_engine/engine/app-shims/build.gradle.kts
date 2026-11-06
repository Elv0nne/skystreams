// Stand-ins for the CloudStream *app* classes plugins call into (Plugin,
// CloudStreamApp, CommonActivity, DataStore, ...). The same sources are also
// compiled into the Android host against the real Android SDK.
plugins {
    kotlin("jvm")
}

dependencies {
    api("com.lagradost.api:library:1.0.1")
    // The library declares these as runtime-only; the shims compile against them.
    api("com.squareup.okhttp3:okhttp:5.3.2")
    api("com.github.Blatzar:NiceHttp:0.4.18")
    api("com.fasterxml.jackson.module:jackson-module-kotlin:2.13.1")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
    api("com.github.teamnewpipe:NewPipeExtractor:v0.26.3")
    compileOnly(project(":android-stubs"))
    testImplementation(project(":android-stubs"))
    testImplementation(kotlin("test"))
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
}
