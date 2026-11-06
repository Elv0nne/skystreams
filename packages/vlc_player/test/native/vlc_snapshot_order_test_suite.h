#ifndef VLC_PLAYER_TEST_NATIVE_VLC_SNAPSHOT_ORDER_TEST_SUITE_H_
#define VLC_PLAYER_TEST_NATIVE_VLC_SNAPSHOT_ORDER_TEST_SUITE_H_

#include <cstdint>
#include <string>

#include <gtest/gtest.h>

#include "vlc_snapshot_order.h"

// Windows and Linux make snapshots on two threads, the update pump's and the
// platform thread's after a command, and send each as it is finished
// (FORK.md 37).
namespace vlc_player {
namespace test {

namespace {

VlcSnapshot MadeAs(uint64_t sequence, const std::string& state) {
  VlcSnapshot snapshot;
  snapshot.sequence = sequence;
  snapshot.state = state;
  return snapshot;
}

}  // namespace

TEST(VlcSnapshotOrder, ASnapshotMadeBeforeTheLastSentIsDropped) {
  // The pump made the failed player's "playing" before a SetSource, and
  // SetSource's "opening" went first: Dart read the late one as the parked
  // media playing (P1 Part 3's Windows outage rows).
  VlcSnapshotOrder order;
  EXPECT_TRUE(order.Admit(MadeAs(2, "opening"), false));
  EXPECT_FALSE(order.Admit(MadeAs(1, "playing"), false));
  EXPECT_TRUE(order.Admit(MadeAs(3, "playing"), false));
}

TEST(VlcSnapshotOrder, ARepeatIsNotSentAgainUnlessForced) {
  VlcSnapshotOrder order;
  EXPECT_TRUE(order.Admit(MadeAs(1, "playing"), false));
  EXPECT_FALSE(order.Admit(MadeAs(2, "playing"), false));
  EXPECT_TRUE(order.Admit(MadeAs(3, "playing"), true));
}

TEST(VlcSnapshotOrder, AForcedSnapshotKeepsTheOrderToo) {
  VlcSnapshotOrder order;
  EXPECT_TRUE(order.Admit(MadeAs(5, "opening"), false));
  EXPECT_FALSE(order.Admit(MadeAs(4, "playing"), true));
}

TEST(VlcSnapshotOrder, ACommandsSnapshotIsNotTakenForARepeatOfOneStillQueued) {
  // Linux admits where it delivers: the pump's snapshot, made after the hold
  // was armed and queued to the main thread, is not yet admitted when the
  // command's own runs there, so the command's goes out at once and setSource
  // answers after it (FORK.md 33); the queued one, older, follows nothing.
  VlcSnapshotOrder order;
  EXPECT_TRUE(order.Admit(MadeAs(1, "playing"), false));
  EXPECT_TRUE(order.Admit(MadeAs(3, "opening"), false));
  EXPECT_FALSE(order.Admit(MadeAs(2, "opening"), false));
}

}  // namespace test
}  // namespace vlc_player

#endif  // VLC_PLAYER_TEST_NATIVE_VLC_SNAPSHOT_ORDER_TEST_SUITE_H_
