// libVLC's font database, built before the first video - see
// VlcFontWarmup.kt.
//
// libVLC's freetype text renderer calls fontconfig's FcInitLoadConfigAndFonts
// the first time a video output is made in a process, and with no cache that
// scans every system font. libvlc-android links fontconfig into libvlc.so and
// exports it, so the same call is resolved there and made ahead of time: it
// leaves fontconfig's cache in libvlc-android's home, where libVLC's own call
// then finds it.

#include <dlfcn.h>
#include <jni.h>
#include <stddef.h>

typedef void *(*init_load_config_and_fonts_fn)(void);
typedef void (*config_destroy_fn)(void *config);

JNIEXPORT jboolean JNICALL
Java_com_lingjhf_vlc_1player_VlcFontWarmup_nativeBuildFontDatabase(
        JNIEnv *env, jclass clazz) {
    (void) env;
    (void) clazz;
    // Loaded by the LibVLC the caller made first, which also set HOME.
    void *libvlc = dlopen("libvlc.so", RTLD_NOW | RTLD_NOLOAD);
    if (libvlc == NULL) {
        return JNI_FALSE;
    }
    init_load_config_and_fonts_fn init_load_config_and_fonts =
            (init_load_config_and_fonts_fn) dlsym(libvlc, "FcInitLoadConfigAndFonts");
    config_destroy_fn config_destroy =
            (config_destroy_fn) dlsym(libvlc, "FcConfigDestroy");
    jboolean built = JNI_FALSE;
    if (init_load_config_and_fonts != NULL && config_destroy != NULL) {
        void *config = init_load_config_and_fonts();
        if (config != NULL) {
            config_destroy(config);
            built = JNI_TRUE;
        }
    }
    dlclose(libvlc);
    return built;
}
