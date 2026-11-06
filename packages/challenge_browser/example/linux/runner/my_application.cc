#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <cstring>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// For the integration tests: Tab, Escape, Space and clicks, handed to GTK as the windowing system hands
// a person's, to whatever has keyboard focus or is under the pointer.
static void send_key(GtkWidget* window, guint keyval, guint16 keycode, GdkModifierType state,
                     gboolean press) {
  GdkEvent* event = gdk_event_new(press ? GDK_KEY_PRESS : GDK_KEY_RELEASE);
  event->key.window = GDK_WINDOW(g_object_ref(gtk_widget_get_window(window)));
  event->key.time = GDK_CURRENT_TIME;
  event->key.state = state;
  event->key.keyval = keyval;
  event->key.hardware_keycode = keycode;
  event->key.is_modifier = keyval == GDK_KEY_Shift_L;
  GdkSeat* seat = gdk_display_get_default_seat(gtk_widget_get_display(window));
  gdk_event_set_device(event, gdk_seat_get_keyboard(seat));
  gtk_main_do_event(event);
  gdk_event_free(event);
}

// The topmost visible window at (x, y) in [window], and the point in that window.
static GdkWindow* window_at(GdkWindow* window, gdouble* x, gdouble* y) {
  for (GList* child = gdk_window_peek_children(window); child; child = child->next) {
    GdkWindow* candidate = GDK_WINDOW(child->data);
    if (!gdk_window_is_visible(candidate)) continue;
    gint left, top;
    gdk_window_get_position(candidate, &left, &top);
    if (*x < left || *y < top || *x >= left + gdk_window_get_width(candidate) ||
        *y >= top + gdk_window_get_height(candidate)) {
      continue;
    }
    *x -= left;
    *y -= top;
    return window_at(candidate, x, y);
  }
  return window;
}

static void send_click(FlView* view, gdouble x, gdouble y) {
  GtkAllocation allocation;
  gtk_widget_get_allocation(GTK_WIDGET(view), &allocation);
  x += allocation.x;
  y += allocation.y;
  GdkWindow* target = window_at(gtk_widget_get_window(GTK_WIDGET(view)), &x, &y);
  GdkSeat* seat = gdk_display_get_default_seat(gdk_window_get_display(target));
  const GdkEventType types[] = {GDK_BUTTON_PRESS, GDK_BUTTON_RELEASE};
  for (GdkEventType type : types) {
    GdkEvent* event = gdk_event_new(type);
    event->button.window = GDK_WINDOW(g_object_ref(target));
    event->button.time = GDK_CURRENT_TIME;
    event->button.x = x;
    event->button.y = y;
    gint root_x, root_y;
    gdk_window_get_root_coords(target, static_cast<gint>(x), static_cast<gint>(y), &root_x, &root_y);
    event->button.x_root = root_x;
    event->button.y_root = root_y;
    event->button.button = 1;
    event->button.state = type == GDK_BUTTON_PRESS ? 0 : GDK_BUTTON1_MASK;
    gdk_event_set_device(event, gdk_seat_get_pointer(seat));
    gdk_event_set_source_device(event, gdk_seat_get_pointer(seat));
    gtk_main_do_event(event);
    gdk_event_free(event);
  }
}

static void keys_cb(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
  FlView* view = FL_VIEW(user_data);
  GtkWidget* window = gtk_widget_get_toplevel(GTK_WIDGET(view));
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlValue) result = nullptr;
  if (strcmp(method, "focusFlutter") == 0) {
    // As a click on Flutter's content would.
    gtk_window_present(GTK_WINDOW(window));
    gtk_widget_grab_focus(GTK_WIDGET(view));
    result = fl_value_new_bool(gtk_window_is_active(GTK_WINDOW(window)));
  } else if (strcmp(method, "tab") == 0) {
    const gboolean shift = fl_value_get_type(args) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(args);
    const guint tab = shift ? GDK_KEY_ISO_Left_Tab : GDK_KEY_Tab;
    const GdkModifierType state = shift ? GDK_SHIFT_MASK : static_cast<GdkModifierType>(0);
    if (shift) send_key(window, GDK_KEY_Shift_L, 50, static_cast<GdkModifierType>(0), TRUE);
    send_key(window, tab, 23, state, TRUE);
    send_key(window, tab, 23, state, FALSE);
    if (shift) send_key(window, GDK_KEY_Shift_L, 50, GDK_SHIFT_MASK, FALSE);
  } else if (strcmp(method, "escape") == 0) {
    send_key(window, GDK_KEY_Escape, 9, static_cast<GdkModifierType>(0), TRUE);
    send_key(window, GDK_KEY_Escape, 9, static_cast<GdkModifierType>(0), FALSE);
  } else if (strcmp(method, "space") == 0) {
    send_key(window, GDK_KEY_space, 65, static_cast<GdkModifierType>(0), TRUE);
    send_key(window, GDK_KEY_space, 65, static_cast<GdkModifierType>(0), FALSE);
  } else if (strcmp(method, "click") == 0) {
    send_click(view, fl_value_get_float(fl_value_get_list_value(args, 0)),
               fl_value_get_float(fl_value_get_list_value(args, 1)));
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  fl_method_call_respond_success(call, result, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "challenge_browser_example");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "challenge_browser_example");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  // challenge_browser lays its pages over Flutter's view.
  GtkWidget* overlay = gtk_overlay_new();
  gtk_widget_show(overlay);
  gtk_container_add(GTK_CONTAINER(overlay), GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), overlay);

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* keys = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "challenge_browser_example/keys", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(keys, keys_cb, view, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
