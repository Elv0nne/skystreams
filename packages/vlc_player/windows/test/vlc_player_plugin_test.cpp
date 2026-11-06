// Ahead of anything that may include windows.h, which would pull in the old
// winsock.h: the native suite's test server uses Winsock 2. NOMINMAX first,
// as the plugin's own sources have it, or windows.h's min and max macros
// break std::numeric_limits<>::max() and time_point::max().
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>

#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>
#include <windows.h>

#include <cstdint>
#include <fstream>
#include <memory>
#include <string>
#include <variant>
#include <vector>

#include "vlc_player_core.h"
#include "vlc_player_plugin.h"
#include "vlc_plugin_cache.h"
#include "../../test/native/vlc_player_core_test_suite.h"
#include "../../test/native/vlc_snapshot_order_test_suite.h"
#include "../../test/native/vlc_subtitle_look_test_suite.h"

namespace vlc_player {
namespace test {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

}  // namespace

TEST(VlcPlayerPlugin, MissingPlayerReturnsPlayerNotFound) {
  VlcPlayerPlugin plugin(nullptr, nullptr);

  std::string error_code;
  std::string error_message;
  EncodableMap arguments;
  arguments[EncodableValue("viewId")] = EncodableValue(int64_t{42});

  plugin.HandleMethodCall(
      MethodCall("play", std::make_unique<EncodableValue>(arguments)),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code, &error_message](const std::string &code,
                                        const std::string &message,
                                        const EncodableValue *details) {
            error_code = code;
            error_message = message;
          },
          nullptr));

  EXPECT_EQ(error_code, "player_not_found");
  EXPECT_NE(error_message.find("viewId 42"), std::string::npos);
}

std::vector<std::string> VlcPlayerCoreTestOptions() {
  return {};
}

namespace {

// A plugins folder in %TEMP%, with one DLL in a subfolder as libVLC's has.
struct PluginsFolder {
  std::wstring root;

  PluginsFolder() {
    wchar_t temp[MAX_PATH];
    GetTempPathW(MAX_PATH, temp);
    root = std::wstring(temp) + L"vlc_plugin_cache_test_" +
           std::to_wstring(GetCurrentProcessId());
    CreateDirectoryW(root.c_str(), nullptr);
    CreateDirectoryW((root + L"\\codec").c_str(), nullptr);
    std::ofstream(root + L"\\codec\\libx_plugin.dll") << "x";
  }
  ~PluginsFolder() {
    DeleteFileW((root + L"\\codec\\libx_plugin.dll").c_str());
    DeleteFileW((root + L"\\plugins.dat").c_str());
    RemoveDirectoryW((root + L"\\codec").c_str());
    RemoveDirectoryW(root.c_str());
  }
};

FILETIME FileTimeAt(int64_t seconds_after_2020) {
  // 2020-01-01T00:00:00Z in FILETIME units.
  const uint64_t base = 132223104000000000ULL;
  const uint64_t value = base + static_cast<uint64_t>(seconds_after_2020) *
                                    10000000ULL;
  return FILETIME{static_cast<DWORD>(value & 0xffffffff),
                  static_cast<DWORD>(value >> 32)};
}

void Touch(const std::wstring &path, const FILETIME &at) {
  HANDLE file = CreateFileW(path.c_str(), FILE_WRITE_ATTRIBUTES, 0, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  SetFileTime(file, nullptr, nullptr, &at);
  CloseHandle(file);
}

}  // namespace

TEST(VlcPluginCache, RebuildsWhenMissingStaleOrOlderThanTheApp) {
  PluginsFolder folder;
  Touch(folder.root + L"\\codec\\libx_plugin.dll", FileTimeAt(100));
  const FILETIME app = FileTimeAt(200);

  EXPECT_TRUE(PluginCacheNeedsRebuild(folder.root, app)) << "no cache";

  std::ofstream(folder.root + L"\\plugins.dat") << "cache";
  Touch(folder.root + L"\\plugins.dat", FileTimeAt(300));
  EXPECT_FALSE(PluginCacheNeedsRebuild(folder.root, app));

  Touch(folder.root + L"\\plugins.dat", FileTimeAt(150));
  EXPECT_TRUE(PluginCacheNeedsRebuild(folder.root, app))
      << "an app newer than its cache brought plugins of its own";

  Touch(folder.root + L"\\plugins.dat", FileTimeAt(300));
  Touch(folder.root + L"\\codec\\libx_plugin.dll", FileTimeAt(400));
  EXPECT_TRUE(PluginCacheNeedsRebuild(folder.root, app))
      << "a plugin changed after the cache was written";
}

TEST(VlcPluginCache, ATimeStillToComeProvesNothing) {
  // A ZIP (and an installer built without Inno Setup's TimeStampsInUTC)
  // restores a build's clock reading in the user's time zone, so west of the
  // build machine's the app and its plugins can be dated hours ahead of the
  // clock. No cache written meanwhile can be newer: every launch until the
  // clock caught up would load all 360 plugins.
  PluginsFolder folder;
  const FILETIME now = FileTimeAt(1000);
  const FILETIME ahead = FileTimeAt(1000 + 8 * 3600);
  Touch(folder.root + L"\\codec\\libx_plugin.dll", ahead);
  std::ofstream(folder.root + L"\\plugins.dat") << "cache";
  Touch(folder.root + L"\\plugins.dat", FileTimeAt(900));

  EXPECT_FALSE(PluginCacheNeedsRebuild(folder.root, ahead, now))
      << "an app and plugins dated after the clock";

  std::ofstream(folder.root + L"\\codec\\liby_plugin.dll") << "y";
  Touch(folder.root + L"\\codec\\liby_plugin.dll", FileTimeAt(950));
  EXPECT_TRUE(PluginCacheNeedsRebuild(folder.root, ahead, now))
      << "a plugin changed after the cache, at a time already past";

  DeleteFileW((folder.root + L"\\plugins.dat").c_str());
  EXPECT_TRUE(PluginCacheNeedsRebuild(folder.root, ahead, now)) << "no cache";
  DeleteFileW((folder.root + L"\\codec\\liby_plugin.dll").c_str());
}

}  // namespace test
}  // namespace vlc_player
