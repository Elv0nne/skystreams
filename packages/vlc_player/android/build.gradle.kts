group = "com.lingjhf.vlc_player"
version = "1.0-SNAPSHOT"

// No `buildscript` block here on purpose.
//
// Upstream pinned AGP 9.0.1 / Kotlin 2.3.20 on its own classpath. A Flutter
// plugin is built as a subproject of the host app, so the host's plugin
// management already supplies both — and a second, different version on the
// plugin's classpath conflicts with it. SkyStream is on AGP 9.1 since
// 2026-10-02, once flutter_inappwebview_android (whose
// `getDefaultProguardFile('proguard-android.txt')` AGP 9 rejects) left the app,
// with Flutter's builtInKotlin/newDsl opt-outs in gradle.properties.
//
// Removing the block lets the plugin inherit whatever the host uses, which is
// what every other vendored package here does.

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.lingjhf.vlc_player"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        // Was 29 upstream, with no comment and nothing requiring it.
        //
        // Nothing in this plugin needs API 29. libVLC itself declares
        // minSdkVersion 17 (verified in the libvlc-all:3.7.0 and 3.7.7 AAR manifests), and
        // the only API in this plugin's Kotlin newer than API 17 is
        // android.view.PixelCopy — API 24 — used solely by takeSnapshot. There
        // is not a single @RequiresApi or Build.VERSION guard in the source.
        //
        // 24 matches Flutter's own default minSdkVersion, so hosts inherit it
        // for free. It also matters commercially: 29 excluded Fire OS 7, which
        // is Android 9 / API 28, and that is a large share of Fire TV devices.
        //
        // Going below 24 is possible — it needs a SDK_INT guard around the
        // PixelCopy call in VlcPlayerPlatformView — but is not done here.
        minSdk = 24

        // Keeps the names the crop shim's JNI binding needs in a minified
        // host; see consumer-rules.pro.
        consumerProguardFiles("consumer-rules.pro")
    }

    // libVLC's crop, which libvlc-android does not expose in Java: see
    // src/main/cpp/vlc_player_geometry.c. The NDK version comes from the host's
    // root build, which pins one for every subproject.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 3.7.7 (2026-10-01) is the first libvlc-all on the VLC 3.0.24 release:
    // its arm64 libvlc.so reports `3.0.24-35-gc7e5d68ee5`, 35 commits of the
    // 3.0 maintenance branch past the 3.0.24 tag (its version string already
    // says 3.0.25, the branch's next number). 3.7.1 - 3.7.6 carried
    // 3.0.24-beta1, and 3.7.0 was 3.0.23. No libvlc-all carries the bare
    // 3.0.24 tag. minSdkVersion in its manifest is still 17.
    implementation("org.videolan.android:libvlc-all:3.7.7")
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.23.0")
}
