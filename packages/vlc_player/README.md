# vlc_player

A Flutter plugin for video playback using VLC.

`vlc_player` creates a native VLC-backed video view and exposes a Dart
controller for loading media, controlling playback, selecting tracks, handling
subtitles, reading playback state and media statistics, and capturing
snapshots.

## Supported platforms

- Android
- iOS
- macOS
- Windows
- Linux

The plugin forwards media URIs to the native VLC library. Supported media
formats, codecs, playlists, and stream protocols depend on the VLC runtime used
on the target platform. Common VLC-supported sources include MP4, MOV, MKV,
WebM, AVI, FLV, MPEG-TS, HLS (`.m3u8`), DASH, RTSP, and RTP.

## Installation

Add the package to your app:

```yaml
dependencies:
  vlc_player: ^2.1.3
```

Then run:

```sh
flutter pub get
```

Apps that embed this plugin must satisfy the binary distribution and license
requirements for libVLC, MobileVLCKit, VLCKit, and the VLC Windows runtime. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the third-party runtime
and source components that app distributors need to account for.

## Platform setup

### Android

Android apps must use `minSdk 29` or newer.

Network playback requires internet access. The plugin manifest declares:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

### iOS

The iOS implementation requires iOS 13 or newer.

The iOS implementation depends on `MobileVLCKit`.

HTTPS media URLs work without extra transport configuration. If your app plays
non-HTTPS URLs, configure App Transport Security in the app's `Info.plist`.

### macOS

The macOS implementation requires macOS 10.15 or newer.

The macOS implementation depends on `VLCKit`.

For sandboxed apps that play network media, enable the network client
entitlement:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

Use CocoaPods `1.13.0` or newer so the VLCKit runtime path script phase runs
reliably.

### Windows

The Windows implementation downloads the VLC Windows runtime during
`flutter build windows` and bundles it into your app automatically:

```text
build/windows/x64/runner/Release/
  your_app.exe
  libvlc.dll
  libvlccore.dll
  plugins/
```

The first Windows build requires network access to download the verified VLC
runtime archive.

### Linux

The Linux implementation links against the system libVLC package through
pkg-config. Install VLC development files before building a Linux app:

```sh
sudo apt install libvlc-dev vlc
```

## Usage

### Create a player

```dart
import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

class VideoPage extends StatefulWidget {
  const VideoPage({super.key});

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  late final VlcPlayerController controller = VlcPlayerController(
    mediaSource: VlcMediaSource(
      uri: Uri.parse('https://example.com/video.mp4'),
    ),
    autoPlay: true,
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: VlcPlayer(controller: controller),
    );
  }
}
```

`setMedia()` can be called before the controller is attached to a `VlcPlayer`.
Commands such as `play()`, `pause()`, and `seekTo()` require an attached player
and throw `StateError` if called too early or after disposal.

### Play an HLS stream

Pass the `.m3u8` playlist URL as the media source:

```dart
final controller = VlcPlayerController(
  mediaSource: VlcMediaSource(
    uri: Uri.parse('https://example.com/live/playlist.m3u8'),
  ),
  autoPlay: true,
);
```

### Load media with headers and VLC options

Use `VlcMediaSource` when a URL needs request headers, per-item VLC media
options, or an initial seek position:

```dart
await controller.setMedia(
  VlcMediaSource(
    uri: Uri.parse('https://example.com/protected/video.mp4'),
    httpHeaders: const <String, String>{
      'Authorization': 'Bearer token',
    },
    mediaOptions: const <String>[
      ':network-caching=1200',
    ],
    startPosition: const Duration(seconds: 30),
  ),
  autoPlay: true,
);
```

### Control playback

```dart
await controller.play();
await controller.pause();
await controller.seekTo(const Duration(seconds: 30));
await controller.setVolume(100);
await controller.setPlaybackSpeed(1.25);
await controller.setAudioDelay(const Duration(milliseconds: -120));
await controller.setSubtitleDelay(const Duration(milliseconds: 250));
await controller.stop();
```

### Fit the video

Use `VlcPlayer.fit` to choose how the video is fitted inside the widget:

```dart
VlcPlayer(
  controller: controller,
  fit: VlcVideoFit.cover,
)
```

Available values are `contain`, `cover`, `fill`, and `none`.

### Capture a snapshot

```dart
final pngBytes = await controller.takeSnapshot(width: 320);
debugPrint('snapshot bytes=${pngBytes.length}');
```

When only `width` or `height` is provided, VLC preserves the source aspect ratio
where the platform backend supports it.

### Play a playlist

```dart
await controller.setPlaylist(
  <VlcMediaSource>[
    VlcMediaSource(uri: Uri.parse('https://example.com/episode-1.mp4')),
    VlcMediaSource(uri: Uri.parse('https://example.com/episode-2.mp4')),
  ],
  autoPlay: true,
  autoAdvance: true,
  loopMode: VlcPlaylistLoopMode.loopAll,
);

await controller.next();
await controller.previous();
await controller.jumpTo(0);
await controller.addToPlaylist(
  VlcMediaSource(uri: Uri.parse('https://example.com/bonus.mp4')),
);
await controller.shufflePlaylist(seed: 42);
```

Playlist state is available through `playlist`, `playlistIndex`,
`playlistLoopMode`, `currentMediaSource`, `hasNext`, and `hasPrevious`.

### Select tracks and subtitles

```dart
final audioTracks = await controller.getAudioTracks();
if (audioTracks.isNotEmpty) {
  await controller.setAudioTrack(audioTracks.first.id);
}

final subtitleTracks = await controller.getSubtitleTracks();
if (subtitleTracks.isNotEmpty) {
  await controller.setSubtitleTrack(subtitleTracks.first.id);
}

await controller.addSubtitle(Uri.file('/path/to/subtitles.srt'));
await controller.disableSubtitle();

final info = await controller.getMediaInfo();
debugPrint('duration=${info.duration}');

final stats = await controller.getMediaStats();
if (stats.isAvailable) {
  debugPrint('decoded video blocks=${stats.decodedVideo}');
}
```

Track selection methods use native VLC track ids returned by
`getAudioTracks()` and `getSubtitleTracks()`.

The active selection is part of the value, not a separate call:
`value.activeAudioTrackId` and `value.activeSubtitleTrackId` carry the id the
engine is currently using (`null` when there is none, or subtitles are off), and
`value.trackRevision` moves whenever the track *set* changes - a good moment
to refetch the lists, and the only reliable signal that an `addSubtitle` has
landed (see [VlcPlayerController](#vlcplayercontroller)).

```dart
ValueListenableBuilder<VlcPlayerValue>(
  valueListenable: controller,
  builder: (context, value, child) {
    final active = value.activeSubtitleTrackId;
    return Text(active == null ? 'Subtitles off' : 'Subtitle track $active');
  },
)
```

### Listen for state changes

`VlcPlayerController` extends `ValueNotifier<VlcPlayerValue>`.

```dart
ValueListenableBuilder<VlcPlayerValue>(
  valueListenable: controller,
  builder: (context, value, child) {
    return Text('${value.state} ${value.position}');
  },
)
```

Native platform failures throw `VlcPlayerException` and may also be exposed
through `VlcPlayerValue.error`.

```dart
try {
  await controller.play();
} on VlcPlayerException catch (error) {
  debugPrint('VLC command failed: ${error.code} ${error.message}');
}
```

## API

The supported application-facing API is exported from:

```dart
import 'package:vlc_player/vlc_player.dart';
```

Native view attachment, texture creation, method channels, and platform view
type details are implementation internals.

### VlcPlayer

`VlcPlayer` is the Flutter widget that hosts the native VLC video output.

```dart
const VlcPlayer({
  Key? key,
  required VlcPlayerController controller,
  Color backgroundColor = Colors.black,
  VlcVideoFit fit = VlcVideoFit.contain,
})
```

- `controller`: controller used to load media, control playback, and observe
  state.
- `backgroundColor`: color shown behind the native video output.
- `fit`: video fitting behavior inside the widget bounds.

### VlcPlayerController

`VlcPlayerController` owns playback state and sends commands to the native VLC
player.

```dart
VlcPlayerController({
  VlcMediaSource? mediaSource,
  bool autoPlay = false,
  List<String> options = const <String>[],
  Duration? eventThrottleInterval,
})
```

- `mediaSource`: optional initial media item.
- `autoPlay`: starts playback after the initial media source is loaded.
- `options`: VLC instance options applied when the native player is created.
- `eventThrottleInterval`: optional interval for coalescing progress-only
  native events.

Important properties:

- `value`: current `VlcPlayerValue`.
- `isAttached`: whether the controller is attached to a native player.
- `playlist`, `playlistIndex`, `playlistLoopMode`: current playlist state.
- `currentMediaSource`: active or pending media source.
- `hasNext`, `hasPrevious`: whether playlist navigation can move without
  wrapping.
- `playbackClock`: where playback is at this moment, between the engine's
  reports, for subtitle lines or anything else drawn against the picture. It
  runs on at the playback speed while playing, jumps to a seek's target at
  once, never moves back unless playback did (a seek, new media, a stop or a
  failure), and holds a second past the engine's last report. Read
  `position`; `timeUntil(target)` says when it will get there, and listeners
  hear when it changes course.

Media and playlist methods:

- `setMedia(VlcMediaSource source, {bool autoPlay = false})`
- `setPlaylist(List<VlcMediaSource> sources, {int initialIndex = 0, bool autoPlay = false, bool autoAdvance = true, VlcPlaylistLoopMode loopMode = VlcPlaylistLoopMode.none})`
- `next({bool autoPlay = true})`
- `previous({bool autoPlay = true})`
- `jumpTo(int index, {bool autoPlay = true})`
- `addToPlaylist(VlcMediaSource source)`
- `insertIntoPlaylist(int index, VlcMediaSource source)`
- `removeFromPlaylistAt(int index, {bool autoPlay = true})`
- `clearPlaylist()`
- `shufflePlaylist({int? seed})`

Playback methods:

- `play()`
- `pause()`
- `stop()`
- `seekTo(Duration position)`
- `setVolume(int volume)`
- `setPlaybackSpeed(double speed)`
- `setAudioDelay(Duration delay)`
- `setSubtitleDelay(Duration delay)`
- `takeSnapshot({int? width, int? height})`
- `setDurationCap(Duration? cap)`: reports at most `cap` as the duration until
  the next media, for a length libVLC overstates. libVLC takes an HLS master's
  length from its longest playlist, alternative renditions included, so a
  subtitle playlist that claims more than the video sets it; pass the video
  playlist's own length. Only ever shortens; `null` lifts it.

Track, subtitle, and media information methods:

- `getAudioTracks()`
- `setAudioTrack(int id)`
- `getSubtitleTracks()`
- `setSubtitleTrack(int id)`
- `disableSubtitle()`
- `addSubtitle(Uri uri)`
- `getMediaInfo()`
- `getMediaStats()`

`setVolume()` clamps values to VLC's `0..200` range. `seekTo()` requires a
non-negative position. `setPlaybackSpeed()` requires a finite value greater
than zero.

Every track mutation (`setAudioTrack`, `setSubtitleTrack`, `disableSubtitle`,
`addSubtitle`) and every `seekTo` is followed by a fresh `VlcPlayerValue` on
all five backends, and a change in `activeAudioTrackId`,
`activeSubtitleTrackId` or `trackRevision` is never held back by
`eventThrottleInterval`.

For the three *selection* mutations that snapshot carries the result: choosing
a track is a synchronous write on the player that reads straight back on every
backend that was checked, so `activeAudioTrackId` / `activeSubtitleTrackId`
are already correct in it. Should an engine ever report the previous id there,
the next time tick corrects it - a late value, never a wrong one that sticks.

`addSubtitle` is the exception, on all five backends. libVLC 3 posts an added
slave to the input thread instead of applying it inline, so the snapshot that
immediately follows the call still describes the pre-add track list, and the
future completing means "the engine accepted the slave", not "the track is in
the list now". The side-car appears when the engine announces the new
elementary stream - `.esAdded` on macOS and iOS, `MediaPlayer.Event.ESAdded`
on Android, the next 500 ms poll on Windows and Linux - which moves
`trackRevision`. Refetch the lists from a `trackRevision` change; do not
refetch them synchronously after `await controller.addSubtitle(...)`.

### VlcMediaSource

`VlcMediaSource` describes one media item before it is passed to VLC.

```dart
VlcMediaSource({
  required Uri uri,
  Map<String, String> httpHeaders = const <String, String>{},
  List<String> mediaOptions = const <String>[],
  Duration startPosition = Duration.zero,
})
```

- `uri`: non-empty media URI to load.
- `httpHeaders`: headers to present when opening the media. Only `User-Agent`
  and `Referer` are actually transmitted — libVLC 3.x has no option for any
  other header, so `Cookie`, `Authorization`, `Origin` and custom headers are
  dropped. Use `unsupportedVlcHeaders` to detect this, and proxy the media if
  the server requires them.
- `mediaOptions`: VLC media options applied only to this source.
- `startPosition`: non-negative initial playback position.

### VlcPlayerValue

`VlcPlayerValue` is the immutable playback snapshot emitted by the controller.

Fields:

- `state`
- `position`
- `duration`
- `volume`
- `playbackSpeed`
- `audioDelay`
- `subtitleDelay`
- `activeAudioTrackId` - the native id of the audio track in use, or `null`
  when there is none. libVLC's `-1` is normalised to `null`; `0` is a real id.
- `activeSubtitleTrackId` - the native id of the subtitle track being rendered,
  or `null` when subtitles are off.
- `trackRevision` - a per-player counter that increases whenever the audio +
  subtitle track *set* changes, not merely when its size does: macOS, iOS,
  Windows and Linux hash the ids and names of both lists into every snapshot,
  so a same-size swap (an adaptive rendition change, an MPEG-TS PMT update) is
  caught too, while Android bumps on an audio or subtitle `ESAdded` /
  `ESDeleted` and deliberately not on a video-only one. Refetch the track
  lists when it moves - including after `addSubtitle`, which only lands here.
- `isReady`
- `isSeekable`
- `isLive`
- `videoSize`
- `bufferingProgress`
- `error`
- `errorDescription`

Convenience getters:

- `isPlaying`
- `isBuffering`
- `hasError`

### VlcPlaybackState

Possible playback states:

- `idle`
- `opening`
- `buffering`
- `playing`
- `paused`
- `stopped`
- `ended`
- `error`

### VlcVideoFit

Possible video fitting values:

- `contain`
- `cover`
- `fill`
- `none`

### VlcPlaylistLoopMode

Possible playlist loop values:

- `none`
- `loopOne`
- `loopAll`

### Track, media information, and media statistics

`getAudioTracks()` and `getSubtitleTracks()` return
`VlcTrackDescription` objects:

- `id`: native VLC track id.
- `name`: track name reported by VLC.
- `language`: optional language code or label reported by VLC.

`getMediaInfo()` returns `VlcMediaInfo`:

- `title`, `artist`, `album`: metadata discovered by VLC when available.
- `duration`: media duration, or `Duration.zero` when unknown.
- `videoTracks`, `audioTracks`, `subtitleTracks`: lists of
  `VlcMediaTrackInfo`.

`VlcMediaTrackInfo` includes `type`, `codec`, `language`, `bitrate`, `width`,
`height`, `channels`, and `sampleRate`. These values are best-effort because
containers and streams do not always expose every field.

`getMediaStats()` returns `VlcMediaStats`:

- `isAvailable`: whether VLC reported statistics for the current media.
- `readBytes`, `inputBitrate`: current input module counters.
- `demuxReadBytes`, `demuxBitrate`, `demuxCorrupted`,
  `demuxDiscontinuity`: current demux counters.
- `decodedVideo`, `decodedAudio`: decoded block counters.
- `displayedPictures`, `lostPictures`: video output counters.
- `playedAudioBuffers`, `lostAudioBuffers`: audio output counters.
- `sentPackets`, `sentBytes`, `sendBitrate`: stream-output counters.

When no media is loaded or VLC cannot provide statistics, `isAvailable` is
`false` and the numeric values are zero.

### Device volume and brightness (Android and iOS)

For a player's own volume and brightness swipes. Elsewhere the calls fail
with a `MissingPluginException`: a desktop's mixer and monitor stay its own.

- `VlcSystemVolume.read()`, `write(double level)` and `changes`: the device's
  media volume, 0..1. Android sets the media stream one step at a time, with
  no system pop-up. A raise that the hearing-safety limit holds back is asked
  again with the system's UI, which shows its confirmation. iOS sets it through
  the system's own volume control and touches no audio session.
- `VlcSystemVolume.setPlayerShown(bool shown)`: while the player is on screen,
  iOS shows no volume pop-up for the hardware buttons, and on Android the
  buttons move the media volume even while paused.
- `VlcSystemVolume.isFixed()`: Android's `isVolumeFixed`. Use the player's own
  gain (`setVolume`) instead where it is true.
- `VlcScreenBrightness.read()`, `set(double level)` and `reset()`: the app's
  screen brightness, applied at once. On Android it is the app window's (never
  below 0.01); on iOS the system's level is kept and given back on `reset()`
  and while the app is in the background.

A swipe calls these many times a second. Keep one call in flight and send
only the newest value after it, and expect `changes` to report the app's own
writes back a moment later.

### Errors

Native command failures are exposed as `VlcPlayerException`, which wraps a
structured `VlcPlayerError`.

`VlcPlayerError` exposes:

- `code`
- `message`
- `details`
- `description`

Common error codes are available in `VlcPlayerErrorCode`, including
`invalidArgs`, `playerNotFound`, `createFailed`, `setSourceFailed`,
`trackNotFound`, `addSubtitleFailed`, `playbackError`, `disposed`, and
`eventChannelError`.

## API stability

The `2.x` line follows Semantic Versioning. Backward-compatible additions use
minor versions, fixes use patch versions, and breaking API, platform, or
behavior changes use major versions.

Native view attachment, texture creation, method channels, platform view type
strings, and generated platform registration details are implementation
internals. Applications should import only `package:vlc_player/vlc_player.dart`
and use the public types documented above.

## Migrating from 1.x or 0.8.x

Version `2.0.0` requires Android `minSdk 29` or newer.

The Dart-facing API remains backward compatible, but Android apps that still
target a lower minimum SDK must raise it before upgrading.

## Migrating from 0.7.21 or earlier

For apps migrating from older releases that used `source`, `httpHeaders`, or
`setSource()`, use `VlcMediaSource` and `setMedia()` instead:

```dart
final controller = VlcPlayerController(
  mediaSource: VlcMediaSource(
    uri: Uri.parse('https://example.com/video.mp4'),
    httpHeaders: const <String, String>{
      'Authorization': 'Bearer token',
    },
  ),
  autoPlay: true,
);

await controller.setMedia(
  VlcMediaSource(uri: Uri.parse('https://example.com/next.mp4')),
  autoPlay: true,
);
```

## Troubleshooting

### `player_not_found`

This usually means a command was sent after the native player was disposed or
before the controller attached to the current `VlcPlayer`. Keep one
`VlcPlayerController` per player widget and call `dispose()` from the owning
widget's `dispose()` method.

### Network playback fails

Check that:

- The media URL is reachable from the device.
- Android has internet permission.
- macOS sandboxed apps have the network client entitlement.
- iOS allows the URL through App Transport Security if it is not HTTPS.
- Required HTTP headers are passed through `VlcMediaSource.httpHeaders`, which
  can carry only `User-Agent` and `Referer` to the network — see above.
- Linux has `libvlc-dev` and `vlc` installed.

### macOS `Library not loaded: VLCKit`

Run `pod install` in the macOS app directory and rebuild:

```sh
cd macos
pod install
cd ..
flutter build macos
```

Also make sure CocoaPods is `1.13.0` or newer.
