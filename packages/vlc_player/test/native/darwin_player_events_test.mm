// The Darwin plugins' libVLC events (darwin/VlcPlayerEvents.mm) on real VLCKit players: where a held reopen's hold
// ends, against VLCKit's own listeners, which libVLC calls before ours because VLCKit attaches them when it makes a
// player. libVLC sends a new time as PositionChanged, then TimeChanged (lib/media_player.c, INPUT_EVENT_POSITION),
// and VLCKit's TimeChanged listener queues the time the plugin's snapshots read on main (mediaPlayerTimeChanged:). A
// hold still on when that listener runs can be reported beside the new media's time: the first report that moves,
// still held, at the old picture's shape (FORK.md 30).
//
// Mac only: $SP/native-local/darwin-sink.sh builds and runs it against VLCKit 3.7.4's libVLC, with the renderer that
// darwin_renderer_sink_test.mm compiles.

#import <Foundation/Foundation.h>
#import <VLCKit/VLCKit.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <vector>

#include <vlc/vlc.h>

#include "gtest/gtest.h"

#import "VlcPlayerEvents.h"
#import "VlcTextureRenderer.h"

/// VLCKit's private bridging, re-declared as the plugins do.
@interface VLCMediaPlayer (DarwinPlayerEventsTest)
@property(readonly) void *libVLCMediaPlayer;
@end

namespace {

NSURL *Fixture(NSString *name) {
  return [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/example/assets/format_fixtures/keep_picture/%@",
                                                           VLC_PLAYER_PACKAGE, name]];
}

// Runs main, where VLCKit's listeners post, until [done] or [seconds] pass.
bool RunUntil(bool (^done)(void), double seconds) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!done()) {
    if (deadline.timeIntervalSinceNow <= 0) {
      return false;
    }
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
  }
  return true;
}

libvlc_event_manager_t *EventsOf(VLCMediaPlayer *player) {
  return libvlc_media_player_event_manager(static_cast<libvlc_media_player_t *>(player.libVLCMediaPlayer));
}

// A TimeChanged listener ahead of the plugin's, where VLCKit's is: the hold it sees at each time that moved.
struct Probe {
  __unsafe_unretained VlcPlayerEvents *events = nil;
  std::mutex mutex;
  std::vector<bool> held;
};

void OnTimeChanged(const libvlc_event_t *event, void *data) {
  if (event->u.media_player_time_changed.new_time <= 0) {
    return;
  }
  auto *probe = static_cast<Probe *>(data);
  const bool held = probe->events.pictureHeld;
  std::lock_guard<std::mutex> lock(probe->mutex);
  probe->held.push_back(held);
}

TEST(DarwinPlayerEvents, AHeldReopenHasEndedItsHoldWhenVLCKitsTimeListenerSeesTheFirstMove) {
  @autoreleasepool {
    // No audio output: macOS's writes libVLC's configuration (FORK.md 32).
    VLCLibrary *library = [[VLCLibrary alloc] initWithOptions:@[ @"--aout=dummy", @"--quiet" ]];
    VLCMediaPlayer *old = [[VLCMediaPlayer alloc] initWithLibrary:library];
    VlcTextureRenderer *renderer = [[VlcTextureRenderer alloc] initWithMediaPlayer:old];
    auto frames = std::make_shared<std::atomic<int>>(0);
    renderer.onFrameAvailable = ^{
      *frames += 1;
    };
    VlcPlayerEvents *events = [[VlcPlayerEvents alloc] initWithMediaPlayer:old renderer:renderer readLog:NO];
    old.media = [VLCMedia mediaWithURL:Fixture(@"film.mp4")];
    [old play];
    ASSERT_TRUE(RunUntil(
        ^bool {
          return frames->load() > 0;
        },
        15))
        << "the first film drew a picture";

    // replacePlayer: a fresh player on the same renderer and events, then the reopen that keeps the picture.
    VLCMediaPlayer *next = [[VLCMediaPlayer alloc] initWithLibrary:library];
    [renderer attachToMediaPlayer:next];
    Probe probe;
    probe.events = events;
    libvlc_event_attach(EventsOf(next), libvlc_MediaPlayerTimeChanged, OnTimeChanged, &probe);
    [events attachToMediaPlayer:next];
    [old stop];
    [events armWithKeepPicture:YES];
    const bool armed = events.pictureHeld;
    VLCMedia *media = [VLCMedia mediaWithURL:Fixture(@"film_4x3.mp4")];
    [media addOption:@":start-time=2"];
    next.media = media;
    [next play];
    Probe *seen = &probe;
    const bool moved = RunUntil(
        ^bool {
          std::lock_guard<std::mutex> lock(seen->mutex);
          return !seen->held.empty();
        },
        15);
    libvlc_event_detach(EventsOf(next), libvlc_MediaPlayerTimeChanged, OnTimeChanged, &probe);
    [next stop];
    [events detach];
    [renderer detach];

    ASSERT_TRUE(armed) << "the reopen held the picture";
    ASSERT_TRUE(moved) << "the new media reported a time";
    std::lock_guard<std::mutex> lock(probe.mutex);
    EXPECT_FALSE(probe.held.front()) << "the hold was still on at the new media's first time, " << probe.held.size()
                                     << " reports seen";
  }
}

}  // namespace
