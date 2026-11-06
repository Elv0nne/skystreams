// The look of the subtitle lines libVLC draws into the picture, changed while
// the video plays.
//
// libVLC 3 takes a text style only as options when its instance is created,
// and has no public call to change one later. But its text renderer reads the
// scale, the colours, the background and the outline again each time it
// draws a line, from variables it inherits from the media player; and a
// video output moves its lines when its own "sub-margin" changes. libVLC's
// own macOS app restyles subtitles live this way. The functions that set
// those variables are libvlccore's, exported by every libVLC 3 build shipped
// (libvlc-android's libvlc.so, VLCKit, the Windows SDK, Linux's system
// libvlccore). Each platform hands them over through a resolver: Android,
// Windows and Linux look them up at run time, and nothing changes where one is
// missing or the library is not 3.0; Darwin links them, so a VLCKit without
// them would not build (the pinned 3.7.4 frameworks export all six).
//
// What it cannot reach: a line already on screen keeps its look until the next
// (the margin moves it at once); SSA/ASS tracks, drawn by libass with styles
// of their own, and bitmap tracks keep theirs (the margin still moves them);
// CEA-608 captions, laid out on their own grid, ignore the scale, and their
// colours, like CEA-708's, override this one.
#ifndef VLC_PLAYER_SRC_NATIVE_VLC_SUBTITLE_LOOK_H_
#define VLC_PLAYER_SRC_NATIVE_VLC_SUBTITLE_LOOK_H_

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The look, in libVLC's own terms.
typedef struct vlc_subtitle_look {
  // Percent of the size the instance was created with ("sub-text-scale");
  // libVLC holds it to 10..500.
  int text_scale;
  // 0xRRGGBB ("freetype-color").
  int color;
  // 0xRRGGBB ("freetype-background-color").
  int background_color;
  // 0..255, 0 drawing no box ("freetype-background-opacity").
  int background_opacity;
  // Percent of the glyph size ("freetype-outline-thickness"); 0 draws none.
  int outline_thickness;
  // Pixels the lines are raised by ("sub-margin"): of the decoded picture,
  // or of the picture on screen where vlc_subtitle_look_drawn_on_display
  // says the lines are drawn there.
  int margin;
} vlc_subtitle_look;

// Any function, as a resolver hands it back.
typedef void (*vlc_subtitle_look_function)(void);

// Looks up one of libVLC's exported functions by name: dlsym, or
// GetProcAddress. NULL when it is not there. A function pointer rather than a
// void *, which C compilers may not convert to one without complaint.
typedef vlc_subtitle_look_function (*vlc_subtitle_look_resolver)(
    const char *name);

// Applies [look] to [player], a libvlc_media_player_t *: its text tracks show
// it from their next line, and its video outputs move their lines at once.
// Video outputs made later inherit it.
//
// Returns false, changing nothing, when this libVLC is not 3.0 or [resolve]
// cannot find every function needed.
bool vlc_subtitle_look_apply(void *player, const vlc_subtitle_look *look,
                             vlc_subtitle_look_resolver resolve);

// Whether a video output of [player] draws its subtitle lines itself, on an
// OpenGL display: Android's platform view, whatever decodes. Such a display
// lays the lines out at the size of the picture on screen whenever that is
// the larger, and takes "sub-margin" in its pixels rather than the decoded
// picture's (VLC 3.0 src/video_output/video_output.c,
// ThreadDisplayRenderPicture, and vout_subpictures.c, SpuRenderRegion). Told
// by the objects libVLC hangs under a video output: its window, and the
// window's OpenGL context.
//
// False when none does, this libVLC is not 3.0, or [resolve] cannot find
// what is needed.
bool vlc_subtitle_look_drawn_on_display(void *player,
                                        vlc_subtitle_look_resolver resolve);

#ifdef __cplusplus
}
#endif

#endif  // VLC_PLAYER_SRC_NATIVE_VLC_SUBTITLE_LOOK_H_
