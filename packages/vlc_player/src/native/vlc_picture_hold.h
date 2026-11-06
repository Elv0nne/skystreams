#ifndef VLC_PLAYER_NATIVE_VLC_PICTURE_HOLD_H_
#define VLC_PLAYER_NATIVE_VLC_PICTURE_HOLD_H_

#include <mutex>

namespace vlc_player {

// When an output keeps showing the last picture of the media before this one.
//
// libVLC 3 shows a new media's first decoded picture at once. For a media
// given a :start-time that picture is the one at 0: the input pushes the
// start as a seek that its main loop handles after its first demux (3.0
// input.c, StartTitle and MainLoop), and the decoder forces its first picture
// onto the screen while the buffer fills (decoder.c, "Received first
// picture"). A reopen at a position therefore showed the film's opening until
// the seek landed: 7 s on the iOS simulator and 9 s on the Android emulator
// at 1.5 Mbit/s (SkyStream's reopen spike, 2026-10-14).
//
// A hold ends at the first time libVLC reports for the new media. libVLC
// reports none while its buffer fills (es_out.c, ES_OUT_SET_TIMES), so the
// first one means playback runs from the start position. It has to come
// after the new media's Opening: a report already on its way from the media
// before says nothing about the new one, and on a player that changes media
// in place (Darwin) the old media's stop also arrives after the new media
// was set.
// A media that stops, ends or fails before that keeps the hold: the held
// picture is still the only right one on screen, and the next Arm or Release
// decides (SkyStream's P1 Part 3, FORK.md 30).
//
// Header-only so the Darwin renderer can include it. Thread-safe: Arm runs on
// the platform thread, the events on libVLC's threads.
class VlcPictureHold {
 public:
  enum class Change {
    // Nothing the output has to do.
    kNone,
    // Start holding the picture on screen now.
    kHold,
    // Stop holding: show libVLC's pictures again.
    kRelease,
  };

  // A new media was set. Holds when asked to and there is a picture to hold.
  // A hold already on stays on and waits for this newer media instead: by now
  // the output may hold the only right picture there is.
  Change Arm(bool keep_picture, bool has_picture) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!keep_picture) {
      const bool was_held = phase_ != Phase::kOff;
      phase_ = Phase::kOff;
      return was_held ? Change::kRelease : Change::kNone;
    }
    if (phase_ != Phase::kOff) {
      phase_ = Phase::kAwaitingOpening;
      return Change::kNone;
    }
    if (!has_picture) {
      return Change::kNone;
    }
    phase_ = Phase::kAwaitingOpening;
    return Change::kHold;
  }

  // libVLC opened a media's input.
  void OnOpening() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (phase_ == Phase::kAwaitingOpening) {
      phase_ = Phase::kAwaitingTime;
    }
  }

  // libVLC reported a time.
  Change OnTimeChanged() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (phase_ != Phase::kAwaitingTime) {
      return Change::kNone;
    }
    phase_ = Phase::kOff;
    return Change::kRelease;
  }

  // The media stopped, ended or failed. A hold outlives it: a reopen that
  // fails before it plays leaves the held picture the only right one on
  // screen, and the next Arm - another reopen keeping it, or a source that
  // doesn't - or a Release decides. Before, a hold ended here, which the C++
  // sink and the Darwin renderer let go only at a later media's first
  // picture while Android dropped its copy at once.
  Change OnMediaGone() { return Change::kNone; }

  // The output stops for good: the player was stopped or is going away.
  Change Release() {
    std::lock_guard<std::mutex> lock(mutex_);
    const bool was_held = phase_ != Phase::kOff;
    phase_ = Phase::kOff;
    return was_held ? Change::kRelease : Change::kNone;
  }

  bool held() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return phase_ != Phase::kOff;
  }

 private:
  enum class Phase { kOff, kAwaitingOpening, kAwaitingTime };

  mutable std::mutex mutex_;
  Phase phase_ = Phase::kOff;
};

}  // namespace vlc_player

#endif  // VLC_PLAYER_NATIVE_VLC_PICTURE_HOLD_H_
