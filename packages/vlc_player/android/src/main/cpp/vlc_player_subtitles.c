// The subtitle look libVLC draws into the picture, changed while the video
// plays - see src/native/vlc_subtitle_look.h, shared with the other
// platforms. Here the functions it needs are resolved in the libvlc.so the
// AAR has already loaded, which also carries libvlccore's.

#include <dlfcn.h>
#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <stddef.h>

#include "vlc_subtitle_look.h"

static pthread_once_t open_once = PTHREAD_ONCE_INIT;
static void *libvlc = NULL;

static void open_libvlc(void) {
    libvlc = dlopen("libvlc.so", RTLD_NOW | RTLD_NOLOAD);
    if (libvlc == NULL) {
        libvlc = dlopen("libvlc.so", RTLD_NOW);
    }
}

static vlc_subtitle_look_function resolve(const char *name) {
    pthread_once(&open_once, open_libvlc);
    if (libvlc == NULL) {
        return NULL;
    }
    return (vlc_subtitle_look_function) dlsym(libvlc, name);
}

JNIEXPORT jboolean JNICALL
Java_com_lingjhf_vlc_1player_VlcNativeSubtitles_nativeApplyLook(
        JNIEnv *env, jclass clazz, jlong player, jint text_scale, jint color,
        jint background_color, jint background_opacity,
        jint outline_thickness, jint margin) {
    (void) env;
    (void) clazz;
    if (player == 0) {
        return JNI_FALSE;
    }
    vlc_subtitle_look look;
    look.text_scale = text_scale;
    look.color = color;
    look.background_color = background_color;
    look.background_opacity = background_opacity;
    look.outline_thickness = outline_thickness;
    look.margin = margin;
    return vlc_subtitle_look_apply((void *) (intptr_t) player, &look, resolve)
               ? JNI_TRUE
               : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_com_lingjhf_vlc_1player_VlcNativeSubtitles_nativeDrawnOnDisplay(
        JNIEnv *env, jclass clazz, jlong player) {
    (void) env;
    (void) clazz;
    if (player == 0) {
        return JNI_FALSE;
    }
    return vlc_subtitle_look_drawn_on_display((void *) (intptr_t) player,
                                              resolve)
               ? JNI_TRUE
               : JNI_FALSE;
}
