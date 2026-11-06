// The Darwin renderer's sink (darwin/VlcTextureRenderer.mm), driven the way libVLC 3.0's vmem drives it: through the
// real VlcVideoOutput, on real libVLC players, by the callbacks libvlc_video_set_callbacks and _set_format_callbacks
// left on them. vmem's Prepare calls lock, copies the whole picture into the planes lock returned, and only then calls
// unlock (vmem.c:245-269); a Detach stops the next lock, not that copy (FORK.md 31). The checks read the planes'
// mapping with mach_vm_region and never write to them, so a sink that frees a locked picture fails here rather than
// crashing.
//
// Mac only: $SP/native-local/darwin-sink.sh builds and runs it against VLCKit 3.7.4's libVLC. The renderer's
// translation unit is included whole, because its sink is in an anonymous namespace.

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <mach/mach.h>
#include <mach/mach_vm.h>

#include <cstring>
#include <memory>
#include <vector>

#include "gtest/gtest.h"

#include "VlcTextureRenderer.mm"

// libvlccore, exported by VLCKit: what reads the callbacks back off a player.
extern "C" int var_GetChecked(void* object, const char* name, int type, void* value);

namespace vlc_player {
namespace {

constexpr int kVlcVarAddress = 0x0070;  // VLC_VAR_ADDRESS, vlc_variables.h

// What vmem's Open reads off its player (vmem.c:124-135).
struct Vmem {
  using Setup = unsigned (*)(void**, char*, unsigned*, unsigned*, unsigned*, unsigned*);
  using Lock = void* (*)(void*, void**);
  using Unlock = void (*)(void*, void*, void* const*);
  using Display = void (*)(void*, void*);
  Setup setup = nullptr;
  Lock lock = nullptr;
  Unlock unlock = nullptr;
  Display display = nullptr;
  void* opaque = nullptr;
};

void* Address(libvlc_media_player_t* player, const char* name) {
  // vlc_value_t is a union of at most 8 bytes in libVLC 3; the room spare does no harm.
  union {
    void* address;
    char room[32];
  } value = {};
  return var_GetChecked(player, name, kVlcVarAddress, &value) == 0 ? value.address : nullptr;
}

Vmem VmemOf(libvlc_media_player_t* player) {
  Vmem vmem;
  vmem.setup = reinterpret_cast<Vmem::Setup>(Address(player, "vmem-setup"));
  vmem.lock = reinterpret_cast<Vmem::Lock>(Address(player, "vmem-lock"));
  vmem.unlock = reinterpret_cast<Vmem::Unlock>(Address(player, "vmem-unlock"));
  vmem.display = reinterpret_cast<Vmem::Display>(Address(player, "vmem-display"));
  vmem.opaque = Address(player, "vmem-data");
  return vmem;
}

bool Mapped(const void* p) {
  mach_vm_address_t address = reinterpret_cast<mach_vm_address_t>(p);
  mach_vm_size_t size = 0;
  vm_region_basic_info_data_64_t info;
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t object = MACH_PORT_NULL;
  const kern_return_t result = mach_vm_region(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
                                              reinterpret_cast<vm_region_info_t>(&info), &count, &object);
  return result == KERN_SUCCESS && address <= reinterpret_cast<mach_vm_address_t>(p) &&
         (info.protection & VM_PROT_WRITE) != 0;
}

// One video output of one player, as vmem runs it.
class Output {
 public:
  explicit Output(libvlc_media_player_t* player) : vmem_(VmemOf(player)) {}

  bool Open(unsigned width, unsigned height) {
    // A VideoToolbox picture, as macOS and iOS decode one: the renderer adds the subtitle rows itself.
    char chroma[5] = "CVPN";
    unsigned pitches[kVlcMaxPlanes] = {};
    unsigned lines[kVlcMaxPlanes] = {};
    return vmem_.setup != nullptr && vmem_.setup(&vmem_.opaque, chroma, &width, &height, pitches, lines) > 0;
  }

  // vmem's lock: the planes the copy will write.
  void* Lock(void** planes) { return vmem_.lock(vmem_.opaque, planes); }
  void Unlock(void* picture, void* const* planes) { vmem_.unlock(vmem_.opaque, picture, planes); }
  void Display(void* picture) { vmem_.display(vmem_.opaque, picture); }

 private:
  Vmem vmem_;
};

class DarwinRendererSink : public ::testing::Test {
 protected:
  void SetUp() override {
    // No audio output: macOS's writes libVLC's configuration (FORK.md 32).
    const char* const options[] = {"--aout=dummy", "--quiet"};
    instance_ = libvlc_new(2, options);
    ASSERT_NE(instance_, nullptr);
    old_player_ = libvlc_media_player_new(instance_);
    new_player_ = libvlc_media_player_new(instance_);
    ASSERT_NE(old_player_, nullptr);
    ASSERT_NE(new_player_, nullptr);
    sink_ = std::make_unique<CVPixelBufferSink>(^{
    });
    output_ = std::make_unique<VlcVideoOutput>(old_player_, sink_.get());
  }

  void TearDown() override {
    output_.reset();
    sink_.reset();
    if (old_player_ != nullptr) libvlc_media_player_release(old_player_);
    if (new_player_ != nullptr) libvlc_media_player_release(new_player_);
    if (instance_ != nullptr) libvlc_release(instance_);
  }

  // -[VlcTextureRenderer attachToMediaPlayer:] (replacePlayer): the next player's output, on the same sink.
  void AttachToTheNewPlayer() {
    output_->Detach();
    output_ = std::make_unique<VlcVideoOutput>(new_player_, sink_.get());
  }

  // -[VlcTextureRenderer detach] (dispose).
  void DetachTheRenderer() {
    output_->Detach();
    output_.reset();
    sink_->Silence();
    sink_->DropHold();
    sink_->Teardown();
  }

  libvlc_instance_t* instance_ = nullptr;
  libvlc_media_player_t* old_player_ = nullptr;
  libvlc_media_player_t* new_player_ = nullptr;
  std::unique_ptr<CVPixelBufferSink> sink_;
  std::unique_ptr<VlcVideoOutput> output_;
};

// Leaving the player: dispose() stops the player asynchronously and detaches the renderer in the same turn of the
// main thread, while the player's output may be copying a picture. The memory stays until that output unlocks.
TEST_F(DarwinRendererSink, APictureLockedBeforeADetachKeepsItsMemoryUntilItsUnlock) {
  @autoreleasepool {
    Output old_output(old_player_);
    ASSERT_TRUE(old_output.Open(1920, 1080));
    void* planes[kVlcMaxPlanes] = {};
    void* picture = old_output.Lock(planes);
    ASSERT_NE(picture, nullptr);

    DetachTheRenderer();
    EXPECT_TRUE(Mapped(planes[0]) && Mapped(planes[1])) << "the output's copy would write into freed memory";

    old_output.Unlock(picture, planes);
    EXPECT_FALSE(Mapped(planes[0])) << "the late unlock left the picture alive";
  }
}

// A source change to another size: the next player's output configures the shared sink while the old player's may
// still be copying.
TEST_F(DarwinRendererSink, APictureLockedBeforeAnotherSizeKeepsItsMemoryUntilItsUnlock) {
  @autoreleasepool {
    Output old_output(old_player_);
    ASSERT_TRUE(old_output.Open(3840, 2160));
    void* planes[kVlcMaxPlanes] = {};
    void* picture = old_output.Lock(planes);
    ASSERT_NE(picture, nullptr);

    AttachToTheNewPlayer();
    Output new_output(new_player_);
    ASSERT_TRUE(new_output.Open(1920, 1080));
    EXPECT_TRUE(Mapped(planes[0]) && Mapped(planes[1])) << "the old output's copy would write into freed memory";

    old_output.Unlock(picture, planes);
    EXPECT_FALSE(Mapped(planes[0])) << "the late unlock left the picture alive";
  }
}

// A source change at the same size: the next player's output never gets the memory the old one is still copying into.
TEST_F(DarwinRendererSink, TheNextPlayersPicturesNeverReuseALockedOne) {
  @autoreleasepool {
    Output old_output(old_player_);
    ASSERT_TRUE(old_output.Open(1920, 1080));
    void* planes[kVlcMaxPlanes] = {};
    void* picture = old_output.Lock(planes);
    ASSERT_NE(picture, nullptr);

    AttachToTheNewPlayer();
    Output new_output(new_player_);
    ASSERT_TRUE(new_output.Open(1920, 1080));
    for (int i = 1; i <= 4; ++i) {
      void* fresh[kVlcMaxPlanes] = {};
      void* next = new_output.Lock(fresh);
      ASSERT_NE(next, nullptr);
      EXPECT_NE(fresh[0], planes[0]) << "the new output's picture " << i << " is the old output's, mid-copy";
      new_output.Unlock(next, fresh);
      new_output.Display(next);
    }

    old_output.Unlock(picture, planes);
  }
}

// The lock's reference never outlives the picture's use: once its output and the sink are done, nothing is left.
TEST_F(DarwinRendererSink, EveryPictureIsFreedOnceItsOutputAndTheSinkAreDone) {
  @autoreleasepool {
    Output output(old_player_);
    ASSERT_TRUE(output.Open(1920, 1080));
    std::vector<void*> seen;
    for (int i = 0; i < 8; ++i) {
      void* planes[kVlcMaxPlanes] = {};
      void* picture = output.Lock(planes);
      ASSERT_NE(picture, nullptr);
      seen.push_back(planes[0]);
      // vmem's order: unlock at the end of Prepare, display after it.
      output.Unlock(picture, planes);
      output.Display(picture);
    }
    // The embedder's last texture: Flutter holds it until its next frame.
    CVPixelBufferRef shown = sink_->CopyPending();
    ASSERT_NE(shown, nullptr);
    CVPixelBufferRelease(shown);

    DetachTheRenderer();
    for (void* plane : seen) {
      EXPECT_FALSE(Mapped(plane)) << "a picture outlived its output and the sink";
    }
  }
}

}  // namespace
}  // namespace vlc_player
