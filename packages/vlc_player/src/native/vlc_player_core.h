#ifndef VLC_PLAYER_NATIVE_VLC_PLAYER_CORE_H_
#define VLC_PLAYER_NATIVE_VLC_PLAYER_CORE_H_

#include <atomic>
#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <vlcpp/vlc.hpp>

#include "vlc_picture_hold.h"
#include "vlc_pixel_buffer_sink.h"
#include "vlc_player_types.h"
#include "vlc_video_output.h"

namespace vlc_player {

class VlcPlayerCore {
 public:
  using FrameAvailableCallback = std::function<void()>;
  // Something libVLC reported changed what a snapshot would say. Called on
  // libVLC's threads: it must be cheap and must never call into libVLC.
  using ChangedCallback = std::function<void()>;

  explicit VlcPlayerCore(std::vector<std::string> options,
                         FrameAvailableCallback on_frame_available,
                         ChangedCallback on_changed = nullptr);
  ~VlcPlayerCore();

  VlcPlayerCore(const VlcPlayerCore&) = delete;
  VlcPlayerCore& operator=(const VlcPlayerCore&) = delete;

  bool is_valid() const;
  const std::string& error() const;

  std::string SetSource(const std::string& uri,
                        const std::vector<std::string>& headers,
                        const std::vector<std::string>& media_options,
                        int64_t start_position,
                        bool auto_play,
                        bool keep_picture = false);
  std::string Play();
  std::string Pause();
  std::string Stop();
  std::string SeekTo(int64_t milliseconds);
  // A place in a live HLS or DASH window, as libVLC's position fraction.
  std::string SeekToFraction(double fraction);
  std::string SetVolume(int volume);
  std::string SetPlaybackSpeed(double speed);
  std::string SetAudioDelay(int64_t microseconds);
  std::string SetSubtitleDelay(int64_t microseconds);
  // Restyles the subtitle lines libVLC draws, from their next line - see
  // src/native/vlc_subtitle_look.h - with the raise worked out against the
  // frame sink's picture as it is now: the host sends the look again when
  // that picture changes size. *applied says whether this libVLC could.
  std::string SetSubtitleLook(const VlcSubtitleLookValues& look,
                              bool* applied);
  std::vector<uint8_t> TakeSnapshot(uint32_t width,
                                    uint32_t height,
                                    std::string* error);

  std::vector<VlcTrackDescription> GetAudioTracks();
  std::string SetAudioTrack(int id);
  std::vector<VlcTrackDescription> GetSubtitleTracks();
  std::string SetSubtitleTrack(int id);
  std::string DisableSubtitle();
  std::string AddSubtitle(const std::string& uri);
  VlcMediaInfo GetMediaInfo();
  VlcMediaStats GetMediaStats();

  VlcSnapshot Snapshot();
  bool CopyPixels(const uint8_t** out_buffer, uint32_t* width, uint32_t* height);
  void Dispose();

  // A cheap, order-sensitive fingerprint of the audio + subtitle track SET.
  //
  // Snapshot() diffs this instead of a track count: the two lists can be
  // replaced wholesale without changing how many entries they hold (an
  // adaptive rendition change, an MPEG-TS PMT update), and a count-derived
  // revision would sit still through it, leaving every consumer caching
  // GetAudioTracks() / GetSubtitleTracks() drawing the previous names with
  // nothing ticked.
  //
  // Public because that property - a same-size swap moves the number - is
  // what the native suite pins.
  static int64_t TrackSetFingerprint(
      const std::vector<VlcTrackDescription>& audio,
      const std::vector<VlcTrackDescription>& subtitles);

  // Keeps one libVLC instance for the process's life, made by the first call;
  // later calls do nothing. libVLC 3 unloads its plugin bank with its last
  // instance, so a core released and another made reloaded every plugin (spec
  // 1.7). rebuild_plugin_cache makes that instance rewrite libVLC's plugin
  // cache (--reset-plugins-cache); Windows asks for it when the cache is
  // missing or stale.
  static void KeepPluginBankLoaded(bool rebuild_plugin_cache);

  // libVLC's pixels ("sub-margin") for a raise of [raise], a share of a
  // picture [height] high: the lines are laid out on the frame sink's buffer,
  // which is the picture's own size. Held to half the picture.
  static int SubtitleMargin(double raise, unsigned height);

#ifdef VLC_PLAYER_TESTING
  VlcPixelBufferSink* FrameSinkForTesting();
  void ResizeVideoBufferForTesting(uint32_t width,
                                   uint32_t height,
                                   uint32_t pitch);
  void SimulateFrameForTesting(uint8_t value);
  const uint8_t* FrameBufferDataForTesting() const;
  size_t FrameBufferSizeForTesting() const;
  uint64_t RenderGenerationForTesting() const;
  uint64_t TextureGenerationForTesting() const;
  int SubtitleMarginForTesting(double raise) const;
  libvlc_media_player_t* PlayerForTesting() const;
  uint64_t GenerationForTesting() const;
  void OnBufferingForTesting(uint64_t generation, float percent);
  void OnOpeningForTesting(uint64_t generation);
  void OnTimeChangedForTesting(uint64_t generation);
  void OnMediaGoneForTesting(uint64_t generation);
  void LogForTesting(int level, const char* format, ...);
  static bool PluginBankKeptForTesting();
#endif  // VLC_PLAYER_TESTING

 private:
  std::string ActiveError() const;

  // The height of the picture libVLC lays subtitle lines out on: the frame
  // sink's, which is the size the host keys a look's resend on. The media's
  // declared size only before the sink has one - libVLC sizes the sink first
  // and updates the declared size later (VLC 3.0 decoder.c vout_update_format,
  // es_out.c EsOutSend), so after an adaptive stream's rendition change or an
  // MPEG-TS's first frame the two disagree for a moment.
  unsigned SubtitleLayoutHeight() const;

  static std::string StateName(libvlc_state_t state);
  static bool IsReadyState(const std::string& state);
  static bool IsLiveState(const std::string& state);
  static std::string FourCCString(uint32_t value);
  static std::string TrackTypeName(VLC::MediaTrack::Type type);
  static VlcMediaTrackInfo MediaTrackInfo(const VLC::MediaTrack& track);
  static std::vector<VlcTrackDescription> TrackDescriptions(
      const std::vector<VLC::TrackDescription>& tracks);

  // The player for the source now. Swapped for a fresh one by every source
  // after the first, by Stop and by Dispose; the update thread and libVLC's
  // video thread read it through CurrentPlayer().
  std::shared_ptr<VLC::MediaPlayer> CurrentPlayer() const;
  // Puts a fresh player in place and hands the old one to ReleaseLater.
  // Platform thread only.
  void ReplacePlayer();
  void Subscribe(VLC::MediaPlayer& player, uint64_t generation);
  void Unsubscribe(VLC::MediaPlayer& player);
  static void ReleaseLater(std::shared_ptr<VLC::MediaPlayer> player);
  // libVLC's events, on its threads. Each drops a replaced player's.
  void OnOpening(uint64_t generation);
  void OnBuffering(uint64_t generation, float percent);
  void OnTimeChanged(uint64_t generation);
  void OnMediaGone(uint64_t generation);
  void OnChanged(uint64_t generation);
  static void OnLog(void* data, int level, const libvlc_log_t* context,
                    const char* format, va_list arguments);
  void OnLogMessage(int level, const char* format, va_list arguments);

  FrameAvailableCallback on_frame_available_;
  ChangedCallback on_changed_;
  std::unique_ptr<VLC::Instance> instance_;
  mutable std::mutex player_mutex_;
  std::shared_ptr<VLC::MediaPlayer> player_;
  // The last source's media, so Stop can leave it loaded on the fresh player
  // as libVLC's own stop does. Platform thread only.
  std::unique_ptr<VLC::Media> media_;
  std::vector<VLC::EventManager::RegisteredEvent> events_;
  std::atomic<uint64_t> generation_{0};
  // Numbers each snapshot as it begins (VlcSnapshot::sequence).
  std::atomic<uint64_t> snapshot_sequence_{0};
  VlcPictureHold picture_hold_;
  float buffering_percent_ = -1.0f;  // guarded by state_mutex_
  double rate_ = 1.0;                // guarded by state_mutex_
  int64_t audio_delay_ = 0;          // guarded by state_mutex_
  int64_t subtitle_delay_ = 0;       // guarded by state_mutex_
  bool has_subtitle_look_ = false;   // platform thread only
  VlcSubtitleLookValues subtitle_look_;
  std::atomic<int64_t> seek_refusals_{0};
  std::atomic<int64_t> seek_refused_at_{-1};
  std::string init_error_;
  std::atomic<bool> disposed_{false};

  // Declared before video_output_ so the output is torn down first: Detach
  // has to stop libVLC calling in before the sink it calls into is gone.
  std::unique_ptr<VlcPixelBufferSink> frame_sink_;
  std::unique_ptr<VlcVideoOutput> video_output_;

  mutable std::mutex state_mutex_;
  int volume_ = 100;
  // TrackSetFingerprint() of the audio + spu lists seen by the last
  // Snapshot(); the revision moves when a new snapshot disagrees with it.
  // -1 is unreachable for a real fingerprint, so it means "nothing seen yet".
  int64_t last_track_fingerprint_ = -1;
  int64_t track_revision_ = 0;
  std::string state_override_;
  std::string error_code_;
  std::string error_description_;
};

}  // namespace vlc_player

#endif  // VLC_PLAYER_NATIVE_VLC_PLAYER_CORE_H_
