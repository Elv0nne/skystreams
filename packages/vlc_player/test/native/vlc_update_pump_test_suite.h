#ifndef VLC_PLAYER_TEST_NATIVE_VLC_UPDATE_PUMP_TEST_SUITE_H_
#define VLC_PLAYER_TEST_NATIVE_VLC_UPDATE_PUMP_TEST_SUITE_H_

#include <atomic>
#include <chrono>
#include <thread>

#include <gtest/gtest.h>

#include "vlc_update_pump.h"

// Real time, with margins wide enough for a loaded VM.
namespace vlc_player {
namespace test {

using std::chrono::milliseconds;

TEST(VlcUpdatePump, ABurstOfChangesIsOneUpdate) {
  // A 400 ms interval rather than the plugins' 100 ms: a loaded or emulated
  // machine oversleeps each sleep below by tens of milliseconds, and checks
  // 10 ms from the interval's end failed on the Windows VM.
  std::atomic<int> sends{0};
  VlcUpdatePump pump([&sends] { ++sends; }, milliseconds(400),
                     milliseconds(5000));
  pump.Start();
  for (int i = 0; i < 20; ++i) {
    pump.Wake();
  }
  std::this_thread::sleep_for(milliseconds(100));
  EXPECT_EQ(sends.load(), 1) << "the first change goes at once";

  for (int i = 0; i < 20; ++i) {
    pump.Wake();
  }
  std::this_thread::sleep_for(milliseconds(50));
  EXPECT_EQ(sends.load(), 1) << "the rest wait out the interval";
  std::this_thread::sleep_for(milliseconds(600));
  EXPECT_EQ(sends.load(), 2) << "and then go as one";
  pump.Stop();
}

TEST(VlcUpdatePump, AQuietPlayerStillUpdatesOnTheHeartbeat) {
  std::atomic<int> sends{0};
  VlcUpdatePump pump([&sends] { ++sends; }, milliseconds(100),
                     milliseconds(300));
  pump.Start();
  std::this_thread::sleep_for(milliseconds(700));
  EXPECT_GE(sends.load(), 2);
  EXPECT_LE(sends.load(), 3);
  pump.Stop();
}

TEST(VlcUpdatePump, StopReturnsPromptlyAndSendsNothingAfter) {
  std::atomic<int> sends{0};
  VlcUpdatePump pump([&sends] { ++sends; }, milliseconds(100),
                     milliseconds(1000));
  pump.Start();
  const auto started = std::chrono::steady_clock::now();
  pump.Stop();
  EXPECT_LT(std::chrono::steady_clock::now() - started, milliseconds(200));
  const int after = sends.load();
  pump.Wake();
  std::this_thread::sleep_for(milliseconds(150));
  EXPECT_EQ(sends.load(), after);
  pump.Stop();
}

}  // namespace test
}  // namespace vlc_player

#endif  // VLC_PLAYER_TEST_NATIVE_VLC_UPDATE_PUMP_TEST_SUITE_H_
