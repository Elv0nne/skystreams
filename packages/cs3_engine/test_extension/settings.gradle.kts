// SkyStream's own CloudStream extension, for tests that need one that never changes or goes away.
// packages/cs3_engine/tool/build_test_extension.sh builds it into build/SkyStreamTest.cs3.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("com.android.library") version "9.1.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("../m2")
            content { includeGroup("com.lagradost.api") }
        }
        maven("https://jitpack.io")
    }
}

rootProject.name = "skystream-test-extension"
include(":extension")
