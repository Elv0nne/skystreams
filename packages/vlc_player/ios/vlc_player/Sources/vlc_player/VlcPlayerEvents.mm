#import "VlcPlayerEvents.h"

#import "VlcTextureRenderer.h"

#if TARGET_OS_OSX
#import <VLCKit/VLCKit.h>
#else
#import <MobileVLCKit/MobileVLCKit.h>
#endif

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <time.h>

#include <vlc/vlc.h>

#include "vlc_picture_hold.h"

/// VLCKit's private bridging, re-declared as VlcTextureRenderer.mm does; both
/// podspecs pin the framework to an exact version.
@interface VLCMediaPlayer (VlcPlayerEventsBridging)
@property(readonly) void *libVLCMediaPlayer;
@end

@interface VLCLibrary (VlcPlayerEventsBridging)
@property(readonly) void *instance;
@end

@interface VlcPlayerEvents ()
- (void)handleEvent:(const libvlc_event_t *)event;
- (void)refusedSeekAt:(long long)microseconds;
@end

namespace {

constexpr libvlc_event_e kEvents[] = {
    libvlc_MediaPlayerOpening,          libvlc_MediaPlayerBuffering,
    libvlc_MediaPlayerTimeChanged,      libvlc_MediaPlayerStopped,
    libvlc_MediaPlayerEndReached,       libvlc_MediaPlayerEncounteredError,
    libvlc_MediaPlayerESDeleted,        libvlc_MediaPlayerESSelected,
    libvlc_MediaPlayerPositionChanged,
};

uint64_t NowNanoseconds() {
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

constexpr uint64_t kMinInterval = 100ull * 1000 * 1000;

/// Who reads each instance's refused seeks: every VlcPlayerEvents on it, held
/// weakly. Guarded by gLogMutex; the log callback copies a set out before it
/// calls anyone, so nothing runs with the lock held.
std::mutex gLogMutex;
NSMapTable<NSValue *, NSHashTable<VlcPlayerEvents *> *> *gLogReaders;

NSHashTable<VlcPlayerEvents *> *LogReadersLocked(libvlc_instance_t *instance) {
  if (gLogReaders == nil) {
    gLogReaders = [NSMapTable strongToStrongObjectsMapTable];
  }
  NSValue *key = [NSValue valueWithPointer:instance];
  NSHashTable<VlcPlayerEvents *> *readers = [gLogReaders objectForKey:key];
  if (readers == nil) {
    readers = [NSHashTable weakObjectsHashTable];
    [gLogReaders setObject:readers forKey:key];
  }
  return readers;
}

void HandleLog(void *data, int level, const libvlc_log_t *, const char *format,
               va_list arguments) {
  // Every message comes here, debug included, on libVLC's threads: only the
  // refused seek's warning is formatted (3.0.24 input.c: msg_Warn
  // "INPUT_CONTROL_SET_TIME %"PRId64" failed or not possible", microseconds).
  if (level != LIBVLC_WARNING || format == nullptr ||
      std::strstr(format, "INPUT_CONTROL_SET_TIME") == nullptr ||
      std::strstr(format, "failed or not possible") == nullptr) {
    return;
  }
  char text[160];
  va_list copy;
  va_copy(copy, arguments);
  std::vsnprintf(text, sizeof(text), format, copy);
  va_end(copy);
  const char *number = std::strpbrk(text, "0123456789");
  const long long microseconds =
      number == nullptr ? -1 : std::strtoll(number, nullptr, 10);
  @autoreleasepool {
    NSArray<VlcPlayerEvents *> *readers = nil;
    {
      std::lock_guard<std::mutex> lock(gLogMutex);
      readers =
          LogReadersLocked(static_cast<libvlc_instance_t *>(data)).allObjects;
    }
    // Every player on the instance: the controller matches the refused time
    // against its own seek, so one that sent none ignores it.
    for (VlcPlayerEvents *reader in readers) {
      [reader refusedSeekAt:microseconds];
    }
  }
}

}  // namespace

@implementation VlcPlayerEvents {
  libvlc_media_player_t *_player;
  libvlc_instance_t *_logInstance;
  VlcTextureRenderer *_renderer;
  vlc_player::VlcPictureHold _hold;
  std::atomic<float> _bufferingPercent;
  std::atomic<long long> _seekRefusals;
  std::atomic<long long> _seekRefusedAt;
  std::atomic<bool> _changePending;
  std::atomic<uint64_t> _lastChanged;
  BOOL _detached;
}

static void HandleEvent(const libvlc_event_t *event, void *data) {
  @autoreleasepool {
    [(__bridge VlcPlayerEvents *)data handleEvent:event];
  }
}

+ (void)readLogOfLibrary:(VLCLibrary *)library {
  auto *instance = static_cast<libvlc_instance_t *>(library.instance);
  if (instance != nullptr) {
    libvlc_log_set(instance, HandleLog, instance);
  }
}

- (instancetype)initWithMediaPlayer:(VLCMediaPlayer *)mediaPlayer
                           renderer:(VlcTextureRenderer *)renderer
                            readLog:(BOOL)readLog {
  self = [super init];
  if (self == nil) {
    return nil;
  }
  _bufferingPercent = -1.0f;
  _seekRefusals = 0;
  _seekRefusedAt = -1;
  _changePending = false;
  _lastChanged = 0;
  _renderer = renderer;
  [self attachEventsTo:mediaPlayer];
  if (readLog) {
    _logInstance =
        static_cast<libvlc_instance_t *>(mediaPlayer.libraryInstance.instance);
    if (_logInstance != nullptr) {
      std::lock_guard<std::mutex> lock(gLogMutex);
      [LogReadersLocked(_logInstance) addObject:self];
    }
  }
  return self;
}

- (void)dealloc {
  [self detach];
}

- (void)attachEventsTo:(VLCMediaPlayer *)mediaPlayer {
  _player = static_cast<libvlc_media_player_t *>(mediaPlayer.libVLCMediaPlayer);
  libvlc_event_manager_t *events = libvlc_media_player_event_manager(_player);
  for (libvlc_event_e type : kEvents) {
    libvlc_event_attach(events, type, HandleEvent, (__bridge void *)self);
  }
}

- (void)detachEvents {
  if (_player == nullptr) {
    return;
  }
  // Each waits out a callback already running; none of ours waits on main.
  libvlc_event_manager_t *events = libvlc_media_player_event_manager(_player);
  for (libvlc_event_e type : kEvents) {
    libvlc_event_detach(events, type, HandleEvent, (__bridge void *)self);
  }
  _player = nullptr;
}

- (void)attachToMediaPlayer:(VLCMediaPlayer *)mediaPlayer {
  if (_detached) {
    return;
  }
  // The old player's stop comes after this: it is not the new media going.
  [self detachEvents];
  _bufferingPercent = -1.0f;
  [self attachEventsTo:mediaPlayer];
}

- (void)detach {
  if (_detached) {
    return;
  }
  _detached = YES;
  [self detachEvents];
  if (_logInstance != nullptr) {
    std::lock_guard<std::mutex> lock(gLogMutex);
    [LogReadersLocked(_logInstance) removeObject:self];
    _logInstance = nullptr;
  }
  _hold.Release();
  _renderer = nil;
}

- (void)handleEvent:(const libvlc_event_t *)event {
  using Change = vlc_player::VlcPictureHold::Change;
  switch (event->type) {
    case libvlc_MediaPlayerOpening:
      _hold.OnOpening();
      _bufferingPercent = -1.0f;
      break;
    case libvlc_MediaPlayerBuffering:
      _bufferingPercent = event->u.media_player_buffering.new_cache;
      break;
    case libvlc_MediaPlayerPositionChanged:
      // libVLC sends a new time as PositionChanged, then TimeChanged
      // (lib/media_player.c, INPUT_EVENT_POSITION), and VLCKit's listeners
      // come before ours: its TimeChanged one queues on main the time the
      // next snapshot reads. The hold ends at the first of the two, so that
      // snapshot already says so (FORK.md 30).
    case libvlc_MediaPlayerTimeChanged:
      if (_hold.OnTimeChanged() == Change::kRelease) {
        [_renderer releasePicture];
        // The snapshot that says so goes out now, with the new picture's
        // size: VLCKit's own time callback (mediaPlayerTimeChanged:) can be a
        // second away, the new picture laid out at the old shape meanwhile.
        break;
      }
      // VLCKit reports times to the plugin itself (mediaPlayerTimeChanged:).
      return;
    case libvlc_MediaPlayerStopped:
    case libvlc_MediaPlayerEndReached:
    case libvlc_MediaPlayerEncounteredError:
      if (_hold.OnMediaGone() == Change::kRelease) {
        [_renderer releasePicture];
      }
      _bufferingPercent = -1.0f;
      break;
    default:
      break;
  }
  [self scheduleChanged];
}

- (void)refusedSeekAt:(long long)microseconds {
  if (_detached) {
    return;
  }
  _seekRefusedAt = microseconds < 0 ? -1 : microseconds / 1000;
  ++_seekRefusals;
  [self scheduleChanged];
}

/// One update on main as soon as possible, then at most one per 100 ms.
- (void)scheduleChanged {
  if (_changePending.exchange(true)) {
    return;
  }
  const uint64_t now = NowNanoseconds();
  const uint64_t ready = _lastChanged.load() + kMinInterval;
  const int64_t wait = ready > now ? static_cast<int64_t>(ready - now) : 0;
  __weak VlcPlayerEvents *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, wait),
                 dispatch_get_main_queue(), ^{
                   VlcPlayerEvents *strongSelf = weakSelf;
                   if (strongSelf == nil) {
                     return;
                   }
                   strongSelf->_changePending = false;
                   strongSelf->_lastChanged = NowNanoseconds();
                   if (!strongSelf->_detached && strongSelf.onChanged != nil) {
                     strongSelf.onChanged();
                   }
                 });
}

- (void)armWithKeepPicture:(BOOL)keepPicture {
  using Change = vlc_player::VlcPictureHold::Change;
  // The renderer holds at every new source, kept or not: the new video
  // output's Configure drops the picture it was showing, and a nil buffer
  // paints black. A source that doesn't keep the picture lets it go at its
  // first picture - a bridge, not a hold - so has_picture is the renderer's
  // answer, and what is reported is the decision's (FORK.md 30).
  const bool hasPicture = _renderer != nil && [_renderer holdPicture];
  switch (_hold.Arm(keepPicture, hasPicture)) {
    case Change::kHold:
      break;
    case Change::kRelease:
      [_renderer releasePicture];
      break;
    case Change::kNone:
      if (!_hold.held()) {
        [_renderer releasePicture];
      }
      break;
  }
}

- (void)stop {
  if (_hold.Release() == vlc_player::VlcPictureHold::Change::kRelease) {
    [_renderer releasePicture];
  }
}

- (double)bufferingProgress {
  const float percent = _bufferingPercent.load();
  return percent >= 0 && percent < 100 ? percent / 100.0 : -1.0;
}

- (BOOL)pictureHeld {
  // The decision, not the renderer's pixels: the renderer bridges every change
  // of source and keeps its picture through a media that fails, while a hold
  // is only what keepPicture asked for (FORK.md 30).
  return _renderer != nil && _hold.held() ? YES : NO;
}

- (NSInteger)seekRefusals {
  return static_cast<NSInteger>(_seekRefusals.load());
}

- (NSInteger)seekRefusedAt {
  return static_cast<NSInteger>(_seekRefusedAt.load());
}

@end
