#ifndef VLC_PLAYER_WINDOWS_VLC_PLUGIN_CACHE_H_
#define VLC_PLAYER_WINDOWS_VLC_PLUGIN_CACHE_H_

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <string>

namespace vlc_player {

// Whether the process's first libVLC instance should rebuild libVLC's plugin
// cache (`plugins\plugins.dat`): when it is missing, older than the app's
// executable (an update brings its own plugins), or older than any plugin
// DLL.
//
// Without a cache libVLC 3 loads every plugin DLL when its first instance is
// made: 22.6-24.4 s on the Windows VM when the DLLs were freshly written, as
// after an install (spec 1.7, FORK.md 22); with one it loads only what a media
// needs. It trusts a cached entry only if the DLL's modified time and size
// match exactly, and writes the cache only when asked (--reset-plugins-cache).
// The installer makes the cache with vlc-cache-gen.exe; the portable build has
// none until its first launch writes one, since a ZIP's local, two-second
// timestamps would leave a cache made anywhere else stale.
//
// A time after `now` proves nothing: a ZIP (and an installer built without
// Inno Setup's TimeStampsInUTC) restores the build's clock reading in the
// user's time zone, which west of the build machine's is hours ahead, and no
// cache written meanwhile could be newer, so every launch until the clock
// caught up would load all the plugins.
bool PluginCacheNeedsRebuild(const std::wstring& plugins_directory,
                             const FILETIME& app_written, const FILETIME& now);

// The same, against the system clock.
bool PluginCacheNeedsRebuild(const std::wstring& plugins_directory,
                             const FILETIME& app_written);

}  // namespace vlc_player

#endif  // VLC_PLAYER_WINDOWS_VLC_PLUGIN_CACHE_H_
