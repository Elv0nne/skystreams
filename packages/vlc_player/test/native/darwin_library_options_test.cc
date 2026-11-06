// What the Darwin plugins put after the host's options (VlcPlayerPlugin.swift, library(for:)), read from their source
// and given to VLCKit's libVLC behind VLCKit's macOS defaults, as VLCLibrary does (VLCLibrary.m:152, 186-196): it turns
// off the pause at every end and the volume saved into libVLC's configuration (FORK.md 32).
//
// Mac only: $SP/native-local/darwin-sink.sh builds and runs it (VLC_PLAYER_PACKAGE is the package's folder). The player
// here gets macOS's real audio output, auhal, which is what writes the configuration.

#include <cstdint>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include <vlc/vlc.h>

#include "gtest/gtest.h"

// libvlccore, exported by VLCKit.
extern "C" int64_t config_GetInt(void* object, const char* name);
extern "C" int var_Inherit(void* object, const char* name, int type, void* value);

namespace vlc_player {
namespace {

constexpr int kVlcVarBool = 0x0020;  // VLC_VAR_BOOL, vlc_variables.h

// VLCKit 3.7.4's macOS defaults, in VLCLibrary.m's order, less the dialog interface (--extraintf=
// macosx_dialog_provider), which libvlc_new would start and a command-line test can't host.
constexpr const char* kVlcKitMacDefaults[] = {
    "--play-and-pause",       "--no-color",  "--no-video-title-show",    "--verbose=4",
    "--no-sout-keep",         "--vout=macosx", "--text-renderer=freetype", "--audio-resampler=soxr",
};

// The strings of `VLCLibrary(options: options + [...])` in a plugin's library(for:); none when it isn't there.
std::vector<std::string> PluginTail(const std::string& platform) {
  std::ifstream file(std::string(VLC_PLAYER_PACKAGE) + "/" + platform +
                     "/vlc_player/Sources/vlc_player/VlcPlayerPlugin.swift");
  const std::string source((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
  const std::string call = "VLCLibrary(options: options + [";
  const size_t start = source.find(call);
  if (start == std::string::npos) {
    return {};
  }
  const size_t end = source.find(']', start);
  std::vector<std::string> tail;
  for (size_t open = source.find('"', start); open < end; open = source.find('"', open)) {
    const size_t close = source.find('"', open + 1);
    tail.push_back(source.substr(open + 1, close - open - 1));
    open = close + 1;
  }
  return tail;
}

TEST(DarwinLibraryOptions, ThePluginsTailEndsAtTheEndAndSavesNoVolume) {
  const std::vector<std::string> tail = PluginTail("macos");
  EXPECT_EQ(PluginTail("ios"), tail) << "iOS and macOS make their libraries alike";
  std::vector<const char*> argv(std::begin(kVlcKitMacDefaults), std::end(kVlcKitMacDefaults));
  for (const std::string& option : tail) {
    argv.push_back(option.c_str());
  }
  argv.push_back("--quiet");
  libvlc_instance_t* instance = libvlc_new(static_cast<int>(argv.size()), argv.data());
  ASSERT_NE(instance, nullptr);
  // libvlc_instance_t starts with its libvlc_int_t (lib/libvlc_internal.h), the object the options are read from.
  void* object = *reinterpret_cast<void**>(instance);

  union {
    bool flag;
    char room[32];
  } play_and_pause = {};
  ASSERT_EQ(var_Inherit(object, "play-and-pause", kVlcVarBool, &play_and_pause), 0);
  EXPECT_FALSE(play_and_pause.flag) << "every end would be a pause";

  // A player gets its audio output when it is made (lib/media_player.c:826-828), and a volume set reaches auhal's
  // VolumeSet on this thread while the output is idle.
  libvlc_media_player_t* player = libvlc_media_player_new(instance);
  ASSERT_NE(player, nullptr);
  const int64_t before = config_GetInt(object, "auhal-volume");
  ASSERT_EQ(libvlc_audio_set_volume(player, 150), 0) << "no audio output to set the volume on";
  EXPECT_EQ(config_GetInt(object, "auhal-volume"), before) << "a volume set wrote libVLC's configuration";

  libvlc_media_player_release(player);
  libvlc_release(instance);
}

}  // namespace
}  // namespace vlc_player
