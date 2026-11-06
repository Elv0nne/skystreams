plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.akash.cs3test"
    compileSdk = 37
    defaultConfig { minSdk = 24 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 }
}

// What the app that loads an extension provides, as CloudStream's app does: compiled against, never packed.
dependencies {
    compileOnly("com.lagradost.api:library:1.0.1")
    compileOnly(files("../../engine/app-shims/build/libs/app-shims.jar"))
    compileOnly("androidx.appcompat:appcompat:1.7.1")
    compileOnly("com.google.android.material:material:1.14.0")
    compileOnly("androidx.recyclerview:recyclerview:1.4.0")
    compileOnly("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
}
