#ifndef VLC_PLAYER_NATIVE_VLC_UPDATE_PUMP_H_
#define VLC_PLAYER_NATIVE_VLC_UPDATE_PUMP_H_

#include <chrono>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>

namespace vlc_player {

// Turns libVLC's events into snapshots for Dart, for the Windows and Linux
// wrappers: one update as soon as something changes, at most one per
// min_interval while changes keep coming, and one per heartbeat regardless
// (spec 4: "one update per 100 ms at most ... A 1 s heartbeat stays as a
// safety net").
//
// It replaced a thread that slept 500 ms between snapshots. libVLC's HLS time
// moves in steps of about a second, so a 500 ms poll saw a step up to half a
// second late, and the controller's one-second stall clock went off for a few
// milliseconds at segment boundaries (SkyStream's QoE suite on Windows,
// 2026-10-13).
class VlcUpdatePump {
 public:
  VlcUpdatePump(std::function<void()> send,
                std::chrono::milliseconds min_interval,
                std::chrono::milliseconds heartbeat);
  ~VlcUpdatePump();

  VlcUpdatePump(const VlcUpdatePump&) = delete;
  VlcUpdatePump& operator=(const VlcUpdatePump&) = delete;

  void Start();
  // Something a snapshot reports may have changed. Cheap, and safe on any
  // thread: libVLC's event threads call it.
  void Wake();
  // Ends the thread and waits for it. Idempotent.
  void Stop();

 private:
  void Run();

  const std::function<void()> send_;
  const std::chrono::milliseconds min_interval_;
  const std::chrono::milliseconds heartbeat_;
  std::mutex mutex_;
  std::condition_variable wake_;
  bool dirty_ = false;
  bool running_ = false;
  std::thread thread_;
};

}  // namespace vlc_player

#endif  // VLC_PLAYER_NATIVE_VLC_UPDATE_PUMP_H_
