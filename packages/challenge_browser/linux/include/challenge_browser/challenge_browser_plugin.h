#ifndef FLUTTER_PLUGIN_CHALLENGE_BROWSER_PLUGIN_H_
#define FLUTTER_PLUGIN_CHALLENGE_BROWSER_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

// Pages are laid over Flutter's view: the app's runner must put the FlView in a GtkOverlay.
FLUTTER_PLUGIN_EXPORT void challenge_browser_plugin_register_with_registrar(FlPluginRegistrar* registrar);

G_END_DECLS

#endif  // FLUTTER_PLUGIN_CHALLENGE_BROWSER_PLUGIN_H_
