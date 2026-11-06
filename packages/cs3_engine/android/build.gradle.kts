group = "dev.akash.cs3engine"
version = "0.3.0"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

// CloudStream's library, built from upstream source by tool/build_cloudstream_library.sh. The app
// resolves this plugin's dependencies, so every project in the build gets the repositories
// (rootProject.allprojects: a plugin's own allprojects is only itself), as flutter_js_ng does.
val cloudStreamLibrary = file("../m2")

rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri(cloudStreamLibrary)
            content { includeGroup("com.lagradost.api") }
        }
        maven("https://jitpack.io") // NiceHttp, NewPipeExtractor
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "dev.akash.cs3engine.android"

    compileSdk = 37 // CloudStream's library requires compiling against API 37

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            // The engine core, CloudStream app stand-ins and the screens' tree code are shared with the JVM build.
            java.srcDirs(
                "src/main/kotlin",
                "../engine/engine-core/src/main/kotlin",
                "../engine/app-shims/src/main/kotlin",
                "../engine/ui-core/src/main/kotlin",
            )
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    testOptions {
        unitTests {
            // Robolectric needs the merged resources: Material's and AppCompat's themes.
            isIncludeAndroidResources = true
            // Robolectric's Android 16 sets up file descriptors through the JDK's internal access, which
            // JDK 17+ closes to it by default.
            all { it.jvmArgs("--add-opens=java.base/jdk.internal.access=ALL-UNNAMED") }
        }
    }

    defaultConfig {
        minSdk = 24
        // Keeps what extensions call by name in the app's release build.
        consumerProguardFiles("consumer-rules.pro")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        // We are the host app, which may use the library's host-only APIs, as CloudStream's app does.
        optIn.addAll("com.lagradost.cloudstream3.InternalAPI", "com.lagradost.cloudstream3.Prerelease")
    }
}

dependencies {
    // CloudStream's library (Android variant), from ../m2.
    implementation("com.lagradost.api:library:1.0.1")
    implementation("com.squareup.okhttp3:okhttp:5.3.2")
    implementation("com.github.Blatzar:NiceHttp:0.4.18")
    implementation("com.github.teamnewpipe:NewPipeExtractor:v0.26.3")
    implementation("com.fasterxml.jackson.module:jackson-module-kotlin:2.13.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    // Not part of CloudStream's library, but its app ships it and 30 of 485 surveyed plugins use it.
    implementation("com.google.code.gson:gson:2.13.2")
    // Exposed: the host activity extends com.lagradost.cloudstream3.MainActivity (an AppCompatActivity).
    api("androidx.appcompat:appcompat:1.7.1")
    // CloudStream ships it and plugins read their settings through PreferenceManager.
    api("androidx.preference:preference-ktx:1.2.1")
    // Extensions' settings screens are Material bottom sheets and dialogs, often with lists. Declared
    // here rather than left to arrive through dynamic_color (1.7.0).
    api("com.google.android.material:material:1.14.0")
    api("androidx.recyclerview:recyclerview:1.4.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.17")
    testImplementation("androidx.test:core:1.7.0")
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit:2.4.0")
}
