#include "vlc_plugin_cache.h"

namespace vlc_player {
namespace {

// The newest last-write time of any .dll under `directory` that is not after
// `now`, subfolders included (libVLC's plugins sit one folder down: codec\,
// demux\, ...).
void NewestPlugin(const std::wstring& directory, const FILETIME& now,
                  FILETIME* newest) {
  WIN32_FIND_DATAW entry{};
  HANDLE find = FindFirstFileW((directory + L"\\*").c_str(), &entry);
  if (find == INVALID_HANDLE_VALUE) {
    return;
  }
  do {
    const std::wstring name = entry.cFileName;
    if (name == L"." || name == L"..") {
      continue;
    }
    if (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      NewestPlugin(directory + L"\\" + name, now, newest);
      continue;
    }
    if (name.size() > 4 &&
        _wcsicmp(name.c_str() + name.size() - 4, L".dll") == 0 &&
        CompareFileTime(&entry.ftLastWriteTime, &now) <= 0 &&
        CompareFileTime(&entry.ftLastWriteTime, newest) > 0) {
      *newest = entry.ftLastWriteTime;
    }
  } while (FindNextFileW(find, &entry));
  FindClose(find);
}

}  // namespace

bool PluginCacheNeedsRebuild(const std::wstring& plugins_directory,
                             const FILETIME& app_written, const FILETIME& now) {
  WIN32_FILE_ATTRIBUTE_DATA cache{};
  if (!GetFileAttributesExW((plugins_directory + L"\\plugins.dat").c_str(),
                            GetFileExInfoStandard, &cache)) {
    return true;
  }
  // Only a time already past can show the cache is older (see the header).
  if (CompareFileTime(&app_written, &now) <= 0 &&
      CompareFileTime(&cache.ftLastWriteTime, &app_written) < 0) {
    return true;
  }
  FILETIME newest{0, 0};
  NewestPlugin(plugins_directory, now, &newest);
  return CompareFileTime(&cache.ftLastWriteTime, &newest) < 0;
}

bool PluginCacheNeedsRebuild(const std::wstring& plugins_directory,
                             const FILETIME& app_written) {
  FILETIME now{};
  GetSystemTimeAsFileTime(&now);
  return PluginCacheNeedsRebuild(plugins_directory, app_written, now);
}

}  // namespace vlc_player
