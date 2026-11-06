// See vlc_subtitle_look.h. Written to compile as C (Android's shim) and as
// C++ (the Darwin plugins pull the shared sources into a C++ file).
#include "vlc_subtitle_look.h"

#include <stddef.h>
#include <string.h>

// libvlccore's value union, object list and variable types, as VLC 3.0's
// vlc_common.h and vlc_variables.h declare them.
typedef union look_value {
  int64_t i_int;
  bool b_bool;
  float f_float;
  char *psz_string;
  void *p_address;
  void *p_list;
  struct {
    int32_t x;
    int32_t y;
  } coords;
} look_value;

typedef struct look_list {
  int i_type;
  int i_count;
  look_value *p_values;
} look_list;

#define LOOK_VAR_INTEGER 0x0030
#define LOOK_VAR_DOINHERIT 0x8000

typedef const char *(*look_get_version_fn)(void);
typedef int (*look_var_type_fn)(void *object, const char *name);
typedef int (*look_var_create_fn)(void *object, const char *name, int type);
typedef int (*look_var_set_fn)(void *object, const char *name, int type,
                               look_value value);
typedef look_list *(*look_list_children_fn)(void *object);
typedef void (*look_list_release_fn)(look_list *list);

typedef struct look_functions {
  look_var_type_fn type;
  look_var_create_fn create;
  look_var_set_fn set;
} look_functions;

// Whether [resolve] has found the libVLC whose objects and variables these
// are: 3.0's.
static bool look_is_3_0(look_get_version_fn version) {
  const char *running = version == NULL ? NULL : version();
  return running != NULL && strncmp(running, "3.0.", 4) == 0;
}

// Whether [object] is a libVLC object of [type]: a libVLC 3 object's type
// name is its first member.
static bool look_is(void *object, const char *type) {
  const char *object_type = object == NULL ? NULL : *(const char **)object;
  return object_type != NULL && strcmp(object_type, type) == 0;
}

// Sets the integer [name] on [object], first creating it there - inherited by
// what is made below it, as an instance option is - if it does not exist.
static void look_set_integer(const look_functions *fns, void *object,
                             const char *name, int64_t value) {
  if (fns->type(object, name) == 0) {
    fns->create(object, name, LOOK_VAR_INTEGER | LOOK_VAR_DOINHERIT);
  }
  look_value v;
  memset(&v, 0, sizeof v);
  v.i_int = value;
  fns->set(object, name, LOOK_VAR_INTEGER, v);
}

bool vlc_subtitle_look_apply(void *player, const vlc_subtitle_look *look,
                             vlc_subtitle_look_resolver resolve) {
  if (player == NULL || look == NULL || resolve == NULL) return false;

  look_get_version_fn version =
      (look_get_version_fn)resolve("libvlc_get_version");
  look_functions fns;
  fns.type = (look_var_type_fn)resolve("var_Type");
  fns.create = (look_var_create_fn)resolve("var_Create");
  fns.set = (look_var_set_fn)resolve("var_SetChecked");
  look_list_children_fn children =
      (look_list_children_fn)resolve("vlc_list_children");
  look_list_release_fn release =
      (look_list_release_fn)resolve("vlc_list_release");
  if (version == NULL || fns.type == NULL || fns.create == NULL ||
      fns.set == NULL || children == NULL || release == NULL) {
    return false;
  }
  // The variables, and the layout of the objects walked below, are 3.0's.
  if (!look_is_3_0(version)) return false;

  // On the player: each text renderer under it reads these again whenever it
  // draws a line, and a video output made later starts from them.
  look_set_integer(&fns, player, "sub-text-scale", look->text_scale);
  look_set_integer(&fns, player, "freetype-color", look->color);
  look_set_integer(&fns, player, "freetype-background-color",
                   look->background_color);
  look_set_integer(&fns, player, "freetype-background-opacity",
                   look->background_opacity);
  look_set_integer(&fns, player, "freetype-outline-thickness",
                   look->outline_thickness);
  look_set_integer(&fns, player, "sub-margin", look->margin);

  // A video output that already exists has a margin of its own, and moving
  // it moves the lines on screen at once. Video outputs are the player's
  // children.
  look_list *list = children(player);
  if (list != NULL) {
    for (int i = 0; i < list->i_count; i++) {
      void *child = list->p_values[i].p_address;
      if (look_is(child, "video output")) {
        look_value v;
        memset(&v, 0, sizeof v);
        v.i_int = look->margin;
        fns.set(child, "sub-margin", LOOK_VAR_INTEGER, v);
      }
    }
    release(list);
  }
  return true;
}

bool vlc_subtitle_look_drawn_on_display(void *player,
                                        vlc_subtitle_look_resolver resolve) {
  if (player == NULL || resolve == NULL) return false;
  look_get_version_fn version =
      (look_get_version_fn)resolve("libvlc_get_version");
  look_list_children_fn children =
      (look_list_children_fn)resolve("vlc_list_children");
  look_list_release_fn release =
      (look_list_release_fn)resolve("vlc_list_release");
  if (children == NULL || release == NULL || !look_is_3_0(version)) {
    return false;
  }

  // player > video output > window > gl (VLC 3.0 src/video_output/window.c,
  // vout_display_window_New, and src/video_output/opengl.c, vlc_gl_Create).
  bool drawn = false;
  look_list *outputs = children(player);
  if (outputs == NULL) return false;
  for (int i = 0; i < outputs->i_count && !drawn; i++) {
    void *output = outputs->p_values[i].p_address;
    if (!look_is(output, "video output")) continue;
    look_list *windows = children(output);
    if (windows == NULL) continue;
    for (int j = 0; j < windows->i_count && !drawn; j++) {
      void *window = windows->p_values[j].p_address;
      if (!look_is(window, "window")) continue;
      look_list *contexts = children(window);
      if (contexts == NULL) continue;
      for (int k = 0; k < contexts->i_count && !drawn; k++) {
        drawn = look_is(contexts->p_values[k].p_address, "gl");
      }
      release(contexts);
    }
    release(windows);
  }
  release(outputs);
  return drawn;
}
