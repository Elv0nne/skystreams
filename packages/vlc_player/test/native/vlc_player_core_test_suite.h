#ifndef VLC_PLAYER_TEST_NATIVE_VLC_PLAYER_CORE_TEST_SUITE_H_
#define VLC_PLAYER_TEST_NATIVE_VLC_PLAYER_CORE_TEST_SUITE_H_

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#include <gtest/gtest.h>

#include "vlc_pixel_buffer_sink_test_suite.h"
#include "vlc_picture_hold_test_suite.h"
#include "vlc_update_pump_test_suite.h"
#include "vlc_player_core.h"

namespace vlc_player {
namespace test {

std::vector<std::string> VlcPlayerCoreTestOptions();

namespace {

std::unique_ptr<VlcPlayerCore> MakeCore() {
  return std::make_unique<VlcPlayerCore>(VlcPlayerCoreTestOptions(), [] {});
}

#ifdef _WIN32
using SocketHandle = SOCKET;
constexpr SocketHandle kNoSocket = INVALID_SOCKET;
constexpr int kSendFlags = 0;
inline void CloseSocket(SocketHandle s) { closesocket(s); }
// Ends a connection another thread may be blocked reading: close alone does
// not wake that read on every platform.
inline void EndConnection(SocketHandle s) { shutdown(s, SD_BOTH); }
inline bool WaitToAccept(SocketHandle s, int milliseconds) {
  WSAPOLLFD listener{s, POLLRDNORM, 0};
  return WSAPoll(&listener, 1, milliseconds) > 0;
}
#else
using SocketHandle = int;
constexpr SocketHandle kNoSocket = -1;
#ifdef MSG_NOSIGNAL
constexpr int kSendFlags = MSG_NOSIGNAL;
#else
constexpr int kSendFlags = 0;
#endif
inline void CloseSocket(SocketHandle s) { close(s); }
inline void EndConnection(SocketHandle s) { shutdown(s, SHUT_RDWR); }
inline bool WaitToAccept(SocketHandle s, int milliseconds) {
  pollfd listener{s, POLLIN, 0};
  return poll(&listener, 1, milliseconds) > 0;
}
#endif

// Serves an HLS stream whose segments stall: the playlist in full, then each
// segment's headers and nothing more, until the server ends the connection
// three seconds later.
//
// libVLC 3's adaptive module downloads on threads of its own, and the
// input's stop does not interrupt their reads: closing an input whose segment
// had stalled joined its thread for as long as the stall lasted (over eight
// minutes, against this server with no end to the stall, on VLCKit's
// libVLC, 2026-10-14). A plain file whose read stalls does not show it: that
// read is interrupted at once.
class StallingServer {
 public:
  ~StallingServer() {
    running_ = false;
    if (thread_.joinable()) {
      thread_.join();
    }
    if (listener_ != kNoSocket) {
      CloseSocket(listener_);
    }
    for (const Client& client : clients_) {
      EndConnection(client.socket);
      CloseSocket(client.socket);
    }
  }

  bool Start() {
#ifdef _WIN32
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
      return false;
    }
#endif
    listener_ = socket(AF_INET, SOCK_STREAM, 0);
    if (listener_ == kNoSocket) {
      return false;
    }
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(listener_, reinterpret_cast<sockaddr*>(&address),
             sizeof(address)) != 0 ||
        listen(listener_, 8) != 0) {
      return false;
    }
    socklen_t length = sizeof(address);
    getsockname(listener_, reinterpret_cast<sockaddr*>(&address), &length);
    port_ = ntohs(address.sin_port);
    thread_ = std::thread([this] { Serve(); });
    return true;
  }

  std::string Url() const {
    return "http://127.0.0.1:" + std::to_string(port_) + "/stall.m3u8";
  }

  // Waits for the next segment request after the last one this saw: a
  // download is then stalled.
  bool WaitForRequest(std::chrono::seconds timeout) {
    const int seen = requests_.load();
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (requests_.load() == seen) {
      if (std::chrono::steady_clock::now() > deadline) {
        return false;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return true;
  }

 private:
  struct Client {
    SocketHandle socket;
    // When the server ends the stall; time_point::max() for none.
    std::chrono::steady_clock::time_point ends;
  };

  // Touches the sockets only here and, after the join, in the destructor.
  void Serve() {
    while (running_) {
      EndStalls();
      if (!WaitToAccept(listener_, 100)) {
        continue;
      }
      SocketHandle client = accept(listener_, nullptr, nullptr);
      if (client == kNoSocket) {
        return;
      }
      char request[2048] = {};
      recv(client, request, static_cast<int>(sizeof(request) - 1), 0);
      if (std::strstr(request, ".m3u8") != nullptr) {
        const std::string body =
            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n"
            "#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:10.0,\nseg0.ts\n"
            "#EXTINF:10.0,\nseg1.ts\n#EXT-X-ENDLIST\n";
        const std::string reply =
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: application/vnd.apple.mpegurl\r\n"
            "Content-Length: " +
            std::to_string(body.size()) + "\r\n\r\n" + body;
        send(client, reply.data(), static_cast<int>(reply.size()), kSendFlags);
        clients_.push_back({client, std::chrono::steady_clock::time_point::max()});
        continue;
      }
      const char headers[] =
          "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n"
          "Content-Length: 100000000\r\n\r\n";
      send(client, headers, static_cast<int>(sizeof(headers) - 1), kSendFlags);
      clients_.push_back(
          {client, std::chrono::steady_clock::now() + std::chrono::seconds(3)});
      ++requests_;
    }
  }

  void EndStalls() {
    const auto now = std::chrono::steady_clock::now();
    for (Client& client : clients_) {
      if (client.ends <= now) {
        EndConnection(client.socket);
        client.ends = std::chrono::steady_clock::time_point::max();
      }
    }
  }

  SocketHandle listener_ = kNoSocket;
  uint16_t port_ = 0;
  std::thread thread_;
  std::atomic<bool> running_{true};
  std::atomic<int> requests_{0};
  std::vector<Client> clients_;
};

}  // namespace

TEST(VlcPlayerCore, SnapshotWithoutMediaIsIdle) {
  auto core = MakeCore();

  ASSERT_TRUE(core->is_valid()) << core->error();
  const VlcSnapshot snapshot = core->Snapshot();

  EXPECT_EQ(snapshot.state, "idle");
  EXPECT_EQ(snapshot.position, 0);
  EXPECT_EQ(snapshot.duration, 0);
  EXPECT_EQ(snapshot.volume, 100);
  EXPECT_EQ(snapshot.audio_delay, 0);
  EXPECT_EQ(snapshot.subtitle_delay, 0);
}

TEST(VlcPlayerCore, SnapshotEqualityComparesPayloadFields) {
  VlcSnapshot first;
  VlcSnapshot second;

  EXPECT_EQ(first, second);

  second.position = 1;
  EXPECT_NE(first, second);

  second = first;
  second.error_description = "failed";
  EXPECT_NE(first, second);

  // A track switch must defeat the dedupe or the forced post-mutation
  // snapshot would be swallowed as a repeat.
  second = first;
  second.audio_track = 2;
  EXPECT_NE(first, second);

  second = first;
  second.subtitle_track = 0;
  EXPECT_NE(first, second);

  second = first;
  second.track_revision = 1;
  EXPECT_NE(first, second);
}

TEST(VlcPlayerCore, SnapshotsAreNumberedInTheOrderTheyAreMade) {
  // The number is how a plugin tells a snapshot made before the last it sent
  // (VlcSnapshotOrder, FORK.md 37). It is not what a snapshot says.
  auto core = MakeCore();

  ASSERT_TRUE(core->is_valid()) << core->error();
  const VlcSnapshot first = core->Snapshot();
  const VlcSnapshot second = core->Snapshot();

  EXPECT_GT(first.sequence, 0u);
  EXPECT_GT(second.sequence, first.sequence);
  EXPECT_EQ(first, second);
}

TEST(VlcPlayerCore, SnapshotWithoutMediaReportsNoActiveTracks) {
  auto core = MakeCore();

  ASSERT_TRUE(core->is_valid()) << core->error();
  const VlcSnapshot snapshot = core->Snapshot();

  EXPECT_EQ(snapshot.audio_track, -1);
  EXPECT_EQ(snapshot.subtitle_track, -1);
  EXPECT_EQ(snapshot.track_revision, 0);
}

// The revision Snapshot() publishes is derived from this fingerprint, and the
// whole point of a fingerprint over the count it replaced is that a swap which
// keeps the list the same size still moves it. A live/adaptive stream does
// exactly that on a rendition change or an MPEG-TS PMT update; a consumer
// caching the track lists off the revision would otherwise keep drawing the
// old names with nothing ticked, because the active id it matches is gone.
TEST(VlcPlayerCore, TrackSetFingerprintMovesOnASameSizeSwap) {
  const std::vector<VlcTrackDescription> audio_before = {
      {1, "English", ""},
      {2, "Hindi", ""},
  };
  const std::vector<VlcTrackDescription> spu = {{-1, "Disable", ""}};

  const int64_t before =
      VlcPlayerCore::TrackSetFingerprint(audio_before, spu);

  // Same two tracks, same count: nothing at all may move.
  EXPECT_EQ(VlcPlayerCore::TrackSetFingerprint(audio_before, spu), before);

  // Two tracks still, but they are different elementary streams.
  const std::vector<VlcTrackDescription> swapped_ids = {
      {3, "English", ""},
      {4, "Hindi", ""},
  };
  EXPECT_NE(VlcPlayerCore::TrackSetFingerprint(swapped_ids, spu), before);

  // Same ids, renamed: still a different list to show the viewer.
  const std::vector<VlcTrackDescription> swapped_names = {
      {1, "English commentary", ""},
      {2, "Hindi", ""},
  };
  EXPECT_NE(VlcPlayerCore::TrackSetFingerprint(swapped_names, spu), before);

  // Reordered, so the count and the id multiset both survive.
  const std::vector<VlcTrackDescription> reordered = {
      {2, "Hindi", ""},
      {1, "English", ""},
  };
  EXPECT_NE(VlcPlayerCore::TrackSetFingerprint(reordered, spu), before);
}

TEST(VlcPlayerCore, TrackSetFingerprintKeepsTheTwoListsApart) {
  const std::vector<VlcTrackDescription> track = {{7, "Commentary", ""}};

  // The audio and spu lists are read from different libVLC vars and are
  // published separately, so an id that moves between them is a real change
  // even though the concatenation of the two lists did not.
  EXPECT_NE(VlcPlayerCore::TrackSetFingerprint(track, {}),
            VlcPlayerCore::TrackSetFingerprint({}, track));

  // And the empty set has to be reachable and stable, since that is what a
  // media with no audio and no subtitles fingerprints to.
  EXPECT_EQ(VlcPlayerCore::TrackSetFingerprint({}, {}),
            VlcPlayerCore::TrackSetFingerprint({}, {}));

  // -1 is the "nothing seen yet" sentinel Snapshot() compares against, so no
  // real track set may ever produce it.
  EXPECT_GE(VlcPlayerCore::TrackSetFingerprint({}, {}), 0);
  EXPECT_GE(VlcPlayerCore::TrackSetFingerprint(track, track), 0);
}

TEST(VlcPlayerCore, RejectsEmptySourceUri) {
  auto core = MakeCore();

  ASSERT_TRUE(core->is_valid()) << core->error();

  EXPECT_EQ(core->SetSource("", {}, {}, 0, false),
            "A non-empty uri is required.");
}

TEST(VlcPlayerCore, ClampsVolumeInSnapshot) {
  auto core = MakeCore();

  ASSERT_TRUE(core->is_valid()) << core->error();

  EXPECT_EQ(core->SetVolume(250), "");
  EXPECT_EQ(core->Snapshot().volume, 200);

  EXPECT_EQ(core->SetVolume(-25), "");
  EXPECT_EQ(core->Snapshot().volume, 0);
}

TEST(VlcPlayerCore, RejectsInvalidPlaybackSpeeds) {
  auto core = MakeCore();

  ASSERT_TRUE(core->is_valid()) << core->error();

  EXPECT_EQ(core->SetPlaybackSpeed(0),
            "A finite positive playback speed is required.");
  EXPECT_EQ(core->SetPlaybackSpeed(-1),
            "A finite positive playback speed is required.");
  EXPECT_EQ(core->SetPlaybackSpeed(std::numeric_limits<double>::infinity()),
            "A finite positive playback speed is required.");
}

TEST(VlcPlayerCore, TakeSnapshotWithoutMediaFailsClearly) {
  auto core = MakeCore();
  std::string error;

  ASSERT_TRUE(core->is_valid()) << core->error();

  const std::vector<uint8_t> data = core->TakeSnapshot(0, 0, &error);

  EXPECT_TRUE(data.empty());
  EXPECT_EQ(error, "No media is loaded.");
}

TEST(VlcPlayerCore, MediaStatsWithoutMediaIsUnavailable) {
  auto core = MakeCore();

  ASSERT_TRUE(core->is_valid()) << core->error();

  const VlcMediaStats stats = core->GetMediaStats();

  EXPECT_FALSE(stats.available);
  EXPECT_EQ(stats.read_bytes, 0);
  EXPECT_EQ(stats.input_bitrate, 0);
  EXPECT_EQ(stats.demux_read_bytes, 0);
  EXPECT_EQ(stats.demux_bitrate, 0);
}

TEST(VlcPlayerCore, CopyPixelsWithoutFrameReturnsFalse) {
  auto core = MakeCore();
  const uint8_t sentinel = 0;
  const uint8_t* buffer = &sentinel;
  uint32_t width = 7;
  uint32_t height = 9;

  ASSERT_TRUE(core->is_valid()) << core->error();

  EXPECT_FALSE(core->CopyPixels(&buffer, &width, &height));
  EXPECT_EQ(buffer, &sentinel);
  EXPECT_EQ(width, 7u);
  EXPECT_EQ(height, 9u);
}

TEST(VlcPlayerCore, ResizeVideoBufferReusesUnchangedBuffers) {
  auto core = MakeCore();

  ASSERT_TRUE(core->is_valid()) << core->error();

  core->ResizeVideoBufferForTesting(4, 4, 16);
  const uint8_t* frame_data = core->FrameBufferDataForTesting();
  const size_t frame_size = core->FrameBufferSizeForTesting();

  core->ResizeVideoBufferForTesting(4, 4, 16);

  EXPECT_EQ(core->FrameBufferDataForTesting(), frame_data);
  EXPECT_EQ(core->FrameBufferSizeForTesting(), frame_size);
  EXPECT_EQ(core->RenderGenerationForTesting(), 0u);
  EXPECT_EQ(core->TextureGenerationForTesting(), 0u);
}

TEST(VlcPlayerCore, CopyPixelsPublishesOnlyNewRenderGenerations) {
  auto core = MakeCore();
  const uint8_t* buffer = nullptr;
  uint32_t width = 0;
  uint32_t height = 0;

  ASSERT_TRUE(core->is_valid()) << core->error();

  core->ResizeVideoBufferForTesting(2, 2, 8);
  core->SimulateFrameForTesting(17);

  EXPECT_TRUE(core->CopyPixels(&buffer, &width, &height));
  EXPECT_EQ(width, 2u);
  EXPECT_EQ(height, 2u);
  ASSERT_NE(buffer, nullptr);
  EXPECT_EQ(buffer[0], 17u);
  EXPECT_EQ(core->TextureGenerationForTesting(),
            core->RenderGenerationForTesting());

  const auto copied_generation = core->TextureGenerationForTesting();
  EXPECT_TRUE(core->CopyPixels(&buffer, &width, &height));
  EXPECT_EQ(core->TextureGenerationForTesting(), copied_generation);

  core->SimulateFrameForTesting(23);
  EXPECT_TRUE(core->CopyPixels(&buffer, &width, &height));
  ASSERT_NE(buffer, nullptr);
  EXPECT_EQ(buffer[0], 23u);
  EXPECT_EQ(core->TextureGenerationForTesting(),
            core->RenderGenerationForTesting());
}

TEST(VlcPlayerCore, SubtitleMarginIsAShareOfThePicture) {
  // libVLC lays the lines out on the frame sink's buffer: the picture's size.
  EXPECT_EQ(VlcPlayerCore::SubtitleMargin(0.15, 360), 54);
  EXPECT_EQ(VlcPlayerCore::SubtitleMargin(0.1, 1080), 108);
  // Held to half the picture.
  EXPECT_EQ(VlcPlayerCore::SubtitleMargin(0.9, 360), 180);
  EXPECT_EQ(VlcPlayerCore::SubtitleMargin(0, 360), 0);
  EXPECT_EQ(VlcPlayerCore::SubtitleMargin(-0.1, 360), 0);
  EXPECT_EQ(VlcPlayerCore::SubtitleMargin(
                std::numeric_limits<double>::quiet_NaN(), 360),
            0);
  // Before the picture has a size.
  EXPECT_EQ(VlcPlayerCore::SubtitleMargin(0.15, 0), 0);
}

TEST(VlcPlayerCore, RaisesSubtitlesByAShareOfThePictureItDraws) {
  auto core = MakeCore();

  ASSERT_TRUE(core->is_valid()) << core->error();

  // Before any frame there is no picture to take a share of.
  EXPECT_EQ(core->SubtitleMarginForTesting(0.15), 0);
  // The frame sink's picture is what libVLC lays the lines out on, and the
  // size the host sends the look again for - not the media's declared size,
  // which libVLC updates later for an adaptive stream or an MPEG-TS.
  core->ResizeVideoBufferForTesting(640, 360, 640 * 4);
  EXPECT_EQ(core->SubtitleMarginForTesting(0.15), 54);
}

TEST(VlcPlayerCore, RestylesSubtitlesOnTheLibVlcItRunsOn) {
  auto core = MakeCore();

  ASSERT_TRUE(core->is_valid()) << core->error();

  VlcSubtitleLookValues look;
  look.text_scale = 150;
  look.color = 0xFFEB3B;
  look.background_opacity = 128;
  look.raise = 0.1;
  bool applied = false;
  EXPECT_EQ(core->SetSubtitleLook(look, &applied), "");
  // Every libVLC this plugin ships with or finds is 3.0, whose libvlccore
  // exports what a look needs.
  EXPECT_TRUE(applied);
}

TEST(VlcPlayerCore, DisposeIsIdempotentAndGuardsCommands) {
  auto core = MakeCore();

  ASSERT_TRUE(core->is_valid()) << core->error();

  core->Dispose();
  core->Dispose();

  EXPECT_FALSE(core->is_valid());
  EXPECT_EQ(core->Play(), "The vlc_player has been disposed.");
  EXPECT_EQ(core->SetVolume(100), "The vlc_player has been disposed.");
  EXPECT_EQ(core->SetAudioDelay(1000), "The vlc_player has been disposed.");
  EXPECT_EQ(core->SetSubtitleDelay(1000),
            "The vlc_player has been disposed.");
  bool applied = true;
  EXPECT_EQ(core->SetSubtitleLook(VlcSubtitleLookValues(), &applied),
            "The vlc_player has been disposed.");
  EXPECT_FALSE(applied);
  EXPECT_TRUE(core->GetAudioTracks().empty());
}

TEST(VlcPlayerCore, EachSourceGetsAFreshPlayerOnTheSameSink) {
  VlcPlayerCore core(VlcPlayerCoreTestOptions(), [] {});
  ASSERT_TRUE(core.is_valid());
  ASSERT_EQ(core.SetSource("file:///nonexistent-a.mp4", {}, {}, 0, false), "");
  libvlc_media_player_t* first = core.PlayerForTesting();
  ASSERT_EQ(core.SetSource("file:///nonexistent-b.mp4", {}, {}, 0, false), "");
  EXPECT_NE(core.PlayerForTesting(), first)
      << "the old player is released on a thread of its own";
  EXPECT_EQ(core.GenerationForTesting(), 1u);
}

TEST(VlcPlayerCore, EventsOfAReplacedPlayerAreDropped) {
  VlcPlayerCore core(VlcPlayerCoreTestOptions(), [] {});
  ASSERT_TRUE(core.is_valid());
  ASSERT_EQ(core.SetSource("file:///nonexistent-a.mp4", {}, {}, 0, false), "");
  ASSERT_EQ(core.SetSource("file:///nonexistent-b.mp4", {}, {}, 0, false), "");
  const uint64_t current = core.GenerationForTesting();

  core.OnBufferingForTesting(current - 1, 40.0f);
  EXPECT_EQ(core.Snapshot().buffering_progress, -1.0);
  core.OnBufferingForTesting(current, 40.0f);
  EXPECT_DOUBLE_EQ(core.Snapshot().buffering_progress, 0.4);
  core.OnBufferingForTesting(current, 100.0f);
  EXPECT_EQ(core.Snapshot().buffering_progress, -1.0);
}

// A source set without keepPicture ends the reported hold at once. Its output
// still shows the held picture until the new media's first, as any texture
// keeps its last image: a bridge the start-up view covers, not a hold (FORK.md
// 30). The sink used to report that bridge as held.
TEST(VlcPlayerCore, APlainSourceEndsTheReportedHoldAndBridgesThePicture) {
  VlcPlayerCore core(VlcPlayerCoreTestOptions(), [] {});
  ASSERT_TRUE(core.is_valid());
  core.ResizeVideoBufferForTesting(2, 2, 8);
  core.SimulateFrameForTesting(9);
  const uint8_t* pixels = nullptr;
  uint32_t width = 0;
  uint32_t height = 0;
  ASSERT_TRUE(core.CopyPixels(&pixels, &width, &height));

  ASSERT_EQ(core.SetSource("file:///nonexistent-a.mp4", {}, {}, 5000, false,
                           /*keep_picture=*/true),
            "");
  EXPECT_TRUE(core.Snapshot().picture_held);

  ASSERT_EQ(core.SetSource("file:///nonexistent-b.mp4", {}, {}, 0, false), "");
  EXPECT_FALSE(core.Snapshot().picture_held)
      << "a source set without keepPicture ends the hold at once";
  ASSERT_TRUE(core.CopyPixels(&pixels, &width, &height));
  EXPECT_EQ(pixels[0], 9u) << "the old picture stays until the new media's";

  // A picture libVLC finishes, through the sink's own callbacks.
  VlcPixelBufferSink* sink = core.FrameSinkForTesting();
  void* planes[1] = {nullptr};
  void* picture = sink->Acquire(planes);
  ASSERT_NE(picture, nullptr);
  static_cast<uint8_t*>(planes[0])[0] = 21;
  sink->Release(picture, planes);
  ASSERT_TRUE(core.CopyPixels(&pixels, &width, &height));
  EXPECT_EQ(pixels[0], 21u);
}

// A reopen that fails before it plays keeps the hold, and the picture, until
// the next source decides: the recovery's next reopen carries it on, and its
// own first time after its Opening ends it.
TEST(VlcPlayerCore, AHeldReopenThatFailsBeforeItPlaysKeepsTheHold) {
  VlcPlayerCore core(VlcPlayerCoreTestOptions(), [] {});
  ASSERT_TRUE(core.is_valid());
  core.ResizeVideoBufferForTesting(2, 2, 8);
  core.SimulateFrameForTesting(9);
  const uint8_t* pixels = nullptr;
  uint32_t width = 0;
  uint32_t height = 0;
  ASSERT_TRUE(core.CopyPixels(&pixels, &width, &height));
  ASSERT_EQ(core.SetSource("file:///nonexistent-a.mp4", {}, {}, 5000, false,
                           /*keep_picture=*/true),
            "");
  const uint64_t failing = core.GenerationForTesting();

  core.OnOpeningForTesting(failing);
  core.OnMediaGoneForTesting(failing);
  EXPECT_TRUE(core.Snapshot().picture_held)
      << "the held picture is still what is shown";
  ASSERT_TRUE(core.CopyPixels(&pixels, &width, &height));
  EXPECT_EQ(pixels[0], 9u);

  ASSERT_EQ(core.SetSource("file:///nonexistent-b.mp4", {}, {}, 5000, false,
                           /*keep_picture=*/true),
            "");
  const uint64_t next = core.GenerationForTesting();
  EXPECT_TRUE(core.Snapshot().picture_held);
  core.OnTimeChangedForTesting(next);
  EXPECT_TRUE(core.Snapshot().picture_held)
      << "a time before the new media's Opening says nothing about it";
  core.OnOpeningForTesting(next);
  core.OnTimeChangedForTesting(next);
  EXPECT_FALSE(core.Snapshot().picture_held);
}

// The time report that ends a hold asks for a snapshot, and that snapshot
// already says the hold is over, with the size the new media's output
// negotiated: Dart lays the picture out at the shape the value carries. The
// pixels follow at the next picture libVLC finishes.
TEST(VlcPlayerCore, TheHoldEndsInTheTimeReportsOwnSnapshotWithTheNewSize) {
  // Atomic: libVLC calls back on its own threads.
  std::atomic<int> changes{0};
  VlcPlayerCore core(VlcPlayerCoreTestOptions(), [] {},
                     [&changes] { ++changes; });
  ASSERT_TRUE(core.is_valid());
  core.ResizeVideoBufferForTesting(4, 2, 16);
  core.SimulateFrameForTesting(9);
  const uint8_t* pixels = nullptr;
  uint32_t width = 0;
  uint32_t height = 0;
  ASSERT_TRUE(core.CopyPixels(&pixels, &width, &height));
  ASSERT_EQ(core.SetSource("file:///nonexistent-a.mp4", {}, {}, 5000, false,
                           /*keep_picture=*/true),
            "");
  const uint64_t current = core.GenerationForTesting();
  // The new media's output negotiates its own size while the hold is on.
  core.ResizeVideoBufferForTesting(2, 2, 8);
  core.OnOpeningForTesting(current);
  EXPECT_TRUE(core.Snapshot().picture_held);

  const int before = changes.load();
  core.OnTimeChangedForTesting(current);
  EXPECT_GT(changes.load(), before) << "the time report asks for a snapshot";
  const VlcSnapshot snapshot = core.Snapshot();
  EXPECT_FALSE(snapshot.picture_held) << "and that snapshot ends the hold";
  EXPECT_EQ(snapshot.video_width, 2);
  EXPECT_EQ(snapshot.video_height, 2);
  ASSERT_TRUE(core.CopyPixels(&pixels, &width, &height));
  EXPECT_EQ(width, 4u) << "the held picture until the next finished one";
}

TEST(VlcPlayerCore, TheLogCountsARefusedSeekAndNothingElse) {
  VlcPlayerCore core(VlcPlayerCoreTestOptions(), [] {});
  ASSERT_TRUE(core.is_valid());
  core.LogForTesting(LIBVLC_DEBUG, "Seek %f to %lld", 0.5, 180000000LL);
  EXPECT_EQ(core.Snapshot().seek_refusals, 0);

  // libVLC 3.0.24's own text (input.c, Control): "%"PRId64, microseconds.
  core.LogForTesting(LIBVLC_WARNING,
                     "INPUT_CONTROL_SET_TIME %lld failed or not possible",
                     180000000LL);
  const VlcSnapshot snapshot = core.Snapshot();
  EXPECT_EQ(snapshot.seek_refusals, 1);
  EXPECT_EQ(snapshot.seek_refused_at, 180000);
}

TEST(VlcPlayerCore, ThePluginBankOutlivesEveryPlayer) {
  {
    VlcPlayerCore core(VlcPlayerCoreTestOptions(), [] {});
    ASSERT_TRUE(core.is_valid());
  }
  EXPECT_TRUE(VlcPlayerCore::PluginBankKeptForTesting());
}

// The bug spec 3 removes: leaving or switching a stream whose download has
// stalled waited for the download, on the platform thread. A local server
// stalls an HLS segment for three seconds; the old core's switch waited all
// three, and the stall's whole length when it had none.
TEST(VlcPlayerCore, SwitchingAndDisposingDoNotWaitForAStalledRead) {
  StallingServer server;
  ASSERT_TRUE(server.Start());
  VlcPlayerCore core(VlcPlayerCoreTestOptions(), [] {});
  ASSERT_TRUE(core.is_valid());
  ASSERT_EQ(core.SetSource(server.Url(), {}, {}, 0, true), "");
  ASSERT_TRUE(server.WaitForRequest(std::chrono::seconds(10)));
  std::this_thread::sleep_for(std::chrono::milliseconds(500));

  const auto took = [](std::chrono::steady_clock::time_point since) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now() - since)
        .count();
  };
  auto started = std::chrono::steady_clock::now();
  ASSERT_EQ(core.SetSource(server.Url(), {}, {}, 0, true), "");
  const auto switched = took(started);
  EXPECT_LT(switched, 500) << "the switch took " << switched << " ms";
  ASSERT_TRUE(server.WaitForRequest(std::chrono::seconds(10)));

  started = std::chrono::steady_clock::now();
  core.Dispose();
  const auto disposed = took(started);
  EXPECT_LT(disposed, 500) << "the dispose took " << disposed << " ms";
}

}  // namespace test
}  // namespace vlc_player

#endif  // VLC_PLAYER_TEST_NATIVE_VLC_PLAYER_CORE_TEST_SUITE_H_
