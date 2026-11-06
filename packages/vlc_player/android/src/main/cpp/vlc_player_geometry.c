// libVLC's crop, which libvlc-android 3.x does not expose in Java.
//
// Zoom has libVLC crop the picture to the view's shape, so the subtitles it
// draws land inside what is shown instead of in the part a larger-than-screen
// picture loses off the edge. MediaPlayer has setAspectRatio and setScale but
// nothing for crop, so this resolves libvlc_video_set_crop_geometry in the
// libvlc.so the AAR has already loaded and calls it with the player's native
// pointer. VLCObject.getInstance() returns the libvlc_media_player_t itself:
// the word at offset 8 of libvlcjni's object, which is the same pointer its
// own nativeSetAspectRatio hands to libvlc_video_set_aspect_ratio (read from
// the libvlc-all 3.7.0 arm64 libvlcjni.so).

#include <dlfcn.h>
#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <stddef.h>

typedef void (*set_crop_geometry_fn)(void *player, const char *geometry);

static pthread_once_t resolve_once = PTHREAD_ONCE_INIT;
static set_crop_geometry_fn set_crop_geometry = NULL;

static void resolve(void) {
    // Already loaded by LibVLC; RTLD_NOLOAD finds it without loading a second
    // copy, and the plain open is only a fallback for an unexpected order.
    void *libvlc = dlopen("libvlc.so", RTLD_NOW | RTLD_NOLOAD);
    if (libvlc == NULL) {
        libvlc = dlopen("libvlc.so", RTLD_NOW);
    }
    if (libvlc != NULL) {
        set_crop_geometry = (set_crop_geometry_fn) dlsym(
                libvlc, "libvlc_video_set_crop_geometry");
    }
}

JNIEXPORT jboolean JNICALL
Java_com_lingjhf_vlc_1player_VlcNativeGeometry_nativeSetCropGeometry(
        JNIEnv *env, jclass clazz, jlong player, jstring geometry) {
    (void) clazz;
    pthread_once(&resolve_once, resolve);
    if (set_crop_geometry == NULL || player == 0) {
        return JNI_FALSE;
    }
    const char *value = NULL;
    if (geometry != NULL) {
        value = (*env)->GetStringUTFChars(env, geometry, NULL);
        if (value == NULL) {
            return JNI_FALSE;
        }
    }
    // NULL lifts the crop; libVLC copies the string before returning.
    set_crop_geometry((void *) (intptr_t) player, value);
    if (value != NULL) {
        (*env)->ReleaseStringUTFChars(env, geometry, value);
    }
    return JNI_TRUE;
}
