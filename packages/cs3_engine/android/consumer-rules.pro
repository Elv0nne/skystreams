# Applied to every app that uses this plugin. Extensions are DEX loaded at runtime that call
# CloudStream's library, the app stand-ins and the libraries CloudStream ships, by name, so
# none of them may be renamed or stripped. The same set CloudStream's own app keeps.
-keep class com.lagradost.** { *; }
-keep class dev.akash.cs3engine.** { *; }
-keep class kotlin.** { *; }
-keep class kotlinx.** { *; }
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class org.jsoup.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-keep class com.google.gson.** { *; }
-keep class org.mozilla.javascript.** { *; }
-keep class org.schabi.newpipe.** { *; }
-keep class com.fleeksoft.** { *; }
-keep class dev.whyoleg.** { *; }
-keep class io.ktor.** { *; }
-keep class androidx.** { *; }
# Extensions' settings screens are Material bottom sheets and dialogs, called by name from their DEX.
-keep class com.google.android.material.** { *; }
-keep class org.json.** { *; }
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod,Exceptions,RuntimeVisible*Annotations,KotlinMetadata
-dontwarn com.lagradost.**
-dontwarn kotlinx.**
-dontwarn org.mozilla.javascript.**
-dontwarn org.schabi.newpipe.**
-dontwarn com.fasterxml.jackson.**
-dontwarn java.beans.**
-dontwarn javax.script.**
-dontwarn org.slf4j.**
# Only on the JVM (ktor's debug detection through JMX); never reached on Android.
-dontwarn java.lang.management.**
