#ifndef VLC_PLAYER_TEST_NATIVE_VLC_SUBTITLE_LOOK_TEST_SUITE_H_
#define VLC_PLAYER_TEST_NATIVE_VLC_SUBTITLE_LOOK_TEST_SUITE_H_

#include <cstdint>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "vlc_subtitle_look.h"

namespace vlc_player {
namespace test {
namespace subtitle_look {

// libvlccore's value union and object list, as libVLC 3 lays them out.
union FakeValue {
  int64_t i_int;
  bool b_bool;
  float f_float;
  char* psz_string;
  void* p_address;
  void* p_list;
  struct {
    int32_t x;
    int32_t y;
  } coords;
};

struct FakeList {
  int i_type;
  int i_count;
  FakeValue* p_values;
};

// A libVLC object: its type name is its first member, as in libVLC 3.
struct FakeObject {
  explicit FakeObject(const char* type) : object_type(type) {}

  const char* object_type;
  std::map<std::string, int> types;
  std::map<std::string, int64_t> integers;
  std::vector<FakeObject*> children;
};

constexpr int kInteger = 0x0030;
constexpr int kInherit = 0x8000;

struct FakeLibVlc {
  const char* version = "3.0.24 Vetinari";
  bool children_null = false;
  int creates = 0;
  int lists = 0;
  int releases = 0;
  std::vector<std::string> missing;
};

FakeLibVlc* fake = nullptr;

extern "C" {

const char* FakeGetVersion() { return fake->version; }

int FakeVarType(void* object, const char* name) {
  auto* o = static_cast<FakeObject*>(object);
  auto found = o->types.find(name);
  return found == o->types.end() ? 0 : found->second;
}

int FakeVarCreate(void* object, const char* name, int type) {
  fake->creates++;
  static_cast<FakeObject*>(object)->types[name] = type;
  return 0;
}

int FakeVarSetChecked(void* object, const char* name, int type,
                      FakeValue value) {
  auto* o = static_cast<FakeObject*>(object);
  // libVLC refuses a value for a variable that does not exist, or of
  // another type.
  auto found = o->types.find(name);
  if (found == o->types.end() || (found->second & 0xff0) != type) return -1;
  o->integers[name] = value.i_int;
  return 0;
}

FakeList* FakeListChildren(void* object) {
  if (fake->children_null) return nullptr;
  const auto& children = static_cast<FakeObject*>(object)->children;
  fake->lists++;
  auto* list = new FakeList{0, static_cast<int>(children.size()),
                            new FakeValue[children.size()]};
  for (size_t i = 0; i < children.size(); i++) {
    list->p_values[i].p_address = children[i];
  }
  return list;
}

void FakeListRelease(FakeList* list) {
  fake->releases++;
  delete[] list->p_values;
  delete list;
}

vlc_subtitle_look_function FakeResolve(const char* name) {
  for (const auto& missing : fake->missing) {
    if (missing == name) return nullptr;
  }
  if (std::strcmp(name, "libvlc_get_version") == 0) {
    return reinterpret_cast<vlc_subtitle_look_function>(&FakeGetVersion);
  }
  if (std::strcmp(name, "var_Type") == 0) {
    return reinterpret_cast<vlc_subtitle_look_function>(&FakeVarType);
  }
  if (std::strcmp(name, "var_Create") == 0) {
    return reinterpret_cast<vlc_subtitle_look_function>(&FakeVarCreate);
  }
  if (std::strcmp(name, "var_SetChecked") == 0) {
    return reinterpret_cast<vlc_subtitle_look_function>(&FakeVarSetChecked);
  }
  if (std::strcmp(name, "vlc_list_children") == 0) {
    return reinterpret_cast<vlc_subtitle_look_function>(&FakeListChildren);
  }
  if (std::strcmp(name, "vlc_list_release") == 0) {
    return reinterpret_cast<vlc_subtitle_look_function>(&FakeListRelease);
  }
  return nullptr;
}

}  // extern "C"

vlc_subtitle_look Look() {
  vlc_subtitle_look look;
  look.text_scale = 150;
  look.color = 0xFFEB3B;
  look.background_color = 0x000000;
  look.background_opacity = 128;
  look.outline_thickness = 4;
  look.margin = 40;
  return look;
}

class VlcSubtitleLook : public ::testing::Test {
 protected:
  void SetUp() override {
    lib_ = FakeLibVlc();
    fake = &lib_;
  }
  void TearDown() override { fake = nullptr; }

  FakeLibVlc lib_;
  FakeObject player_{"libvlc_media_player"};
};

TEST_F(VlcSubtitleLook, PutsEveryValueOnThePlayerForItsTextRenderers) {
  const vlc_subtitle_look look = Look();

  ASSERT_TRUE(vlc_subtitle_look_apply(&player_, &look, FakeResolve));

  EXPECT_EQ(player_.integers["sub-text-scale"], 150);
  EXPECT_EQ(player_.integers["freetype-color"], 0xFFEB3B);
  EXPECT_EQ(player_.integers["freetype-background-color"], 0x000000);
  EXPECT_EQ(player_.integers["freetype-background-opacity"], 128);
  EXPECT_EQ(player_.integers["freetype-outline-thickness"], 4);
  EXPECT_EQ(player_.integers["sub-margin"], 40);
  // Created to be inherited, as an instance option would be.
  EXPECT_EQ(player_.types["sub-text-scale"], kInteger | kInherit);
}

TEST_F(VlcSubtitleLook, MovesTheLinesOfEveryVideoOutputAtOnce) {
  FakeObject input{"input"};
  FakeObject first{"video output"};
  FakeObject audio{"audio output"};
  FakeObject second{"video output"};
  // A video output has its own margin, with a callback that moves its lines.
  first.types["sub-margin"] = kInteger | kInherit;
  second.types["sub-margin"] = kInteger | kInherit;
  input.types["sub-margin"] = kInteger;
  player_.children = {&input, &first, &audio, &second};
  const vlc_subtitle_look look = Look();

  ASSERT_TRUE(vlc_subtitle_look_apply(&player_, &look, FakeResolve));

  EXPECT_EQ(first.integers["sub-margin"], 40);
  EXPECT_EQ(second.integers["sub-margin"], 40);
  EXPECT_TRUE(input.integers.empty());
  EXPECT_TRUE(audio.integers.empty());
  EXPECT_EQ(lib_.releases, 1);
}

TEST_F(VlcSubtitleLook, CreatesEachVariableOnceHoweverOftenItIsApplied) {
  const vlc_subtitle_look look = Look();

  ASSERT_TRUE(vlc_subtitle_look_apply(&player_, &look, FakeResolve));
  const int created = lib_.creates;
  vlc_subtitle_look bigger = Look();
  bigger.text_scale = 200;
  ASSERT_TRUE(vlc_subtitle_look_apply(&player_, &bigger, FakeResolve));

  EXPECT_EQ(created, 6);
  EXPECT_EQ(lib_.creates, created);
  EXPECT_EQ(player_.integers["sub-text-scale"], 200);
}

TEST_F(VlcSubtitleLook, ChangesNothingOnAnotherLibVlc) {
  lib_.version = "4.0.0-dev Otto Chriek";
  const vlc_subtitle_look look = Look();

  EXPECT_FALSE(vlc_subtitle_look_apply(&player_, &look, FakeResolve));

  EXPECT_TRUE(player_.integers.empty());
  EXPECT_EQ(lib_.creates, 0);
}

TEST_F(VlcSubtitleLook, ChangesNothingWhenAFunctionIsMissing) {
  for (const char* name :
       {"libvlc_get_version", "var_Type", "var_Create", "var_SetChecked",
        "vlc_list_children", "vlc_list_release"}) {
    lib_.missing = {name};
    FakeObject player{"libvlc_media_player"};
    const vlc_subtitle_look look = Look();

    EXPECT_FALSE(vlc_subtitle_look_apply(&player, &look, FakeResolve))
        << name;
    EXPECT_TRUE(player.integers.empty()) << name;
  }
}

TEST_F(VlcSubtitleLook, StillStylesThePlayerWithoutAnyChildren) {
  lib_.children_null = true;
  const vlc_subtitle_look look = Look();

  ASSERT_TRUE(vlc_subtitle_look_apply(&player_, &look, FakeResolve));

  EXPECT_EQ(player_.integers["sub-margin"], 40);
  EXPECT_EQ(lib_.releases, 0);
}

// Android's hardware-decoded video: an OpenGL display, which draws the lines
// itself, at the size of the picture on screen.
class VlcSubtitleLookDisplay : public VlcSubtitleLook {
 protected:
  void SetUp() override {
    VlcSubtitleLook::SetUp();
    window_.children = {&gl_};
    output_.children = {&spu_, &window_};
    player_.children = {&input_, &output_};
  }

  FakeObject input_{"input"};
  FakeObject output_{"video output"};
  FakeObject spu_{"subpicture"};
  FakeObject window_{"window"};
  FakeObject gl_{"gl"};
};

TEST_F(VlcSubtitleLookDisplay, SaysSoWhenAVideoOutputDrawsOnOpenGL) {
  EXPECT_TRUE(vlc_subtitle_look_drawn_on_display(&player_, FakeResolve));
  EXPECT_EQ(lib_.releases, lib_.lists);
}

TEST_F(VlcSubtitleLookDisplay, SaysNoWhenTheWindowHasNoOpenGL) {
  window_.children.clear();

  EXPECT_FALSE(vlc_subtitle_look_drawn_on_display(&player_, FakeResolve));
  EXPECT_EQ(lib_.releases, lib_.lists);
}

TEST_F(VlcSubtitleLookDisplay, LooksOnlyUnderVideoOutputs) {
  // The same chain under anything else is not a display of this player's.
  FakeObject other{"audio output"};
  other.children = {&window_};
  player_.children = {&input_, &other};

  EXPECT_FALSE(vlc_subtitle_look_drawn_on_display(&player_, FakeResolve));
  EXPECT_EQ(lib_.releases, lib_.lists);
}

TEST_F(VlcSubtitleLookDisplay, SaysNoWithoutAVideoOutput) {
  player_.children = {&input_};

  EXPECT_FALSE(vlc_subtitle_look_drawn_on_display(&player_, FakeResolve));
}

TEST_F(VlcSubtitleLookDisplay, SaysNoOnAnotherLibVlcOrWithoutItsFunctions) {
  lib_.version = "4.0.0-dev Otto Chriek";
  EXPECT_FALSE(vlc_subtitle_look_drawn_on_display(&player_, FakeResolve));
  EXPECT_EQ(lib_.lists, 0);

  lib_.version = "3.0.24 Vetinari";
  for (const char* name :
       {"libvlc_get_version", "vlc_list_children", "vlc_list_release"}) {
    lib_.missing = {name};
    EXPECT_FALSE(vlc_subtitle_look_drawn_on_display(&player_, FakeResolve))
        << name;
  }
  EXPECT_FALSE(vlc_subtitle_look_drawn_on_display(nullptr, FakeResolve));
  EXPECT_FALSE(vlc_subtitle_look_drawn_on_display(&player_, nullptr));
}

TEST_F(VlcSubtitleLook, RefusesNoPlayerOrNoLook) {
  const vlc_subtitle_look look = Look();

  EXPECT_FALSE(vlc_subtitle_look_apply(nullptr, &look, FakeResolve));
  EXPECT_FALSE(vlc_subtitle_look_apply(&player_, nullptr, FakeResolve));
  EXPECT_FALSE(vlc_subtitle_look_apply(&player_, &look, nullptr));
}

}  // namespace subtitle_look
}  // namespace test
}  // namespace vlc_player

#endif  // VLC_PLAYER_TEST_NATIVE_VLC_SUBTITLE_LOOK_TEST_SUITE_H_
