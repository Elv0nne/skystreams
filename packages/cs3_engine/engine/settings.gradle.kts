pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        // CloudStream's `library`, built from upstream source by ../tool/build_cloudstream_library.sh
        maven(url = uri("../m2")) {
            content { includeGroup("com.lagradost.api") }
        }
        google()
        mavenCentral()
        maven("https://jitpack.io") // NiceHttp, NewPipeExtractor
    }
}

rootProject.name = "cs3-engine"

include(":android-stubs", ":app-shims", ":engine-core", ":engine-jvm", ":framework-gen", ":ui-core")
