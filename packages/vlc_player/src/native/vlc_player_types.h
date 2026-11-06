#ifndef VLC_PLAYER_NATIVE_VLC_PLAYER_TYPES_H_
#define VLC_PLAYER_NATIVE_VLC_PLAYER_TYPES_H_

#include <cstdint>
#include <string>
#include <vector>

namespace vlc_player {

struct VlcTrackDescription {
  int id = -1;
  std::string name;
  std::string language;
};

struct VlcMediaTrackInfo {
  std::string type = "unknown";
  std::string codec;
  std::string language;
  int64_t bitrate = 0;
  int64_t width = 0;
  int64_t height = 0;
  int64_t channels = 0;
  int64_t sample_rate = 0;
};

struct VlcMediaInfo {
  std::string title;
  std::string artist;
  std::string album;
  int64_t duration = 0;
  std::vector<VlcMediaTrackInfo> video_tracks;
  std::vector<VlcMediaTrackInfo> audio_tracks;
  std::vector<VlcMediaTrackInfo> subtitle_tracks;
};

// A subtitle look as Dart's VlcSubtitleLook sends it; see
// src/native/vlc_subtitle_look.h for the rest of the values.
struct VlcSubtitleLookValues {
  int text_scale = 100;
  int color = 0xFFFFFF;
  int background_color = 0x000000;
  int background_opacity = 0;
  int outline_thickness = 2;
  // A share of the picture's height.
  double raise = 0;
};

struct VlcMediaStats {
  bool available = false;
  int64_t read_bytes = 0;
  double input_bitrate = 0.0;
  int64_t demux_read_bytes = 0;
  double demux_bitrate = 0.0;
  int64_t demux_corrupted = 0;
  int64_t demux_discontinuity = 0;
  int64_t decoded_video = 0;
  int64_t decoded_audio = 0;
  int64_t displayed_pictures = 0;
  int64_t lost_pictures = 0;
  int64_t played_audio_buffers = 0;
  int64_t lost_audio_buffers = 0;
  int64_t sent_packets = 0;
  int64_t sent_bytes = 0;
  double send_bitrate = 0.0;
};

struct VlcSnapshot {
  std::string state = "idle";
  int64_t position = 0;
  int64_t duration = 0;
  double position_fraction = -1.0;
  int volume = 100;
  double playback_speed = 1.0;
  int64_t audio_delay = 0;
  int64_t subtitle_delay = 0;
  // libVLC track ids; -1 when there is none / subtitles are off. Dart
  // normalises -1 to null.
  int audio_track = -1;
  int subtitle_track = -1;
  // Bumped whenever the audio + spu track SET changes - not merely its size.
  // See VlcPlayerCore::Snapshot(), which diffs an order-sensitive fingerprint
  // so a wholesale list swap of the same length still moves this. Monotonic
  // per core.
  int64_t track_revision = 0;
  bool is_ready = false;
  bool is_seekable = false;
  bool is_live = false;
  int64_t video_width = 0;
  int64_t video_height = 0;
  double buffering_progress = -1.0;
  // Whether a keepPicture reopen's hold is on: VlcPictureHold's decision,
  // the same on every backend (FORK.md 30).
  bool picture_held = false;
  // libVLC's refused seeks, as its log said them, and the last refused time.
  int64_t seek_refusals = 0;
  int64_t seek_refused_at = -1;
  std::string error_code;
  std::string error_description;
  // The order snapshots were made in: VlcPlayerCore::Snapshot() numbers each
  // as it begins, from 1. Not part of ==, which compares what a snapshot
  // says; see VlcSnapshotOrder (FORK.md 37).
  uint64_t sequence = 0;
};

inline bool operator==(const VlcSnapshot& lhs, const VlcSnapshot& rhs) {
  return lhs.state == rhs.state && lhs.position == rhs.position &&
         lhs.duration == rhs.duration &&
         lhs.position_fraction == rhs.position_fraction &&
         lhs.volume == rhs.volume &&
         lhs.playback_speed == rhs.playback_speed &&
         lhs.audio_delay == rhs.audio_delay &&
         lhs.subtitle_delay == rhs.subtitle_delay &&
         lhs.audio_track == rhs.audio_track &&
         lhs.subtitle_track == rhs.subtitle_track &&
         lhs.track_revision == rhs.track_revision &&
         lhs.is_ready == rhs.is_ready && lhs.is_seekable == rhs.is_seekable &&
         lhs.is_live == rhs.is_live && lhs.video_width == rhs.video_width &&
         lhs.video_height == rhs.video_height &&
         lhs.buffering_progress == rhs.buffering_progress &&
         lhs.picture_held == rhs.picture_held &&
         lhs.seek_refusals == rhs.seek_refusals &&
         lhs.seek_refused_at == rhs.seek_refused_at &&
         lhs.error_code == rhs.error_code &&
         lhs.error_description == rhs.error_description;
}

inline bool operator!=(const VlcSnapshot& lhs, const VlcSnapshot& rhs) {
  return !(lhs == rhs);
}

}  // namespace vlc_player

#endif  // VLC_PLAYER_NATIVE_VLC_PLAYER_TYPES_H_
