#ifndef VLC_PLAYER_TEST_NATIVE_VLC_PICTURE_HOLD_TEST_SUITE_H_
#define VLC_PLAYER_TEST_NATIVE_VLC_PICTURE_HOLD_TEST_SUITE_H_

#include <gtest/gtest.h>

#include "vlc_picture_hold.h"

// Pure logic with no libVLC in it, run on every platform that builds the
// native suite.
namespace vlc_player {
namespace test {

using Change = VlcPictureHold::Change;

TEST(VlcPictureHold, HoldsOnlyWhenAskedAndThereIsAPicture) {
  VlcPictureHold hold;
  EXPECT_EQ(hold.Arm(false, true), Change::kNone);
  EXPECT_FALSE(hold.held());
  EXPECT_EQ(hold.Arm(true, false), Change::kNone);
  EXPECT_FALSE(hold.held());
  EXPECT_EQ(hold.Arm(true, true), Change::kHold);
  EXPECT_TRUE(hold.held());
}

// A time on its way from the media before is not the new one playing: only a
// time after the new media's Opening ends the hold.
TEST(VlcPictureHold, EndsAtTheFirstTimeAfterTheNewMediaOpens) {
  VlcPictureHold hold;
  ASSERT_EQ(hold.Arm(true, true), Change::kHold);
  EXPECT_EQ(hold.OnTimeChanged(), Change::kNone);
  EXPECT_TRUE(hold.held());

  hold.OnOpening();
  EXPECT_EQ(hold.OnTimeChanged(), Change::kRelease);
  EXPECT_FALSE(hold.held());
  EXPECT_EQ(hold.OnTimeChanged(), Change::kNone);
}

// A media going - the old one's stop reported after the new one was set
// (Darwin), or the new one failing, ending or stopping before it plays - never
// ends a hold: the held picture is still the only right one on screen.
TEST(VlcPictureHold, AMediaGoingNeverEndsIt) {
  VlcPictureHold hold;
  ASSERT_EQ(hold.Arm(true, true), Change::kHold);
  EXPECT_EQ(hold.OnMediaGone(), Change::kNone);
  EXPECT_TRUE(hold.held());

  hold.OnOpening();
  EXPECT_EQ(hold.OnMediaGone(), Change::kNone);
  EXPECT_TRUE(hold.held());
}

// A retry during a reconnect, or a Quality pick during a step-down: the
// output may already be showing the newer media's picture at 0, so the
// picture held before is the one to keep, until the newest media plays.
TEST(VlcPictureHold, AReopenDuringAHoldKeepsThePictureAndWaitsForTheNewest) {
  VlcPictureHold hold;
  ASSERT_EQ(hold.Arm(true, true), Change::kHold);
  hold.OnOpening();

  EXPECT_EQ(hold.Arm(true, true), Change::kNone);
  EXPECT_TRUE(hold.held());
  EXPECT_EQ(hold.OnTimeChanged(), Change::kNone);

  hold.OnOpening();
  EXPECT_EQ(hold.OnTimeChanged(), Change::kRelease);
}

TEST(VlcPictureHold, AReopenWithoutKeepPictureEndsIt) {
  VlcPictureHold hold;
  ASSERT_EQ(hold.Arm(true, true), Change::kHold);
  EXPECT_EQ(hold.Arm(false, true), Change::kRelease);
  EXPECT_FALSE(hold.held());
}

TEST(VlcPictureHold, ReleaseEndsItOnce) {
  VlcPictureHold hold;
  ASSERT_EQ(hold.Arm(true, true), Change::kHold);
  EXPECT_EQ(hold.Release(), Change::kRelease);
  EXPECT_EQ(hold.Release(), Change::kNone);
  EXPECT_FALSE(hold.held());
}

// A recovery's next reopen keeps the picture a failed one held, and waits for
// its own media to play.
TEST(VlcPictureHold, AReopenAfterAFailureCarriesTheHoldOn) {
  VlcPictureHold hold;
  ASSERT_EQ(hold.Arm(true, true), Change::kHold);
  hold.OnOpening();
  ASSERT_EQ(hold.OnMediaGone(), Change::kNone);

  EXPECT_EQ(hold.Arm(true, true), Change::kNone);
  EXPECT_TRUE(hold.held());
  EXPECT_EQ(hold.OnTimeChanged(), Change::kNone)
      << "a time before the new media's Opening says nothing about it";
  hold.OnOpening();
  EXPECT_EQ(hold.OnTimeChanged(), Change::kRelease);
  EXPECT_FALSE(hold.held());
}

// A failover after a failed reopen: a source that doesn't keep the picture
// ends the hold at once.
TEST(VlcPictureHold, APlainSourceAfterAFailureEndsIt) {
  VlcPictureHold hold;
  ASSERT_EQ(hold.Arm(true, true), Change::kHold);
  hold.OnOpening();
  ASSERT_EQ(hold.OnMediaGone(), Change::kNone);
  EXPECT_EQ(hold.Arm(false, true), Change::kRelease);
  EXPECT_FALSE(hold.held());
}

// The same media played again after it failed (a play() on the player) ends
// the hold at its first time, as any media does.
TEST(VlcPictureHold, APlayAfterAFailureEndsItAtItsFirstTime) {
  VlcPictureHold hold;
  ASSERT_EQ(hold.Arm(true, true), Change::kHold);
  hold.OnOpening();
  ASSERT_EQ(hold.OnMediaGone(), Change::kNone);
  hold.OnOpening();
  EXPECT_EQ(hold.OnTimeChanged(), Change::kRelease);
  EXPECT_FALSE(hold.held());
}

}  // namespace test
}  // namespace vlc_player

#endif  // VLC_PLAYER_TEST_NATIVE_VLC_PICTURE_HOLD_TEST_SUITE_H_
