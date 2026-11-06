import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile

plugins {
    kotlin("jvm") version "2.4.0" apply false
}

// Java 11 bytecode runs everywhere the engine does: desktop JDKs, the iOS
// OpenJDK Zero VM and (after D8) Android.
subprojects {
    tasks.withType<JavaCompile>().configureEach {
        options.release.set(11)
    }
    tasks.withType<KotlinJvmCompile>().configureEach {
        compilerOptions.jvmTarget.set(JvmTarget.JVM_11)
        // We are the host app, which may use the library's host-only APIs, as CloudStream's app does.
        compilerOptions.optIn.addAll("com.lagradost.cloudstream3.InternalAPI", "com.lagradost.cloudstream3.Prerelease")
    }
}
