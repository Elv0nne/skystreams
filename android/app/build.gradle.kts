import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.akash.skystream"
    compileSdkVersion(rootProject.extra["projectCompileSdk"] as String)
    // See the projectNdk comment in the root build.gradle.kts for why this is
    // pinned instead of following flutter.ndkVersion.
    ndkVersion = rootProject.extra["projectNdk"] as String

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.akash.skystream"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = rootProject.extra["projectTargetSdk"] as Int
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    val keystoreProperties = Properties()
    val keystorePropertiesFile = rootProject.file("key.properties")
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = if (keystoreProperties.getProperty("storeFile") != null) file(keystoreProperties.getProperty("storeFile")) else null
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            // Require a real signing keystore for release. Falling back to
            // the debug key would silently ship an unsigned-for-Play APK
            // (audit H13). For CI/local debug-without-keystore use
            // `flutter run --debug` or `flutter build apk --debug`.
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Build still runs (so `flutter build apk --release` works
                // during local exploration without a key.properties) but the
                // resulting APK is debug-signed — never publish it.
                println("WARN: Release build is using DEBUG signing — " +
                        "key.properties not found. This APK MUST NOT be " +
                        "distributed publicly.")
                signingConfig = signingConfigs.getByName("debug")
            }

            // Code & resource shrinking (audit B8). Skip the bundled
            // proguard-android-optimize.txt rules and rely on the
            // Flutter-provided rules plus our own proguard-rules.pro for
            // plugin-specific keep rules.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    testOptions {
        unitTests {
            // Robolectric's Android 16 sets up file descriptors through the
            // JDK's internal access, which JDK 17+ closes to it by default.
            // The app's own resources are left out: the tests here need none,
            // and including them would package Flutter's assets into a task
            // that does not wait for them.
            all { it.jvmArgs("--add-opens=java.base/jdk.internal.access=ALL-UNNAMED") }
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
        // Duplicate metadata from CloudStream's library dependencies.
        resources {
            excludes += setOf(
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
            )
        }
    }
}


flutter {
    source = "../.."
}

configurations.configureEach {
    // background_downloader declares `androidx.test:monitor` as a plain
    // `implementation` (its android/build.gradle:49), so a test-instrumentation
    // library ends up in the release runtime classpath and ships in the APK.
    // Nothing in its main sources references it - no androidx.test import, no
    // InstrumentationRegistry - so it is dead weight, and it is exactly the
    // reflection-heavy kind of artifact that AGP 9's strictFullModeForKeepRules
    // will complain about. If a build ever fails resolving an androidx.test
    // symbol, the package started using it and this exclude must go.
    //
    // Only from the app's own classpaths, which are what ship. The unit
    // tests' classpaths extend them, so excluding everywhere took it from the
    // tests too, and Robolectric's runner cannot start without it.
    if (name.contains("Test") || !name.endsWith("Classpath")) return@configureEach
    exclude(group = "androidx.test", module = "monitor")
}

dependencies {
    implementation("androidx.tvprovider:tvprovider:1.0.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.17")
}
