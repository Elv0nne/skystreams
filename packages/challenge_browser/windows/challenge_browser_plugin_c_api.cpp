#include "include/challenge_browser/challenge_browser_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "challenge_browser_plugin.h"

void ChallengeBrowserPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  challenge_browser::ChallengeBrowserPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
