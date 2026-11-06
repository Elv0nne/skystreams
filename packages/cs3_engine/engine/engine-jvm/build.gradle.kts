// Desktop and iOS host: converts .cs3 (DEX) to JVM classes and serves the engine
// protocol over stdio (desktop) or JNI (iOS, see EmbeddedEntry).
plugins {
    kotlin("jvm")
}

// Android's and the libraries' real classes, which framework-gen reads at build time (no runtime part):
// the pins in the plan's Global Constraints, the versions the Android app resolves.
val framework by configurations.creating { isTransitive = false }
val frameworkGen by configurations.creating
val standIns by configurations.creating { isTransitive = false }

dependencies {
    implementation(project(":engine-core"))
    implementation(project(":android-stubs"))
    implementation(project(":framework-gen"))
    implementation(project(":ui-core"))
    // The converter alone; dex-tools would add the dex2jar command-line tools (smali, jasmin, ANTLR).
    implementation("de.femtopedia.dex2jar:dex-translator:2.4.38")
    implementation("org.ow2.asm:asm:9.10.1")
    // Not part of CloudStream's library, but its app ships it and 30 of 485 surveyed plugins use it.
    runtimeOnly("com.google.code.gson:gson:2.13.2")
    // Android's own org.json, in place of the one NiceHttp brings: plugins rely on its behaviour
    // (getString() turns any value into a string, where org.json's throws).
    runtimeOnly("com.vaadin.external.google:android-json:0.0.20131108.vaadin1")
    testImplementation(kotlin("test"))
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")

    framework("com.google.android.material:material:1.14.0@aar")
    framework("androidx.appcompat:appcompat:1.7.1@aar")
    framework("androidx.fragment:fragment:1.8.9@aar")
    framework("androidx.recyclerview:recyclerview:1.4.0@aar")
    framework("androidx.core:core:1.18.0@aar")
    framework("androidx.preference:preference:1.2.1@aar")
    framework("androidx.cardview:cardview:1.0.0@aar")
    framework("androidx.constraintlayout:constraintlayout:2.2.1@aar")
    framework("androidx.coordinatorlayout:coordinatorlayout:1.1.0@aar")
    framework("androidx.activity:activity:1.9.0@aar")
    framework("androidx.lifecycle:lifecycle-common-jvm:2.10.0@jar")
    framework("androidx.lifecycle:lifecycle-runtime-android:2.10.0@aar")
    framework("androidx.lifecycle:lifecycle-viewmodel-android:2.10.0@aar")
    // What the filled Fragment and ComponentActivity name (getSavedStateRegistry, getViewLifecycleOwnerLiveData,
    // getLoaderManager): known, the fill writes those classes for the host, which can then resolve the stand-ins.
    framework("androidx.savedstate:savedstate-android:1.4.0@aar")
    framework("androidx.lifecycle:lifecycle-livedata-core:2.10.0@aar")
    framework("androidx.loader:loader:1.0.0@aar")
    frameworkGen(project(":framework-gen"))
    standIns(project(":android-stubs"))
}

sourceSets.test {
    // The test extension (tool/build_test_extension.sh).
    resources.srcDir("../test-fixtures")
}

/** android.jar for API 36, from the Android SDK: ANDROID_HOME, ANDROID_SDK_ROOT, or the macOS default. */
val androidJar: Provider<File> = providers.environmentVariable("ANDROID_HOME")
    .orElse(providers.environmentVariable("ANDROID_SDK_ROOT"))
    .orElse(providers.systemProperty("user.home").map { "$it/Library/Android/sdk" })
    .map { File(it, "platforms/android-36/android.jar") }

// The stand-ins as shipped: API-complete, checked against Android, with the index of every other
// framework class (framework-gen).
val fillStandIns by tasks.registering(JavaExec::class) {
    description = "Fills android-stubs' stand-ins with no-ops, checks them, and writes the framework index."
    val filled = layout.buildDirectory.dir("filled")
    inputs.files(standIns, framework)
    // Files, not file: a missing android.jar reaches the message below instead of Gradle's own.
    inputs.files(androidJar)
    outputs.dir(filled)
    classpath = frameworkGen
    mainClass.set("dev.akash.cs3engine.frameworkgen.FillKt")
    argumentProviders.add(
        CommandLineArgumentProvider {
            check(androidJar.get().isFile) { "framework-gen needs ${androidJar.get()}: install SDK platform 36, or set ANDROID_HOME" }
            listOf(standIns.singleFile.path, filled.get().asFile.path, androidJar.get().path) + framework.files.map { it.path }
        },
    )
}

val filledStubsJar by tasks.registering(Jar::class) {
    archiveFileName.set("android-stubs.jar")
    destinationDirectory.set(layout.buildDirectory.dir("filled-jar"))
    from(fillStandIns)
}

tasks.test {
    useJUnitPlatform()
    // The engine's tests run on the stand-ins as shipped: the filled jar comes before the plain one.
    classpath = files(filledStubsJar) + classpath
}

configurations.runtimeClasspath {
    exclude(group = "org.json", module = "json")
}

// build/dist/lib: the engine jar and every runtime dependency, run with `-cp "lib/*"`; the stand-ins filled.
val dist by tasks.registering(Sync::class) {
    from(tasks.jar)
    from(configurations.runtimeClasspath) { exclude("android-stubs.jar") }
    from(filledStubsJar)
    into(layout.buildDirectory.dir("dist/lib"))
}
