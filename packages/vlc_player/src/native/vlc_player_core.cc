#include "vlc_player_core.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <mutex>
#include <sstream>
#include <thread>
#include <utility>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#include "vlc_subtitle_look.h"

namespace vlc_player {
namespace {

// Finds what a subtitle look needs in the libVLC this player runs on:
// libvlc_get_version in libvlc, the rest in libvlccore, which libvlc loads.
vlc_subtitle_look_function ResolveInLibVlc(const char* name) {
#ifdef _WIN32
  for (const wchar_t* library : {L"libvlccore.dll", L"libvlc.dll"}) {
    HMODULE module = GetModuleHandleW(library);
    if (module == nullptr) {
      continue;
    }
    if (FARPROC found = GetProcAddress(module, name)) {
      return reinterpret_cast<vlc_subtitle_look_function>(found);
    }
  }
  return nullptr;
#else
  // Already loaded, by the libvlc this plugin links: never loaded here.
  static void* const libraries[] = {
      dlopen("libvlccore.so.9", RTLD_NOW | RTLD_NOLOAD),
      dlopen("libvlc.so.5", RTLD_NOW | RTLD_NOLOAD),
  };
  for (void* library : libraries) {
    if (library == nullptr) {
      continue;
    }
    if (void* found = dlsym(library, name)) {
      return reinterpret_cast<vlc_subtitle_look_function>(found);
    }
  }
  return reinterpret_cast<vlc_subtitle_look_function>(
      dlsym(RTLD_DEFAULT, name));
#endif
}

int64_t NonNegative(libvlc_time_t value) {
  return std::max<int64_t>(0, value);
}

// FNV-1a, 64 bit. Not a security hash - it only has to make two different
// track lists land on two different numbers often enough that a snapshot
// diff notices, and it has to cost nothing at the 500 ms poll rate.
constexpr uint64_t kFnvOffsetBasis = 14695981039346656037ULL;
constexpr uint64_t kFnvPrime = 1099511628211ULL;

uint64_t FoldByte(uint64_t hash, uint8_t byte) {
  return (hash ^ byte) * kFnvPrime;
}

uint64_t FoldBytes(uint64_t hash, const void* data, size_t size) {
  const auto* bytes = static_cast<const uint8_t*>(data);
  for (size_t index = 0; index < size; ++index) {
    hash = FoldByte(hash, bytes[index]);
  }
  return hash;
}

uint64_t FoldTrackList(uint64_t hash,
                       const std::vector<VlcTrackDescription>& tracks) {
  // A list separator, so an id that moves from the audio list to the spu list
  // cannot leave the fingerprint where it was.
  hash = FoldByte(hash, 0x1f);
  for (const auto& track : tracks) {
    const int32_t id = static_cast<int32_t>(track.id);
    hash = FoldBytes(hash, &id, sizeof(id));
    hash = FoldBytes(hash, track.name.data(), track.name.size());
    // A record separator, so ("a", "bc") and ("ab", "c") differ.
    hash = FoldByte(hash, 0x1e);
  }
  return hash;
}

std::atomic<uint64_t> g_snapshot_counter{0};

// See VlcPlayerCore::KeepPluginBankLoaded. Never released.
libvlc_instance_t* g_kept_instance = nullptr;
std::once_flag g_kept_instance_once;

// libVLC 3.0.24's warning for a seek its demuxer refused, after es_out has
// already flushed (input.c, Control: msg_Warn "INPUT_CONTROL_SET_TIME
// %"PRId64" failed or not possible", in microseconds). Matched on the format
// string so no other message is ever formatted.
constexpr char kRefusedSeekFormat[] = "INPUT_CONTROL_SET_TIME";
constexpr char kRefusedSeekTail[] = "failed or not possible";

std::string EnvironmentValue(const char* name) {
#ifdef _WIN32
  char* value = nullptr;
  size_t size = 0;
  if (_dupenv_s(&value, &size, name) != 0 || value == nullptr) {
    return "";
  }
  std::string result(value);
  std::free(value);
  return result;
#else
  const char* value = std::getenv(name);
  return value == nullptr ? "" : value;
#endif
}

std::string TemporarySnapshotPath() {
#ifdef _WIN32
  const char* env_names[] = {"TEMP", "TMP"};
  const char separator = '\\';
  std::string directory = ".";
#else
  const char* env_names[] = {"TMPDIR", "TEMP", "TMP"};
  const char separator = '/';
  std::string directory = "/tmp";
#endif
  for (const char* name : env_names) {
    const std::string value = EnvironmentValue(name);
    if (!value.empty()) {
      directory = value;
      break;
    }
  }
  if (!directory.empty() && directory.back() != '/' &&
      directory.back() != '\\') {
    directory.push_back(separator);
  }

  const auto timestamp =
      std::chrono::duration_cast<std::chrono::microseconds>(
          std::chrono::system_clock::now().time_since_epoch())
          .count();
  const uint64_t counter = g_snapshot_counter.fetch_add(1);
  std::ostringstream path;
  path << directory << "vlc_player_snapshot_" << timestamp << "_" << counter
       << ".png";
  return path.str();
}

bool ReadFileIfReady(const std::string& path, std::vector<uint8_t>* data) {
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  if (!file) {
    return false;
  }
  const std::ifstream::pos_type size = file.tellg();
  if (size <= 0) {
    return false;
  }
  const auto byte_count = static_cast<std::streamsize>(size);
  data->resize(static_cast<size_t>(byte_count));
  file.seekg(0, std::ios::beg);
  file.read(reinterpret_cast<char*>(data->data()), byte_count);
  return file.good();
}

}  // namespace

// static
void VlcPlayerCore::KeepPluginBankLoaded(bool rebuild_plugin_cache) {
  std::call_once(g_kept_instance_once, [rebuild_plugin_cache] {
    std::vector<const char*> argv;
    if (rebuild_plugin_cache) {
      argv.push_back("--reset-plugins-cache");
    }
    g_kept_instance =
        libvlc_new(static_cast<int>(argv.size()), argv.data());
  });
}

VlcPlayerCore::VlcPlayerCore(std::vector<std::string> options,
                             FrameAvailableCallback on_frame_available,
                             ChangedCallback on_changed)
    : on_frame_available_(std::move(on_frame_available)),
      on_changed_(std::move(on_changed)) {
  std::vector<const char*> argv;
  argv.reserve(options.size());
  for (const auto& option : options) {
    argv.push_back(option.c_str());
  }

  // Ahead of this core's own instance, so the plugin bank is loaded once
  // per process. On Windows the plugin has already made it, with its own
  // answer about the plugin cache, and this does nothing.
  KeepPluginBankLoaded(false);
  try {
    instance_ =
        std::make_unique<VLC::Instance>(static_cast<int>(argv.size()),
                                        argv.data());
    player_ = std::make_shared<VLC::MediaPlayer>(*instance_);
  } catch (const std::exception& error) {
    init_error_ = error.what();
    return;
  }

  frame_sink_ = std::make_unique<VlcPixelBufferSink>(
      [this] {
        if (!disposed_.load() && on_frame_available_) {
          on_frame_available_();
        }
      },
      // The visible picture size, for the sink's format negotiation. Reads
      // the media's video track as the demuxer declared it -
      // libvlc_video_get_size touches the track info, not the video output -
      // which is the same number the Darwin renderer publishes alongside its
      // coded size.
      //
      // Called on libVLC's video output thread, from inside the format
      // callback, so it reads the player through CurrentPlayer(): the
      // platform thread may be swapping it. Only the current player's video
      // output is attached to the sink, so the answer is that player's.
      [this](uint32_t* width, uint32_t* height) {
        unsigned visible_width = 0;
        unsigned visible_height = 0;
        const auto player = CurrentPlayer();
        if (player == nullptr ||
            !player->size(0, &visible_width, &visible_height)) {
          return false;
        }
        *width = visible_width;
        *height = visible_height;
        return true;
      });
  video_output_ =
      std::make_unique<VlcVideoOutput>(player_->get(), frame_sink_.get());
  Subscribe(*player_, 0);
  libvlc_log_set(instance_->get(), &VlcPlayerCore::OnLog, this);
}

VlcPlayerCore::~VlcPlayerCore() {
  Dispose();
}

bool VlcPlayerCore::is_valid() const {
  return init_error_.empty() && player_ != nullptr;
}

const std::string& VlcPlayerCore::error() const {
  return init_error_;
}

std::shared_ptr<VLC::MediaPlayer> VlcPlayerCore::CurrentPlayer() const {
  std::lock_guard<std::mutex> lock(player_mutex_);
  return player_;
}

void VlcPlayerCore::ReplacePlayer() {
  auto next = std::make_shared<VLC::MediaPlayer>(*instance_);
  {
    // What libVLC keeps per player rather than per media.
    std::lock_guard<std::mutex> lock(state_mutex_);
    next->setVolume(volume_);
    next->setRate(static_cast<float>(rate_));
    next->setAudioDelay(audio_delay_);
    next->setSpuDelay(subtitle_delay_);
  }
  // The old player stops drawing into the sink and talking to this core
  // before anything else happens to it. Its events are dropped from here on
  // by generation; Unsubscribe then waits out a callback already past that
  // check, which takes state_mutex_, so it is never called with that lock
  // held.
  video_output_->Detach();
  const uint64_t generation = ++generation_;
  std::shared_ptr<VLC::MediaPlayer> old;
  {
    std::lock_guard<std::mutex> lock(player_mutex_);
    old = player_;
  }
  if (old != nullptr) {
    Unsubscribe(*old);
  }
  {
    // After the old player's last callback: a prebuffer it reported is not
    // the new one's.
    std::lock_guard<std::mutex> lock(state_mutex_);
    buffering_percent_ = -1.0f;
  }
  {
    std::lock_guard<std::mutex> lock(player_mutex_);
    player_ = next;
  }
  video_output_ =
      std::make_unique<VlcVideoOutput>(next->get(), frame_sink_.get());
  Subscribe(*next, generation);
  if (has_subtitle_look_) {
    bool applied = false;
    SetSubtitleLook(subtitle_look_, &applied);
  }
  ReleaseLater(std::move(old));
}

// static
void VlcPlayerCore::ReleaseLater(std::shared_ptr<VLC::MediaPlayer> player) {
  if (player == nullptr) {
    return;
  }
  // libVLC 3 stops a stream synchronously: stop() joins the input thread,
  // which an adaptive stream's stalled segment download keeps alive for as
  // long as the stall lasts (spec 3). A thread of its own waits instead of
  // the platform's.
  std::thread([player = std::move(player)]() mutable {
    // A reader that copied the player before the swap finishes with it first:
    // a getter that ran into this stop would wait as long as the stop.
    for (int i = 0; i < 400 && player.use_count() > 1; ++i) {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    player->stop();
    player.reset();
  }).detach();
}

void VlcPlayerCore::Subscribe(VLC::MediaPlayer& player, uint64_t generation) {
  auto& events = player.eventManager();
  events_.push_back(
      events.onOpening([this, generation] { OnOpening(generation); }));
  events_.push_back(events.onBuffering(
      [this, generation](float percent) { OnBuffering(generation, percent); }));
  events_.push_back(
      events.onPlaying([this, generation] { OnChanged(generation); }));
  events_.push_back(
      events.onPaused([this, generation] { OnChanged(generation); }));
  events_.push_back(
      events.onStopped([this, generation] { OnMediaGone(generation); }));
  events_.push_back(
      events.onEndReached([this, generation] { OnMediaGone(generation); }));
  events_.push_back(events.onEncounteredError(
      [this, generation] { OnMediaGone(generation); }));
  events_.push_back(events.onTimeChanged(
      [this, generation](libvlc_time_t) { OnTimeChanged(generation); }));
  events_.push_back(events.onLengthChanged(
      [this, generation](libvlc_time_t) { OnChanged(generation); }));
  events_.push_back(events.onSeekableChanged(
      [this, generation](bool) { OnChanged(generation); }));
  events_.push_back(
      events.onVout([this, generation](int) { OnChanged(generation); }));
  events_.push_back(events.onESAdded(
      [this, generation](VLC::MediaTrack::Type, int) {
        OnChanged(generation);
      }));
  events_.push_back(events.onESDeleted(
      [this, generation](VLC::MediaTrack::Type, int) {
        OnChanged(generation);
      }));
  events_.push_back(events.onESSelected(
      [this, generation](VLC::MediaTrack::Type, int) {
        OnChanged(generation);
      }));
}

void VlcPlayerCore::Unsubscribe(VLC::MediaPlayer& player) {
  auto& events = player.eventManager();
  for (auto event : events_) {
    events.unregister(event);
  }
  events_.clear();
}

void VlcPlayerCore::OnChanged(uint64_t generation) {
  if (generation != generation_.load()) {
    return;
  }
  if (on_changed_) {
    on_changed_();
  }
}

void VlcPlayerCore::OnOpening(uint64_t generation) {
  if (generation != generation_.load()) {
    return;
  }
  picture_hold_.OnOpening();
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    buffering_percent_ = -1.0f;
  }
  OnChanged(generation);
}

void VlcPlayerCore::OnBuffering(uint64_t generation, float percent) {
  if (generation != generation_.load()) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    buffering_percent_ = percent;
  }
  OnChanged(generation);
}

void VlcPlayerCore::OnTimeChanged(uint64_t generation) {
  if (generation != generation_.load()) {
    return;
  }
  if (picture_hold_.OnTimeChanged() == VlcPictureHold::Change::kRelease) {
    frame_sink_->ReleaseHold();
  }
  OnChanged(generation);
}

void VlcPlayerCore::OnMediaGone(uint64_t generation) {
  if (generation != generation_.load()) {
    return;
  }
  if (picture_hold_.OnMediaGone() == VlcPictureHold::Change::kRelease) {
    frame_sink_->ReleaseHold();
  }
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    buffering_percent_ = -1.0f;
  }
  OnChanged(generation);
}

// static
void VlcPlayerCore::OnLog(void* data, int level, const libvlc_log_t*,
                          const char* format, va_list arguments) {
  static_cast<VlcPlayerCore*>(data)->OnLogMessage(level, format, arguments);
}

void VlcPlayerCore::OnLogMessage(int level, const char* format,
                                 va_list arguments) {
  // Every message libVLC logs comes here, debug included, on any of its
  // threads: only the refused seek's warning is ever formatted.
  if (level != LIBVLC_WARNING || format == nullptr ||
      std::strstr(format, kRefusedSeekFormat) == nullptr ||
      std::strstr(format, kRefusedSeekTail) == nullptr) {
    return;
  }
  char text[160];
  std::vsnprintf(text, sizeof(text), format, arguments);
  const char* number = std::strpbrk(text, "0123456789");
  const long long microseconds =
      number == nullptr ? -1 : std::strtoll(number, nullptr, 10);
  seek_refused_at_ = microseconds < 0 ? -1 : microseconds / 1000;
  ++seek_refusals_;
  if (on_changed_) {
    on_changed_();
  }
}

std::string VlcPlayerCore::SetSource(const std::string& uri,
                                     const std::vector<std::string>& headers,
                                     const std::vector<std::string>&
                                         media_options,
                                     int64_t start_position,
                                     bool auto_play,
                                     bool keep_picture) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (uri.empty()) {
    return "A non-empty uri is required.";
  }

  std::unique_ptr<VLC::Media> media;
  try {
    media = std::make_unique<VLC::Media>(*instance_, uri,
                                         VLC::Media::FromLocation);
    for (const auto& header : headers) {
      media->addOption(header);
    }
    for (const auto& option : media_options) {
      media->addOption(option);
    }
    if (start_position > 0) {
      std::ostringstream option;
      option << ":start-time=" << (static_cast<double>(start_position) / 1000);
      media->addOption(option.str());
    }
  } catch (const std::exception&) {
    return "Unable to create VLC media.";
  }

  // A player that has had a source is not handed another: set_media would
  // wait here for the old stream's input thread (spec 3).
  if (media_ != nullptr) {
    ReplacePlayer();
  }
  // Only a reopen that keeps its picture, or one while a hold is on, asks
  // the sink: Hold copies the picture on screen.
  const bool has_picture =
      (keep_picture || picture_hold_.held()) && frame_sink_->Hold();
  if (picture_hold_.Arm(keep_picture, has_picture) ==
      VlcPictureHold::Change::kRelease) {
    frame_sink_->ReleaseHold();
  }
  player_->setMedia(*media);
  media_ = std::move(media);

  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    state_override_ = "opening";
    error_code_.clear();
    error_description_.clear();
  }

  return auto_play ? Play() : "";
}

std::string VlcPlayerCore::Play() {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (!player_->play()) {
    return "VLC failed to start playback.";
  }
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    state_override_.clear();
  }
  return "";
}

std::string VlcPlayerCore::Pause() {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  player_->pause();
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    state_override_.clear();
  }
  return "";
}

std::string VlcPlayerCore::Stop() {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  // Not stop(), which waits for the stream on this thread. The source stays
  // loaded on the fresh player, so play() after Stop starts it again, as
  // libVLC's own stop leaves it.
  ReplacePlayer();
  if (picture_hold_.Release() == VlcPictureHold::Change::kRelease) {
    frame_sink_->ReleaseHold();
  }
  if (media_ != nullptr) {
    player_->setMedia(*media_);
  }
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    state_override_ = "stopped";
  }
  return "";
}

std::string VlcPlayerCore::SeekTo(int64_t milliseconds) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  player_->setTime(std::max<int64_t>(0, milliseconds));
  return "";
}

std::string VlcPlayerCore::SeekToFraction(double fraction) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  player_->setPosition(static_cast<float>(std::clamp(fraction, 0.0, 1.0)));
  return "";
}

std::string VlcPlayerCore::SetVolume(int volume) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  const int normalized_volume = std::clamp(volume, 0, 200);
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    volume_ = normalized_volume;
  }
  player_->setVolume(normalized_volume);
  return "";
}

std::string VlcPlayerCore::SetPlaybackSpeed(double speed) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (!std::isfinite(speed) || speed <= 0) {
    return "A finite positive playback speed is required.";
  }
  player_->setRate(static_cast<float>(speed));
  {
    // Kept for the next player: a source after this one gets a fresh one.
    std::lock_guard<std::mutex> lock(state_mutex_);
    rate_ = speed;
  }
  return "";
}

std::string VlcPlayerCore::SetAudioDelay(int64_t microseconds) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (!player_->setAudioDelay(microseconds)) {
    return "VLC failed to set audio delay.";
  }
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    audio_delay_ = microseconds;
  }
  return "";
}

std::string VlcPlayerCore::SetSubtitleDelay(int64_t microseconds) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (player_->setSpuDelay(microseconds) != 0) {
    return "VLC failed to set subtitle delay.";
  }
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    subtitle_delay_ = microseconds;
  }
  return "";
}

std::string VlcPlayerCore::SetSubtitleLook(const VlcSubtitleLookValues& look,
                                           bool* applied) {
  *applied = false;
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  // Kept for the next player: a source after this one gets a fresh one.
  subtitle_look_ = look;
  has_subtitle_look_ = true;
  vlc_subtitle_look values;
  values.text_scale = look.text_scale;
  values.color = look.color;
  values.background_color = look.background_color;
  values.background_opacity = look.background_opacity;
  values.outline_thickness = look.outline_thickness;
  values.margin = SubtitleMargin(look.raise, SubtitleLayoutHeight());
  *applied = vlc_subtitle_look_apply(player_->get(), &values, ResolveInLibVlc);
  return "";
}

unsigned VlcPlayerCore::SubtitleLayoutHeight() const {
  uint32_t frame_width = 0;
  uint32_t frame_height = 0;
  if (frame_sink_ != nullptr) {
    frame_sink_->FrameSize(&frame_width, &frame_height);
  }
  if (frame_height > 0) {
    return frame_height;
  }
  unsigned width = 0;
  unsigned height = 0;
  if (player_ == nullptr || !player_->size(0, &width, &height)) {
    return 0;
  }
  return height;
}

int VlcPlayerCore::SubtitleMargin(double raise, unsigned height) {
  if (!(raise > 0) || height == 0) {
    return 0;
  }
  return static_cast<int>(std::lround(std::min(raise, 0.5) * height));
}

std::vector<uint8_t> VlcPlayerCore::TakeSnapshot(uint32_t width,
                                                 uint32_t height,
                                                 std::string* error) {
  if (error != nullptr) {
    error->clear();
  }
  const auto active_error = ActiveError();
  if (!active_error.empty()) {
    if (error != nullptr) {
      *error = active_error;
    }
    return {};
  }

  auto media = player_->media();
  if (media == nullptr) {
    if (error != nullptr) {
      *error = "No media is loaded.";
    }
    return {};
  }

  const std::string path = TemporarySnapshotPath();
  if (!player_->takeSnapshot(0, path, width, height)) {
    std::remove(path.c_str());
    if (error != nullptr) {
      *error = "VLC failed to take a snapshot.";
    }
    return {};
  }

  for (int attempt = 0; attempt < 40; ++attempt) {
    std::vector<uint8_t> data;
    if (ReadFileIfReady(path, &data)) {
      std::remove(path.c_str());
      return data;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }

  std::remove(path.c_str());
  if (error != nullptr) {
    *error = "VLC did not produce snapshot image data.";
  }
  return {};
}

std::vector<VlcTrackDescription> VlcPlayerCore::GetAudioTracks() {
  // Snapshot() calls this off the platform thread, which may be swapping the
  // player: a copy, never player_ itself.
  const auto player = disposed_.load() ? nullptr : CurrentPlayer();
  if (player == nullptr) {
    return {};
  }
  return TrackDescriptions(player->audioTrackDescription());
}

std::string VlcPlayerCore::SetAudioTrack(int id) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (!player_->setAudioTrack(id)) {
    return "Audio track " + std::to_string(id) + " was not found.";
  }
  return "";
}

std::vector<VlcTrackDescription> VlcPlayerCore::GetSubtitleTracks() {
  // See GetAudioTracks.
  const auto player = disposed_.load() ? nullptr : CurrentPlayer();
  if (player == nullptr) {
    return {};
  }
  return TrackDescriptions(player->spuDescription());
}

std::string VlcPlayerCore::SetSubtitleTrack(int id) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (player_->setSpu(id) != 0) {
    return "Subtitle track " + std::to_string(id) + " was not found.";
  }
  return "";
}

std::string VlcPlayerCore::DisableSubtitle() {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  player_->setSpu(-1);
  return "";
}

std::string VlcPlayerCore::AddSubtitle(const std::string& uri) {
  const auto error = ActiveError();
  if (!error.empty()) {
    return error;
  }
  if (uri.empty()) {
    return "A non-empty subtitle uri is required.";
  }
  if (!player_->addSlave(VLC::MediaSlave::Type::Subtitle, uri, true)) {
    return "Failed to add subtitle: " + uri;
  }
  return "";
}

VlcMediaInfo VlcPlayerCore::GetMediaInfo() {
  VlcMediaInfo info;
  if (!is_valid()) {
    return info;
  }

  info.duration = NonNegative(player_->length());
  auto media = player_->media();
  if (media == nullptr) {
    return info;
  }

  info.title = media->meta(libvlc_meta_Title);
  info.artist = media->meta(libvlc_meta_Artist);
  info.album = media->meta(libvlc_meta_Album);

  for (const auto& track : media->tracks()) {
    auto track_info = MediaTrackInfo(track);
    switch (track.type()) {
      case VLC::MediaTrack::Type::Audio:
        info.audio_tracks.push_back(std::move(track_info));
        break;
      case VLC::MediaTrack::Type::Video:
        info.video_tracks.push_back(std::move(track_info));
        break;
      case VLC::MediaTrack::Type::Subtitle:
        info.subtitle_tracks.push_back(std::move(track_info));
        break;
      default:
        break;
    }
  }
  return info;
}

VlcMediaStats VlcPlayerCore::GetMediaStats() {
  VlcMediaStats result;
  if (!is_valid()) {
    return result;
  }

  auto media = player_->media();
  if (media == nullptr) {
    return result;
  }

  libvlc_media_stats_t stats{};
  if (!media->stats(&stats)) {
    return result;
  }

  result.available = true;
  result.read_bytes = stats.i_read_bytes;
  result.input_bitrate = stats.f_input_bitrate;
  result.demux_read_bytes = stats.i_demux_read_bytes;
  result.demux_bitrate = stats.f_demux_bitrate;
  result.demux_corrupted = stats.i_demux_corrupted;
  result.demux_discontinuity = stats.i_demux_discontinuity;
  result.decoded_video = stats.i_decoded_video;
  result.decoded_audio = stats.i_decoded_audio;
  result.displayed_pictures = stats.i_displayed_pictures;
  result.lost_pictures = stats.i_lost_pictures;
  result.played_audio_buffers = stats.i_played_abuffers;
  result.lost_audio_buffers = stats.i_lost_abuffers;
  result.sent_packets = stats.i_sent_packets;
  result.sent_bytes = stats.i_sent_bytes;
  result.send_bitrate = stats.f_send_bitrate;
  return result;
}

VlcSnapshot VlcPlayerCore::Snapshot() {
  VlcSnapshot snapshot;
  // Numbered before anything is read: a snapshot begun before a command
  // describes the player before it, however late it is finished (FORK.md
  // 37).
  snapshot.sequence = ++snapshot_sequence_;
  // Off the platform thread, which may be swapping the player: a copy, kept
  // alive by this reference until the snapshot is done (see ReleaseLater).
  const auto player =
      init_error_.empty() && !disposed_.load() ? CurrentPlayer() : nullptr;
  if (player == nullptr) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    snapshot.volume = volume_;
    if (!error_description_.empty()) {
      snapshot.error_code =
          error_code_.empty() ? "create_failed" : error_code_;
    }
    snapshot.error_description = error_description_;
    return snapshot;
  }
  // The hold decision, not the sink's pixels: the sink lets a hold go at its
  // next finished picture, and bridges a plain source's swap the same way.
  // The time report that ends a hold asks for this snapshot (OnTimeChanged),
  // so the end and the new size reach Dart together (FORK.md 30).
  snapshot.picture_held = picture_hold_.held();
  snapshot.seek_refusals = seek_refusals_.load();
  snapshot.seek_refused_at = seek_refused_at_.load();

  auto media = player->media();
  if (media == nullptr) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    snapshot.state = state_override_.empty() ? "idle" : state_override_;
    snapshot.volume = volume_;
    snapshot.error_code = error_code_;
    snapshot.error_description = error_description_;
    return snapshot;
  }

  const libvlc_state_t state = player->state();
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (state == libvlc_Error) {
      error_code_ = "playback_error";
      error_description_ = "VLC encountered an error while playing the media.";
    }
    const bool prebuffering =
        buffering_percent_ >= 0.0f && buffering_percent_ < 100.0f;
    std::string name =
        state_override_.empty() ? StateName(state) : state_override_;
    // libVLC 3 never reports libvlc_Buffering itself: the input says
    // "playing" while it fills its buffer, and only the Buffering event says
    // how full it is.
    if (name == "playing" && prebuffering) {
      name = "buffering";
    }
    snapshot.state = name;
    snapshot.buffering_progress =
        prebuffering ? static_cast<double>(buffering_percent_) / 100.0 : -1.0;
    snapshot.volume = volume_;
    snapshot.error_code = error_code_;
    snapshot.error_description = error_description_;
  }
  snapshot.position = NonNegative(player->time());
  snapshot.duration = NonNegative(player->length());
  snapshot.position_fraction = static_cast<double>(player->position());
  snapshot.playback_speed = static_cast<double>(player->rate());
  snapshot.audio_delay = player->audioDelay();
  snapshot.subtitle_delay = player->spuDelay();
  snapshot.audio_track = player->audioTrack();
  snapshot.subtitle_track = player->spu();
  {
    // The track SET is diffed rather than counted. A count cannot see a
    // same-size swap - an adaptive rendition change or an MPEG-TS PMT update
    // replaces the audio/spu ES without changing how many there are - and a
    // consumer that never refetches is left drawing the old names with
    // nothing ticked, because the active id it is matching no longer exists.
    // The ES events now ask for a snapshot when the set changes.
    const int64_t fingerprint =
        TrackSetFingerprint(GetAudioTracks(), GetSubtitleTracks());
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (fingerprint != last_track_fingerprint_) {
      last_track_fingerprint_ = fingerprint;
      ++track_revision_;
    }
    snapshot.track_revision = track_revision_;
  }
  snapshot.is_ready = IsReadyState(snapshot.state);
  snapshot.is_seekable = player->isSeekable();
  snapshot.is_live = IsLiveState(snapshot.state) && snapshot.duration == 0 &&
                     !snapshot.is_seekable;
  // The texture's own size, which is the only size Flutter can lay it out at.
  // It is the visible picture whenever the sink managed to negotiate that -
  // see VlcPixelBufferSink::Configure - and the coded buffer when it did not,
  // which is what it always was before. No separate coded size is published
  // because on this path there is nothing for a consumer to clip: the buffer
  // and the picture are the same rectangle.
  uint32_t frame_width = 0;
  uint32_t frame_height = 0;
  frame_sink_->FrameSize(&frame_width, &frame_height);
  snapshot.video_width = frame_width;
  snapshot.video_height = frame_height;
  return snapshot;
}

bool VlcPlayerCore::CopyPixels(const uint8_t** out_buffer,
                               uint32_t* width,
                               uint32_t* height) {
  if (frame_sink_ == nullptr) {
    return false;
  }
  return frame_sink_->CopyPixels(out_buffer, width, height);
}

void VlcPlayerCore::Dispose() {
  if (disposed_.exchange(true)) {
    return;
  }
  if (video_output_ != nullptr) {
    video_output_->Detach();
  }
  std::shared_ptr<VLC::MediaPlayer> player;
  {
    std::lock_guard<std::mutex> lock(player_mutex_);
    player = std::move(player_);
  }
  if (player != nullptr) {
    Unsubscribe(*player);
  }
  if (instance_ != nullptr) {
    // Waits out a log call already running; libVLC drops later ones. The
    // released player keeps the instance alive, and its stop still logs.
    libvlc_log_unset(instance_->get());
  }
  picture_hold_.Release();
  video_output_.reset();
  on_frame_available_ = nullptr;
  on_changed_ = nullptr;
  // The player keeps its own reference to the instance until it is released.
  ReleaseLater(std::move(player));
  instance_.reset();
}

#ifdef VLC_PLAYER_TESTING
VlcPixelBufferSink* VlcPlayerCore::FrameSinkForTesting() {
  return frame_sink_.get();
}

void VlcPlayerCore::ResizeVideoBufferForTesting(uint32_t width,
                                                uint32_t height,
                                                uint32_t pitch) {
  frame_sink_->ResizeForTesting(width, height, pitch);
}

int VlcPlayerCore::SubtitleMarginForTesting(double raise) const {
  return SubtitleMargin(raise, SubtitleLayoutHeight());
}

void VlcPlayerCore::SimulateFrameForTesting(uint8_t value) {
  frame_sink_->SimulateFrameForTesting(value);
}

const uint8_t* VlcPlayerCore::FrameBufferDataForTesting() const {
  return frame_sink_->FrameBufferDataForTesting();
}

size_t VlcPlayerCore::FrameBufferSizeForTesting() const {
  return frame_sink_->FrameBufferSizeForTesting();
}

uint64_t VlcPlayerCore::RenderGenerationForTesting() const {
  return frame_sink_->RenderGenerationForTesting();
}

uint64_t VlcPlayerCore::TextureGenerationForTesting() const {
  return frame_sink_->TextureGenerationForTesting();
}

libvlc_media_player_t* VlcPlayerCore::PlayerForTesting() const {
  const auto player = CurrentPlayer();
  return player == nullptr ? nullptr : player->get();
}

uint64_t VlcPlayerCore::GenerationForTesting() const {
  return generation_.load();
}

void VlcPlayerCore::OnBufferingForTesting(uint64_t generation, float percent) {
  OnBuffering(generation, percent);
}

void VlcPlayerCore::OnOpeningForTesting(uint64_t generation) {
  OnOpening(generation);
}

void VlcPlayerCore::OnTimeChangedForTesting(uint64_t generation) {
  OnTimeChanged(generation);
}

void VlcPlayerCore::OnMediaGoneForTesting(uint64_t generation) {
  OnMediaGone(generation);
}

void VlcPlayerCore::LogForTesting(int level, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  OnLogMessage(level, format, arguments);
  va_end(arguments);
}

// static
bool VlcPlayerCore::PluginBankKeptForTesting() {
  return g_kept_instance != nullptr;
}
#endif  // VLC_PLAYER_TESTING

std::string VlcPlayerCore::ActiveError() const {
  if (disposed_.load()) {
    return "The vlc_player has been disposed.";
  }
  if (!init_error_.empty()) {
    return init_error_;
  }
  if (player_ == nullptr) {
    return "The VLC media player is not available.";
  }
  return "";
}

std::string VlcPlayerCore::StateName(libvlc_state_t state) {
  switch (state) {
    case libvlc_Opening:
      return "opening";
    case libvlc_Buffering:
      return "buffering";
    case libvlc_Playing:
      return "playing";
    case libvlc_Paused:
      return "paused";
    case libvlc_Stopped:
      return "stopped";
    case libvlc_Ended:
      return "ended";
    case libvlc_Error:
      return "error";
    default:
      return "idle";
  }
}

bool VlcPlayerCore::IsReadyState(const std::string& state) {
  return state == "playing" || state == "paused" || state == "stopped" ||
         state == "ended";
}

bool VlcPlayerCore::IsLiveState(const std::string& state) {
  // Not "buffering": a VOD's prebuffer reports it now, and a length still
  // unknown then would make every start look live for a moment (FORK.md 3's
  // flap). Android and Darwin count only these two.
  return state == "playing" || state == "paused";
}

std::string VlcPlayerCore::FourCCString(uint32_t value) {
  char codec[5] = {
      static_cast<char>(value & 0xff),
      static_cast<char>((value >> 8) & 0xff),
      static_cast<char>((value >> 16) & 0xff),
      static_cast<char>((value >> 24) & 0xff),
      '\0',
  };
  for (int i = 0; i < 4; ++i) {
    if (codec[i] < 32 || codec[i] > 126) {
      return "";
    }
  }
  return codec;
}

std::string VlcPlayerCore::TrackTypeName(VLC::MediaTrack::Type type) {
  switch (type) {
    case VLC::MediaTrack::Type::Audio:
      return "audio";
    case VLC::MediaTrack::Type::Video:
      return "video";
    case VLC::MediaTrack::Type::Subtitle:
      return "subtitle";
    default:
      return "unknown";
  }
}

VlcMediaTrackInfo VlcPlayerCore::MediaTrackInfo(const VLC::MediaTrack& track) {
  VlcMediaTrackInfo info;
  info.type = TrackTypeName(track.type());
  info.codec = FourCCString(track.codec());
  info.language = track.language();
  info.bitrate = track.bitrate();
  if (track.type() == VLC::MediaTrack::Type::Video) {
    info.width = track.width();
    info.height = track.height();
  }
  if (track.type() == VLC::MediaTrack::Type::Audio) {
    info.channels = track.channels();
    info.sample_rate = track.rate();
  }
  return info;
}

int64_t VlcPlayerCore::TrackSetFingerprint(
    const std::vector<VlcTrackDescription>& audio,
    const std::vector<VlcTrackDescription>& subtitles) {
  uint64_t hash = kFnvOffsetBasis;
  hash = FoldTrackList(hash, audio);
  hash = FoldTrackList(hash, subtitles);
  // Masked to stay non-negative so -1 remains an unreachable "nothing seen
  // yet" sentinel for last_track_fingerprint_.
  return static_cast<int64_t>(hash & 0x7fffffffffffffffULL);
}

std::vector<VlcTrackDescription> VlcPlayerCore::TrackDescriptions(
    const std::vector<VLC::TrackDescription>& tracks) {
  std::vector<VlcTrackDescription> result;
  result.reserve(tracks.size());
  for (const auto& track : tracks) {
    result.push_back(VlcTrackDescription{
        track.id(),
        track.name(),
        "",
    });
  }
  return result;
}

}  // namespace vlc_player
