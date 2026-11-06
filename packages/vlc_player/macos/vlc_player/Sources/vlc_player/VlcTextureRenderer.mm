#import "VlcTextureRenderer.h"

#if TARGET_OS_OSX
#import <VLCKit/VLCKit.h>
#else
#import <MobileVLCKit/MobileVLCKit.h>
#endif

#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>

#include "vlc_frame_sink.h"
#include "vlc_subtitle_look.h"
#include "vlc_video_output.h"

/// VLCKit and MobileVLCKit both publish the underlying libvlc handle through
/// a category in their private VLCLibVLCBridging.h. Re-declaring the one
/// property we need keeps that header out of our search path, at the cost of
/// depending on a private API - acceptable only because both podspecs pin the
/// framework to an exact version.
@interface VLCMediaPlayer (VlcPlayerLibVLCBridging)
@property(readonly) void *libVLCMediaPlayer;
@end

namespace {

/// NV12, not RGBA.
///
/// VideoToolbox already decodes to bi-planar NV12, so asking libVLC for it
/// deletes the swscale conversion to RGBA, moves 1.5 bytes per pixel instead
/// of 4, and lands in the one YUV layout Flutter's Metal external texture
/// samples directly on Darwin. Subtitles are a separate matter - see
/// kSubtitleRows.
///
/// FlutterTexture.h on both iOS and macOS names the formats copyPixelBuffer
/// may return: 32BGRA and the two NV12 variants. Swapping the three constants
/// below to kCVPixelFormatType_32BGRA / "BGRA" / 1 plane is the whole fallback
/// if NV12 ever misbehaves.
constexpr OSType kPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
constexpr char kChroma[] = "NV12";
constexpr uint32_t kPlaneCount = 2;

/// Rows added below a VideoToolbox picture, so libVLC can draw subtitles on
/// it.
///
/// vmem cannot draw subpictures itself, so libVLC 3 blends them into the
/// picture - and when our buffer is no bigger than the decoder's picture it
/// blends them EARLY, into the decoder's own format (VLC 3.0
/// src/video_output/video_output.c, ThreadDisplayRenderPicture). A
/// VideoToolbox picture is an opaque CVPixelBuffer that libVLC's blender
/// cannot write, so every subtitle track inside the video vanished whenever
/// VideoToolbox decoded it: always, on Darwin. A software-decoded picture
/// blends fine, which is why this only applies to VideoToolbox's.
///
/// A buffer larger than the picture moves the blend LATE, onto the converted
/// picture in our NV12, which it can write. The picture is scaled to the
/// buffer on the way - on macOS by VideoToolbox's own pixel transfer (cvpx.c,
/// CVPX to CVPX), on iOS by swscale - so the buffer holds the whole picture,
/// two rows taller, and Flutter squeezes those two rows back out by showing
/// the whole buffer at the picture's own size (see CodedSize).
///
/// Two rows: the least that is larger and keeps NV12's even height.
constexpr uint32_t kSubtitleRows = 2;

/// Bounds the pool so a stalled consumer cannot grow it without limit. One
/// buffer is being written, one is published, and the engine may hold one or
/// two more while it uploads.
constexpr int kPoolAllocationThreshold = 5;

/// Fills CVPixelBuffers out of a pool and publishes the newest complete one.
///
/// libVLC writes directly into pool memory, so there is no copy of our own
/// anywhere on this path.
class CVPixelBufferSink final : public vlc_player::VlcFrameSink {
 public:
  explicit CVPixelBufferSink(void (^on_frame_available)(void))
      : on_frame_available_(on_frame_available) {}

  ~CVPixelBufferSink() override {
    DropHold();
    Teardown();
  }

  uint32_t Configure(vlc_player::VlcFrameFormat* format) override {
    Teardown();
    if (format->width == 0 || format->height == 0) {
      return 0;
    }
    // libVLC names the decoder's chroma here; every CoreVideo one starts
    // `CVP` (VLC_CODEC_CVPX_NV12 is 'CVPN', and so on).
    const bool video_toolbox = std::strncmp(format->chroma, "CVP", 3) == 0;
    if (video_toolbox) {
      format->height += kSubtitleRows;
    }
    // libVLC's video thread has no autorelease pool of its own.
    @autoreleasepool {
      return ConfigurePool(format, video_toolbox);
    }
  }

  /// libVLC's cleanup callback: drop the frames, keep the pool.
  ///
  /// Deliberately not a teardown. Changing media closes one video output and
  /// opens another, and the close is not ordered against the open - the old
  /// vout's cleanup lands *after* the new one's Configure often enough to
  /// matter. Releasing the pool here therefore pulled the new vout's buffers
  /// out from under it, and libVLC went on writing a frame into memory that
  /// no longer existed. The pool is owned by Configure and by teardown, which
  /// are the two points that know which pool they mean.
  void Cleanup() override {
    CVPixelBufferRef stale_pending = nullptr;
    CVPixelBufferRef stale_in_flight = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      std::swap(stale_pending, pending_);
      std::swap(stale_in_flight, in_flight_);
      in_flight_committed_ = false;
      in_flight_released_ = false;
    }
    if (stale_pending != nullptr) {
      CVPixelBufferRelease(stale_pending);
    }
    if (stale_in_flight != nullptr) {
      CVPixelBufferRelease(stale_in_flight);
    }
  }

  /// Releases everything, including the pool. Only safe once libVLC can no
  /// longer call in.
  void Teardown() {
    Cleanup();
    CVPixelBufferPoolRef stale_pool = nullptr;
    CFTypeRef stale_aux = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      std::swap(stale_pool, pool_);
      std::swap(stale_aux, aux_attributes_);
    }
    if (stale_pool != nullptr) {
      CVPixelBufferPoolRelease(stale_pool);
    }
    if (stale_aux != nullptr) {
      CFRelease(stale_aux);
    }
  }

  /// Hands libVLC a pool buffer to decode into, or nullptr to drop the frame.
  ///
  /// Dropping is safe here only because VlcVideoOutput points libVLC at its
  /// scratch bin whenever this returns nullptr - libVLC 3's lock callback has
  /// no way to refuse a picture on its own.
  void* Acquire(void** planes) override {
    CVPixelBufferRef abandoned = nullptr;
    CVPixelBufferRef buffer = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      // A picture libVLC decoded but never displayed is still sitting here.
      std::swap(abandoned, in_flight_);
      in_flight_committed_ = false;
      in_flight_released_ = false;

      if (pool_ != nullptr &&
          CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
              kCFAllocatorDefault, pool_,
              static_cast<CFDictionaryRef>(aux_attributes_),
              &buffer) != kCVReturnSuccess) {
        buffer = nullptr;
      }
    }
    if (abandoned != nullptr) {
      CVPixelBufferRelease(abandoned);
    }
    if (buffer == nullptr) {
      return nullptr;
    }

    if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
      CVPixelBufferRelease(buffer);
      return nullptr;
    }
    for (uint32_t plane = 0; plane < kPlaneCount; ++plane) {
      // A stride that does not match the buffer would let the decoder write
      // past the end of a row, so bin the frame rather than guess.
      if (CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) !=
          pitches_[plane]) {
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        CVPixelBufferRelease(buffer);
        return nullptr;
      }
      planes[plane] = CVPixelBufferGetBaseAddressOfPlane(buffer, plane);
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      // Two references from here on: the pool's, which is the lock's and goes
      // at its unlock (Release, or ReleaseOrphan once the output is detached),
      // and the slot's. The next player's format and the renderer's detach drop
      // only the slot's, so a copy into a locked picture never meets freed or
      // recycled memory (FORK.md 31).
      in_flight_ = CVPixelBufferRetain(buffer);
    }
    return buffer;
  }

  /// The unlock of a picture locked before its output was detached
  /// (VlcFrameSink::orphan_release): the lock's reference goes, and the memory
  /// with it if nothing else holds it. Touches nothing of the sink's.
  static void ReleaseOrphan(void* picture, void* const* /*planes*/) {
    auto buffer = static_cast<CVPixelBufferRef>(picture);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    CVPixelBufferRelease(buffer);
  }

  OrphanRelease orphan_release() const override { return &ReleaseOrphan; }

  void Commit(void* picture) override {
    if (picture == nullptr) {
      return;
    }
    bool publish = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (in_flight_ != picture) {
        return;
      }
      in_flight_committed_ = true;
      publish = in_flight_released_;
    }
    if (publish) {
      Publish();
    }
  }

  void Release(void* picture, void* const* planes) override {
    if (picture == nullptr) {
      return;
    }
    auto buffer = static_cast<CVPixelBufferRef>(picture);
    CVPixelBufferUnlockBaseAddress(buffer, 0);

    bool publish = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (in_flight_ == picture) {
        in_flight_released_ = true;
        publish = in_flight_committed_;
      }
    }
    // The lock's reference, whether or not the slot still holds the picture.
    CVPixelBufferRelease(buffer);
    if (publish) {
      Publish();
    }
  }

  /// The newest published frame, retained for the caller, or nullptr before
  /// the first one arrives.
  CVPixelBufferRef CopyPending() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (holding_.load()) {
      return CVPixelBufferRetain(held_);
    }
    // Deliberately kept rather than handed over: Flutter re-reads the texture
    // on resize and on any repaint that did not follow a new frame, and a
    // nullptr there paints a black hole where the video was.
    return pending_ == nullptr ? nullptr : CVPixelBufferRetain(pending_);
  }

  /// Keeps the picture on screen, whatever libVLC decodes next, until
  /// ReleaseHold. False, holding nothing, before the first picture. A second
  /// Hold while holding keeps the first picture.
  bool Hold() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (holding_.load()) {
      // Held again for the next media, and until that one is let go: a
      // release still pending from a media that failed, ended or was stopped
      // before it played would end the hold at the new media's first picture,
      // frame 0.
      release_pending_ = false;
      return true;
    }
    if (pending_ == nullptr) {
      return false;
    }
    held_ = CVPixelBufferRetain(pending_);
    release_pending_ = false;
    holding_ = true;
    return true;
  }

  /// Lets the hold go at the next picture libVLC finishes. See
  /// vlc_picture_hold.h for why not at once.
  void ReleaseHold() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (holding_.load()) {
      release_pending_ = true;
    }
  }

  bool held() const { return holding_.load(); }

  /// Drops a hold at once: the renderer is going away.
  void DropHold() {
    CVPixelBufferRef stale = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      std::swap(stale, held_);
      holding_ = false;
      release_pending_ = false;
    }
    if (stale != nullptr) {
      CVPixelBufferRelease(stale);
    }
  }

  void Silence() {
    std::lock_guard<std::mutex> lock(mutex_);
    on_frame_available_ = nil;
  }

 private:
  uint32_t ConfigurePool(vlc_player::VlcFrameFormat* format, bool scaled) {
    NSDictionary* attributes = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kPixelFormat),
      (id)kCVPixelBufferWidthKey : @(format->width),
      (id)kCVPixelBufferHeightKey : @(format->height),
      // Flutter wraps the buffer in a Metal texture through
      // CVMetalTextureCache, which only works on IOSurface-backed memory.
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };

    std::lock_guard<std::mutex> lock(mutex_);
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr,
                                (__bridge CFDictionaryRef)attributes,
                                &pool_) != kCVReturnSuccess) {
      pool_ = nullptr;
      return 0;
    }

    // libVLC is told the strides once and reuses them for every picture, so
    // they have to come from a real buffer rather than from width alone -
    // CoreVideo pads rows to its own alignment.
    CVPixelBufferRef probe = nullptr;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool_,
                                           &probe) != kCVReturnSuccess) {
      CVPixelBufferPoolRelease(pool_);
      pool_ = nullptr;
      return 0;
    }
    for (uint32_t plane = 0; plane < kPlaneCount; ++plane) {
      pitches_[plane] =
          static_cast<uint32_t>(CVPixelBufferGetBytesPerRowOfPlane(probe, plane));
      lines_[plane] =
          static_cast<uint32_t>(CVPixelBufferGetHeightOfPlane(probe, plane));
      format->pitches[plane] = pitches_[plane];
      format->lines[plane] = lines_[plane];
    }
    CVPixelBufferRelease(probe);

    // Built once rather than per frame: Acquire runs on libVLC's video
    // thread, which has no autorelease pool to drain a fresh dictionary into.
    aux_attributes_ = CFBridgingRetain(@{
      (id)kCVPixelBufferPoolAllocationThresholdKey :
          @(kPoolAllocationThreshold),
    });

    std::memcpy(format->chroma, kChroma, sizeof(kChroma));
    coded_width_ = format->width;
    coded_height_ = format->height;
    scaled_ = scaled;
    return kPlaneCount;
  }

 public:
  /// The buffer dimensions libVLC asked for - the CODED size, which for a
  /// 1080p stream is 1920x1088 because the decoder pads height to a multiple
  /// of 16. Only the visible rows get written; the padding stays zero, and
  /// zero in NV12 is green. Flutter has to know this size to clip it off.
  ///
  /// Zero - no size to clip to - for a VideoToolbox picture: libVLC scales
  /// that one to fill every row of the buffer (see kSubtitleRows), so the
  /// whole buffer is picture, and Flutter shows all of it at the picture's
  /// own size.
  CGSize CodedSize() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (scaled_) {
      return CGSizeZero;
    }
    return CGSizeMake(coded_width_, coded_height_);
  }

 private:

  /// Moves the in-flight picture to `pending_` and wakes the embedder.
  /// Moves the in-flight picture to `pending_` and wakes the embedder - or,
  /// while a hold is on, drops it: the new media's picture at 0 among others.
  /// The first picture finished after ReleaseHold ends the hold.
  void Publish() {
    CVPixelBufferRef replaced = nullptr;
    CVPixelBufferRef released_hold = nullptr;
    void (^notify)(void) = nil;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (holding_.load() && !release_pending_) {
        replaced = in_flight_;
      } else {
        if (holding_.load()) {
          holding_ = false;
          release_pending_ = false;
          std::swap(released_hold, held_);
        }
        replaced = pending_;
        pending_ = in_flight_;
        notify = on_frame_available_;
      }
      in_flight_ = nullptr;
      in_flight_committed_ = false;
      in_flight_released_ = false;
    }
    if (replaced != nullptr) {
      CVPixelBufferRelease(replaced);
    }
    if (released_hold != nullptr) {
      CVPixelBufferRelease(released_hold);
    }
    if (notify != nil) {
      @autoreleasepool {
        notify();
      }
    }
  }

  std::mutex mutex_;
  void (^on_frame_available_)(void);
  CVPixelBufferPoolRef pool_ = nullptr;
  CFTypeRef aux_attributes_ = nullptr;
  uint32_t pitches_[vlc_player::kVlcMaxPlanes] = {};
  uint32_t lines_[vlc_player::kVlcMaxPlanes] = {};
  uint32_t coded_width_ = 0;
  uint32_t coded_height_ = 0;
  bool scaled_ = false;

  /// The picture libVLC is filling. Published once it is both displayed
  /// (Commit) and finished with (Release) - libVLC 3's vmem output calls
  /// those in either order.
  CVPixelBufferRef in_flight_ = nullptr;
  bool in_flight_committed_ = false;
  bool in_flight_released_ = false;

  CVPixelBufferRef pending_ = nullptr;
  /// The picture a hold keeps on screen, retained apart from the pool's
  /// rotation: the old video output's Cleanup and the new one's Configure both
  /// run during a hold, and neither may take it away.
  CVPixelBufferRef held_ = nullptr;
  std::atomic<bool> holding_{false};
  bool release_pending_ = false;
};

}  // namespace

// libvlccore's functions the subtitle look sets variables through, which
// VLCKit's libVLC exports but none of its headers declares. Declared loosely -
// only their addresses are taken here, and vlc_subtitle_look.c calls them
// through their own types - and named, so a build that strips unused code
// keeps them where the framework is linked in statically.
extern "C" {
void var_Type(void);
void var_Create(void);
void var_SetChecked(void);
void vlc_list_children(void);
void vlc_list_release(void);
}

static vlc_subtitle_look_function ResolveInVLCKit(const char *name) {
  struct Entry {
    const char *name;
    vlc_subtitle_look_function function;
  };
  static const Entry kFunctions[] = {
      {"libvlc_get_version",
       reinterpret_cast<vlc_subtitle_look_function>(&libvlc_get_version)},
      {"var_Type", &var_Type},
      {"var_Create", &var_Create},
      {"var_SetChecked", &var_SetChecked},
      {"vlc_list_children", &vlc_list_children},
      {"vlc_list_release", &vlc_list_release},
  };
  for (const Entry &entry : kFunctions) {
    if (std::strcmp(entry.name, name) == 0) {
      return entry.function;
    }
  }
  return nullptr;
}

@implementation VlcTextureRenderer {
  std::unique_ptr<CVPixelBufferSink> _sink;
  std::unique_ptr<vlc_player::VlcVideoOutput> _output;
}

- (instancetype)initWithMediaPlayer:(VLCMediaPlayer *)mediaPlayer {
  self = [super init];
  if (self == nil) {
    return nil;
  }

  __weak VlcTextureRenderer *weakSelf = self;
  _sink = std::make_unique<CVPixelBufferSink>(^{
    VlcTextureRenderer *strongSelf = weakSelf;
    if (strongSelf != nil && strongSelf.onFrameAvailable != nil) {
      strongSelf.onFrameAvailable();
    }
  });

  auto *player =
      static_cast<libvlc_media_player_t *>(mediaPlayer.libVLCMediaPlayer);
  _output =
      std::make_unique<vlc_player::VlcVideoOutput>(player, _sink.get());
  return self;
}

+ (BOOL)applySubtitleLookToMediaPlayer:(VLCMediaPlayer *)mediaPlayer
                             textScale:(NSInteger)textScale
                                 color:(NSInteger)color
                       backgroundColor:(NSInteger)backgroundColor
                     backgroundOpacity:(NSInteger)backgroundOpacity
                      outlineThickness:(NSInteger)outlineThickness
                                margin:(NSInteger)margin {
  vlc_subtitle_look look;
  look.text_scale = static_cast<int>(textScale);
  look.color = static_cast<int>(color);
  look.background_color = static_cast<int>(backgroundColor);
  look.background_opacity = static_cast<int>(backgroundOpacity);
  look.outline_thickness = static_cast<int>(outlineThickness);
  look.margin = static_cast<int>(margin);
  return vlc_subtitle_look_apply(mediaPlayer.libVLCMediaPlayer, &look,
                                 ResolveInVLCKit)
             ? YES
             : NO;
}

- (void)attachToMediaPlayer:(VLCMediaPlayer *)mediaPlayer {
  if (_sink == nullptr || _output == nullptr) {
    return;
  }
  // Detach first: the old player's video output may still close or draw one
  // last frame, and it must find nothing to call into.
  _output->Detach();
  auto *player =
      static_cast<libvlc_media_player_t *>(mediaPlayer.libVLCMediaPlayer);
  _output =
      std::make_unique<vlc_player::VlcVideoOutput>(player, _sink.get());
}

- (NSString *)chroma {
  return @(kChroma);
}

- (CGSize)codedSize {
  return _sink == nullptr ? CGSizeZero : _sink->CodedSize();
}

- (CVPixelBufferRef _Nullable)copyPixelBuffer {
  return _sink == nullptr ? nullptr : _sink->CopyPending();
}

- (BOOL)holdPicture {
  return _sink != nullptr && _sink->Hold() ? YES : NO;
}

- (void)releasePicture {
  if (_sink != nullptr) {
    _sink->ReleaseHold();
  }
}

- (BOOL)pictureHeld {
  return _sink != nullptr && _sink->held() ? YES : NO;
}

- (void)detach {
  if (_output != nullptr) {
    _output->Detach();
    _output.reset();
  }
  if (_sink != nullptr) {
    _sink->Silence();
    _sink->DropHold();
    _sink->Teardown();
  }
  self.onFrameAvailable = nil;
}

- (void)dealloc {
  [self detach];
  _sink.reset();
}

@end
