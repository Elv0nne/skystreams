# Rules a minified host applies to this plugin (consumerProguardFiles in
# build.gradle.kts).

# JNI binds native methods by name. libvlc_player_geometry.so exports
# Java_com_lingjhf_vlc_1player_VlcNativeGeometry_nativeSetCropGeometry, so the
# class and the method must keep the names it was built against. Renamed by
# R8 - the 2.8.1 release build turned them into c4.e.a - the first crop threw
# UnsatisfiedLinkError on the main thread: every change of source or episode,
# and every Zoom or Stretch on a picture not the screen's shape, closed the app.
-keepclasseswithmembers,includedescriptorclasses class com.lingjhf.vlc_player.** {
    native <methods>;
}
