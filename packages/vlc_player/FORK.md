# Fork notes

Vendored fork of [`lingjhf/vlc_player`](https://github.com/lingjhf/vlc_player).

**Upstream base:** `82b155f` — "fix(pub): expand package description" (2026-06-02, pub `2.1.2`).

Upstream is a single-maintainer project that has been quiet since June 2026, with
open bug reports and an unmerged community fix. We treat this tree as ours: land
changes here, keep this file current, and upstream anything generally useful.

Everything below is additive or a bug fix. No upstream API was removed, so the
package stays usable by any Flutter app, not just this one.

---

## Changes against upstream

### 1. Windows create/dispose UI stalls — upstream PR #5

Cherry-picked [PR #5](https://github.com/lingjhf/vlc_player/pull/5) by
`DaPotatoMan`, which upstream has not merged. Moves heavy Windows VLC
initialisation off the platform-handler path, makes disposal tear VLC down
asynchronously, and guards player lifetime across overlapping create/dispose.

Fixes upstream issue #2 (UI thread stuck on the first player creation).
Touches `windows/vlc_player_plugin.cpp` and `.h` only.

### 2. Apple: unmodelled player states no longer report "not ready"

*Fixes upstream issue #6 — "player events such as playing/buffering/ready not
fired properly" on iOS.*

`stateName` switched on `VLCMediaPlayerState` and mapped everything it did not
recognise to `"idle"`, and `isReadyState("idle")` is `false`. VLCKit 3.x emits
`.esAdded` during normal start-up and whenever an elementary stream appears — a
track switch or an adaptive rendition change — so a *playing* player would
report `isReady == false` in the middle of playback. Any host driving its UI
off `isReady` sees the player drop out and come back.

`stateName` now takes the player rather than the bare state, and for an
unmodelled case derives from the transport: `"idle"` only when no media is
loaded, otherwise `playing`/`opening` from `player.isPlaying`.

Applied identically to `ios/` and `macos/`.

### 3. `isLive` no longer flaps true at the start of every VOD

`isLive` is derived as `isLiveState(state) && duration == 0 && !isSeekable`.
Both of those are trivially true while VLC is still opening a stream, and
`isLiveState` counted `buffering` — so *every* VOD reported `isLive` for its
first frames. Long enough for a host to hide its seek bar and speed control and
then have to put them back.

`buffering` is no longer a live state; `playing` and `paused` remain. By the
time either is reached VLC generally knows the duration.

Applied to `android/`, `ios/` and `macos/`.

### 4. New: typed configuration — `lib/src/vlc_player_config.dart`

Upstream configures libVLC through an untyped `List<String> options`. That is
flexible but pushes every caller into hand-writing VLC flags and re-deriving the
same defaults, and it is where host apps accumulate a pile of magic strings.

Adds `VlcPlayerConfig` with `VlcNetworkConfig`, `VlcDecodingConfig` and
`VlcSubtitleStyle`, each of which compiles to the correct `--…` options:

| Concern | Typed as | Emits |
|---|---|---|
| Buffering | `networkCaching` / `liveCaching` / `fileCaching` | `--network-caching` etc. |
| HTTP identity | `userAgent`, `referer` | `--http-user-agent`, `--http-referrer` |
| Adaptive streams | `adaptiveLogic`, `adaptiveMaxHeight` | `--adaptive-logic`, `--adaptive-maxheight` |
| Hardware decode | `VlcHardwareAcceleration` | `--avcodec-hw=any\|none` |
| Weak-CPU fallback | `VlcDecodeThrift` | `--avcodec-skiploopfilter`, `--avcodec-skip-frame` |
| Subtitle look | `VlcSubtitleStyle` | `--freetype-*`, `--sub-margin` |

`VlcPlayerController` gains an optional `config:`. It is expanded *before* any
raw `options`, so a raw option still wins — the escape hatch is intact and the
existing `options`-only path is unchanged.

Also adds `VlcPlayerCapabilities`, which states the limits a host would
otherwise hard-code at its call sites — notably `maxVolumePercent = 200`
(libVLC amplifies past 100%), and the two honest negatives:
`supportsRuntimeSubtitleStyling = false` (VLC 3.x fixes styling at instance
creation) and `supportsToneMapping = false` (no mpv-`vo_gpu` equivalent).

Covered by `test/vlc_player_config_test.dart`.

### 5. Android `minSdk` lowered 29 → 24

Upstream set `minSdk = 29` in `android/build.gradle.kts` as a bare line in
`defaultConfig` with no comment and nothing requiring it.

It is not a real constraint:

* **libVLC declares `minSdkVersion="17"`** — read from the `libvlc-all:3.7.0`
  AAR manifest, not inferred.
* The plugin's Kotlin contains **no `@RequiresApi`, no `Build.VERSION` check and
  no `SDK_INT` guard anywhere**, and every Android import is API-17-era except
  one: `android.view.PixelCopy` (API 24), used only by `takeSnapshot`.

So the floor the code actually needs is 24 — which is exactly Flutter's default
`minSdkVersion`, so hosts inherit it for free.

This matters beyond tidiness. A host app's effective `minSdk` is the highest
across itself and all its plugins (it is not forced by the app the way
`compileSdk` and `targetSdk` typically are), so 29 silently raised any host to
29 — excluding Android 7, 8 and 9. **Fire OS 7 is Android 9 / API 28**, so
upstream's default quietly dropped a large share of Fire TV devices.

Going below 24 is possible and cheap — guard the single `PixelCopy` call in
`VlcPlayerPlatformView` behind `SDK_INT >= 24` and degrade snapshots — but is
deliberately **not** done here; 24 is Flutter's own floor and going lower means
fighting the toolchain for devices that cannot decode modern codecs anyway.

Verified by reading the AAR manifest and the plugin source. **Not yet verified by
an Android build** at the time of writing. The package is now the host's
only playback engine.

### 6. Dropped upstream repo scaffolding

Removed `.github/` and `.vscode/`, matching how `flutter_js_ng`
and `flutter_torrent_server` are vendored here — the host repo owns CI.

`test/release_metadata_test.dart` went with them. It asserted on upstream's
pub.dev release process — that the version string matches across README,
CHANGELOG, podspecs and `example/pubspec.lock`, that the podspec author is
`lingjhf`, that the description fits pub.dev's length guidance. None of that
describes package behaviour, and none of it is true or wanted for a vendored
fork that will never be published to pub.dev.

### 7. `addSubtitle` before attachment queues instead of throwing

Upstream, `setMedia` may be called before a `VlcPlayer` is mounted — it stores
the source and applies it when the view is attached. `addSubtitle` did not: it
went straight to `_attachedArguments`, which throws

    StateError: The controller is not attached to a VlcPlayer.

That asymmetry is a trap. The natural way to start playback is to set the media
and its side-car subtitles together, before building the widget that shows it,
and only the first of those two calls worked. Every caller would otherwise
reimplement the same "wait until attached" dance.

`addSubtitle` now queues when there is no view and flushes, in order, from both
attach paths (`attach` and `attachTexturePlayer`), right after the pending media
is applied. Setting new media discards subtitles queued for the previous media.
A queued subtitle that fails to load is dropped rather than thrown: the video is
still playable without it, and attachment must not fail because a side-car URI
was bad.

Covered by `subtitles added before attachment are applied in order` and
`new media drops subtitles queued for the old media`.

### 8. HTTP headers now use options libVLC actually has

Upstream converted every entry of a source's header map into a media option:

    media.addOption(":http-header=$name: $value")

**`http-header` is not a libVLC option.** It exists in no VLC 3.x build. I dumped the option-name
string tables of every binary this app ships — `libvlc-all:3.7.0` (the pinned Android AAR),
`MobileVLCKit 3.7.3`, `VLCKit 3.7.3`, and the VLC 3.0.23 desktop core. All four contain
`http-user-agent`, `http-referrer` and `http-forward-cookies`. None contains `http-header`.
Rechecked on 2026-10-02 for the move to VLC 3.0.24 (`libvlc-all:3.7.7`, VLCKit
3.0-20260922-1444, the 3.0.24 Windows core): the same holds.
libvlccore parses the unknown option, logs `unknown option %s`, and drops it — and the log is
suppressed by the default `--quiet`.

The effect was total and silent: **no per-source HTTP header reached the network on any of the five
platforms.** No Referer, no Cookie, no Authorization, no Origin, and not even a source's own
User-Agent. A caller could pass a complete, correct header map, see no error, and watch the server
answer 403. Nothing in the package or its tests could catch it, because every layer agreed the
header had been handed on.

The translation now happens once, in Dart, in `_sourceArguments()` — the single builder every
`setSource` payload goes through, so all five backends inherit one policy instead of five copies of
it. `lib/src/vlc_http_headers.dart` maps `User-Agent` → `:http-user-agent=` and `Referer`/`Referrer`
→ `:http-referrer=`, skipping blank values and any value containing CR or LF, which would otherwise
corrupt the options after it in the list. Per-media options override the instance-level
`--http-user-agent` through VLC's variable inheritance, so a source carrying its own User-Agent now
wins while sources carrying none still get the configured default. The `:http-header=` emission is
deleted from all five native backends; the raw map is still delivered in the payload for genuinely
platform-specific mechanisms (iOS's `storeCookie:forHost:path:`, for instance) but produces no
options.

`Cookie`, `Authorization`, `Origin` and custom headers have **no libVLC representation at all**.
Pretending otherwise is what caused this, so the package no longer does: `unsupportedVlcHeaders()`
names exactly which headers will not be sent, and a debug build prints them per source. A host app
that must honour them has to proxy the media and inject them upstream — which is what SkyStream now
does through `LocalProxyService`.

Covered by `test/vlc_http_headers_test.dart` and two channel-boundary tests in
`vlc_player_controller_test.dart` that assert the emitted option strings and that nothing containing
`http-header` is ever produced.

### 9. Android: HLS and MPEG-TS report a video size

On Android, `videoSize`, `videoOrientation` and so `displayVideoSize` stayed null for the whole of
every MPEG-TS and HLS stream, so a host that turns the device to match the video never turned it for
most anime and live sources. MP4 and MKV were fine.

The size is read from `MediaPlayer.currentVideoTrack`, which returns the first video entry of
libvlc-android's `Media` track array. `Media.getTracks()` caches that array on first read, and only
`postParse()` - a `ParsedChanged` event, which playback never raises - clears it (read from the
`libvlc-all:3.7.0` bytecode). A TS video track exists before the decoder has parsed a frame, so the
first read cached it at 0x0 for the life of the media, although libVLC's own track info filled in a
moment later. MP4 and MKV declare their size in the container, so their first read was already right.

`VlcPlayerPlatformView.sizedVideoTrack()` now clears the cached array through reflection on the
private `Media.mNativeTracks` field whenever the cached track is unsized, and reads again. The
reflection is guarded and falls back to the old behaviour where the field does not exist. The same
fix corrects the video dimensions `getMediaInfo()` returns for these streams.

Covered by `example/integration_test/video_shape_test.dart`, which plays the MP4, MKV, MPEG-TS and
HLS fixtures and requires a landscape `displayVideoSize` from each. On an Android 17 emulator it
failed for MPEG-TS and HLS before the change and passes for all four after it.

### 10. Android: leaving a stalled stream no longer freezes the app

Switching source, or disposing the player, on a live stream whose download had stalled froze the
whole app until Android killed it as not responding. SkyStream's ANR report had the main thread 15 s
deep in `VlcPlayerPlatformView.dispose` -> `MediaPlayer.stop` -> `libvlc_media_player_stop` ->
`input_Close` -> `vlc_join`.

libVLC 3 leaves a stream synchronously. `libvlc_media_player_set_media` and `_stop` both stop the
input thread and wait for it to exit, holding the player's input lock throughout (VLC 3.0
`lib/media_player.c`), and every read of the player - time, length, tracks - takes that lock too.
A stalled segment read keeps the input thread alive for as long as it lasts. The plugin made these
calls on the Android main thread, which Flutter's UI thread is merged into, so moving `set_media`
alone to a worker would not have helped: the next snapshot read would have blocked on the lock.

So a player that has had a source is not handed another. `setSource` and `stop` swap in a fresh
`MediaPlayer` on the same `LibVLC` instance, give it views of its own (section 29), carry over the
per-player settings (volume, rate), and stop and release the old one on a background thread;
`dispose` does everything that waits on libVLC off the main thread, in the order it always had, and
each player's views go once it has stopped. Events and vout callbacks from a replaced player are dropped by identity,
since libVLC delivers them as runnables that can still arrive after the swap. `stop` reloads the same
source onto the fresh player, so `play()` after `stop()` still replays it.

Covered by `example/integration_test/stalled_stream_teardown_test.dart`, which serves a live HLS
playlist whose segment stalls (from its own isolate, which a frozen main thread cannot stop) and
times switching away and leaving. On an Android 17 emulator both took 21.7 s before the change, and
both finish in under two seconds after it, with the new source playing.

### 11. New: `setDurationCap`, for HLS lengths libVLC overstates

libVLC reports an HLS master's length as that of the longest playlist it has loaded, alternative
renditions included, and it loads a rendition's playlist whether or not it is selected
(`modules/demux/hls/playlist/Parser.cpp`: every `EXT-X-MEDIA` with a `URI` becomes a representation,
and `parseSegments` raises the playlist's duration to each one's total). NetMirror wraps each
subtitle file as a playlist of one segment claiming 99,999 seconds, so its episodes read 27:46:39
on every platform. The seek bar was useless, and a host that judges an ending by position against
length saw every real ending as a stream dying short.

libVLC has no option to leave renditions out of the length, and the engine exposes no per-rendition
length to read instead. So the controller takes one from the host: `setDurationCap(Duration?)`
publishes the smaller of libVLC's report and the cap from then on, until the next media. It only
ever shortens, leaves an unknown length unknown, and is applied in Dart, so every backend gets it.
SkyStream measures the video's own playlist and passes that.

Covered by `test/vlc_duration_cap_test.dart`, and on a real engine by
`example/integration_test/hls_rendition_length_test.dart`, which serves a 20 s stream with and
without a 99,999 s subtitle rendition. On an Android 17 emulator libVLC reports 0:00:20 and
27:46:39, and the capped controller holds 0:00:20 while the engine goes on reporting 27:46:39.

### 12. Android: the fit reaches libVLC as a crop or an aspect ratio

On Android's platform view the fit was libvlc-android's `VideoHelper.setVideoScale`, which resizes
the view from a size report only its opaque `android_display` output sends. Hardware-decoded video
runs on the `gles2` output instead - `android_display` will not open on an opaque MediaCodec surface
with no subtitle surface to blend into - so Stretch and Zoom did nothing to it at all.

The widget now works out what its fit needs at its own size - `VlcVideoGeometry` (internal): Stretch
is an aspect ratio of the view's shape, Zoom a crop to it, Original a pixel region - and the
controller sends it with `setVideoGeometry`. Android applies the aspect ratio through
`MediaPlayer.setAspectRatio`, which `gles2` honours, subtitles included. libvlc-android 3.x has no
Java crop, so `src/main/cpp/vlc_player_geometry.c` - a JNI shim built with the NDK the host pins -
resolves `libvlc_video_set_crop_geometry` from the `libvlc.so` the AAR has already loaded and calls
it with the player's native pointer (`VLCObject.getInstance()` is the `libvlc_media_player_t*`
itself). `gles2` applies a crop in the core but does not draw it, so Zoom on hardware-decoded video
still shows the whole picture; what it no longer does is cut the subtitles off.

Only Android's platform view is told: every other renderer hands Flutter a whole picture to fit, and
a crop from libVLC as well would apply the fit twice. Covered by `test/vlc_video_geometry_test.dart`
and `test/vlc_video_geometry_widget_test.dart`.

### 13. Darwin: subtitles inside the video show under VideoToolbox

Every subtitle track inside a video vanished on the texture renderer whenever VideoToolbox decoded
it - which on Darwin is always. vmem cannot draw subpictures, so libVLC 3 blends them into the
picture, and when the output buffer is no bigger than the decoder's picture it blends EARLY, into the
decoder's own format (`src/video_output/video_output.c`, `ThreadDisplayRenderPicture`). A
VideoToolbox picture is an opaque `CVPixelBuffer` the blender cannot write, so the blend failed and
the subtitle was dropped. A filter in the chain cannot help: the chain converts back to the decoder's
format at its end.

`VlcTextureRenderer.mm` now asks for a buffer two rows taller than a VideoToolbox picture
(`kSubtitleRows`). That moves the blend LATE, onto the converted picture in our NV12, which it can
write. libVLC scales the picture to the buffer on the way - on macOS on the GPU, through
`VTPixelTransferSession` (`modules/video_chroma/cvpx.c`, CVPX to CVPX), and on iOS, whose
MobileVLCKit has no such converter, with swscale, set to fast bilinear for the texture player
(`--swscale-mode=0`, present in MobileVLCKit 3.7.3). The whole buffer is then picture, so the sink
reports no coded size and Flutter shows all of it at the picture's own size, squeezing the two rows
back out. Software-decoded pictures blend fine early and are left exactly as they were.

Checked on macOS with an MKV carrying a subtitle track: nothing drawn before, the line drawn after,
picture unchanged.

---

### 14. New: `pendingSeekTarget`, the seek on its way

libVLC reports the position it left while a seek repositions the demuxer and refills the buffer -
seconds, on a slow network file - so a scrubber drawn from `VlcPlayerValue.position` sprang back to
where the viewer had been and jumped forward once the stream caught up. Media3 masks a seek's
position the moment it is asked for, and browsers move a media element's `currentTime` at the same
moment.

`VlcPlayerController.pendingSeekTarget` publishes the target from `seekTo` until the engine's
published position arrives at it (a little short counts: seeks land on a keyframe or a segment
boundary) or goes past it in the seek's direction; until the engine can no longer get there
(stopped, ended, failed, new media); or until playback carries on elsewhere for a dozen reports in a
row, which is an engine that ignored the seek. `VlcPlayerValue.position` stays the engine's own, so a
resume point or a relative step never counts from a place playback did not reach; hosts show the
target in their scrubber and clock. Covered by `test/vlc_player_seek_position_test.dart`.

### 15. New: `playbackClock`, where playback is between reports

A host drawing subtitle lines itself needs the position between the engine's reports, and the reports
are sparse and rough: libVLC 3 updates its time at most every 250 ms and not at all while paused,
Windows and Linux poll it every 500 ms, an HLS stream's time is a one-second staircase running up to
a second behind (measured on 3.0.24: it wobbles back 1-31 ms more than thirty times a minute, and
once reported 6.9 s behind straight after a seek), and VLCKit's cached time does not move on a seek.
SkyStream's own clock, re-anchored to every report and run on through pauses, blinked lines about
twenty times a minute on HLS.

`VlcPlayerController.playbackClock` is one clock for every platform, fed every native snapshot ahead
of the event throttle. It runs on from the freshest report at the playback speed, counting only
time spent playing; takes a report less than 1.5 s behind it for a stale one; believes a jump back
further than that only when the next report agrees; and runs on at most a second past the last
report. It moves back only where the controller says playback did: a seek, which it shows at once
and holds until the engine lands, new media, or the engine stopping or failing. After a start, a
resume, a seek landing, a speed change or a stall, the first report that moves replaces its guess
while the position it shows holds. `timeUntil` tells a reader when to look next.

The 1.5 s is wall time, as the lag it allows for is, so at a faster speed it covers more of the
media. And when every report for two seconds has trailed the clock by more than 300 ms of
playing - a stale report taken as fresh, a time that went back with no seek, a silent freeze - the
latest report replaces its anchor as well, and the position it shows holds until playback catches
up. An HLS staircase, stepping up to where playback is about every 1.13 s, never does that.

Covered by `test/vlc_playback_clock_test.dart`, and in the app by real libVLC time traces replayed
through the controller and the subtitle view (`test/features/player/side_car_replay_test.dart`).

### 16. New: `VlcAdaptiveLogic.predictive`, and the default named right

`VlcAdaptiveLogic` offered `rate`, `lowest` and `highest`, and its comments called `rate` libVLC's
default. Unset, libVLC 3.0.24 uses `nearoptimal` (BOLA), which starts on the lowest rendition:
`LogicType::Default` falls through to `NearOptimal` in `PlaylistManager.cpp`.

The enum gains `predictive`, which SkyStream's HLS Auto uses. It plays the highest rendition allowed
for three segments, then follows its buffer against libVLC's fixed 12 s stable target: up above
80 %, held above 50 %, down below (`PredictiveAdaptationLogic.cpp`, `BufferingLogic.cpp`). Measured
on a 3.5 Mbit/s link: 1 stall in 90 s, against 6 for `highest`.

The value is in all four builds the app ships, checked as section 8 describes on 2026-10-13
(`libvlc-all:3.7.7`, MobileVLCKit and VLCKit 3.7.x, the 3.0.24 Windows core). Covered by
`test/vlc_player_config_test.dart`.

### 17. A seek the engine carries on without is sent once more

`pendingSeekTarget` (section 14) gave up on a seek after a dozen published positions in a row moved
without arriving, taking it as one the engine ignored. libVLC 3 has been seen doing exactly that
with HLS: in the app, a seek to 3 min made 2 s into a stream was never taken on four of six
platforms, while the server showed segments fetched in order from the start (SkyStream's QoE
baselines, 2026-10-13). The controller now sends the seek once more from where playback is, and
gives the target up only after a second dozen. Covered by `test/vlc_player_seek_position_test.dart`
and `test/vlc_playback_clock_test.dart`.

Why libVLC drops them, from its own log: an adaptive stream with a track restarting answers a seek
"not seekable", and `INPUT_CONTROL_SET_TIME ... failed or not possible` follows with no event. An
HLS WebVTT track restarts at every segment and as it is switched on, which the app does at the first
picture. And the drop went unseen because every backend reports the time it was just given straight
after a seek (VLCKit as it is set): that echo, repeated while the refused seek's flush refills, read
as the landing. So for a step of more than 3 s, a report at exactly the time sent lands nothing
until the engine has reported somewhere else after it; the clock still starts from the echo, and a
seek sent once more puts it back at the target. A shorter step lands on the echo as before, since the
engine's next report couldn't tell a refusal from playback running on from the target.

### 18. New: the live window, and seeking in it

For a live HLS or DASH stream, libVLC 3's adaptive module reports the window the server still lists
as the length, the place in it as `libvlc_media_player_get_position`'s fraction, and a time in the
stream's own timeline rather than from zero (3.0.24 `PlaylistManager.cpp`). Every snapshot now
carries the fraction (`VlcPlayerValue.positionFraction`), and `seekToWindowFraction` seeks within
the window through `libvlc_media_player_set_position` on all five backends (method
`seekToFraction`). The controller turns a window seek into the position it means, so
`pendingSeekTarget`, the landing check, the merge window and the re-send (section 17) treat it like
any seek, and sends the engine the fraction, worked out again from the latest reading. Covered by
`test/vlc_player_seek_position_test.dart` and `test/vlc_player_value_test.dart`.

For live HLS, 3.0.24's fraction is only right at the join. The stream's time is counted from where
it was joined, but the window is measured from the start of the playlist libVLC last read, which every
refresh moves on: so `get_position` is the time over the window's length, running ahead of the
window as it moves on, and 0 once past 1, while `set_position` lands in the window as it is now
(SkyStream's harness, 24 s and 2-minute windows, seeks made well past the first window, 2026-10-13).
The host now says a media is live (`VlcMediaSource.isLive`), and for such media whose first reading
is the time over the length, the controller works the place out itself: the live edge runs on with
the clock from the window's length at the join, and the window starts its current length before
that. A full window then moves on as fast as the clock, and one still filling up keeps its start.
Every reading in the harness agreed within a second; taking every window to move put a seek on a
filling playlist 9.5 s off. A window counted in its own timeline (DASH's segments carry
their own times) is taken as libVLC says. `set_time` is no help here: it lands at that time counted
from the current window's start. After a seek in it, libVLC's time reads 0 for half a second
or so while it finds the stream again; a report of 0 is not taken as a landing for a target more
than 3 s from the start, where it would read as gone past a step back's target.

### 19. New: `keepPicture`, a reopen that keeps the picture

`setMedia(source, keepPicture: true)` asks the output to keep showing the current picture until the new media plays
from where it was asked to start. libVLC 3 shows a new media's first decoded picture at once: for a media given a
`:start-time`, that is the picture at 0, decoded before the start is sought (3.0 `input.c` pushes the start as a seek
that the main loop handles after its first demux, and `decoder.c` forces the first picture onto the screen while the
buffer fills). On a slow link the film's opening then showed for as long as the seek took: 7 s on the iOS simulator and
9 s on the Android emulator at 1.5 Mbit/s (SkyStream's reopen spike, 2026-10-14). The output kept its last picture until
then on every platform measured; it was the first new one that was wrong.

The `setSource` call carries `keepPicture`; backends that can hold report `pictureHeld` on every snapshot - the shared
decision, section 30 - and `VlcPlayerValue.isPictureHeld` keeps the held picture's size while it is set. The hold ends at
the new media's first reported time - libVLC reports none while its buffer fills (`es_out.c`, `ES_OUT_SET_TIMES`) - and
a media that stops, ends or fails before then leaves it on until the next `setSource`. How each platform holds is in the
sections that follow.

A media that fails, ends or is stopped before it plays doesn't end a hold (section 30): the next media that keeps the
picture carries it on, and that media's frame 0 does not end it. A release that `stop` began, with no picture after it,
is still taken back by the next hold (the C++ sink and the Darwin renderer; covered by
`AHoldTakenAgainAfterALetGoWithNoPictureStaysUp` and `example/integration_test/keep_picture_test.dart`'s case after a
failed media). SkyStream's whole-part review of P1 Part 2 found the case (2026-10-15): every attempt that fails during an
outage would have spoiled the hold of the one that works.

### 20. A refused seek is sent again when libVLC's log says so

Section 17 sends a seek again after a dozen moves without landing. Where a backend can read libVLC's log, it counts
`INPUT_CONTROL_SET_TIME ... failed or not possible` lines and reports `seekRefusals` and `seekRefusedAt`; the controller
sends the seek again at once when the refused time is the one it sent, up to three times. Covered by
`test/vlc_player_seek_position_test.dart`. Which backends read the log is in their sections.

### 21. Windows/Linux: a player per source, events, and the plugin bank kept loaded

The shared core (`src/native/vlc_player_core.*`) no longer keeps one `libvlc_media_player` for its life.
- **A fresh player per source.** Every source after the first gets a fresh one on the same instance, wired to the same
  pixel sink, with the old one's volume, rate, delays and subtitle look. The old player's events are detached on the
  calling thread, and it is stopped and released on a thread of its own, after any reader that copied it has finished.
  `Stop` swaps the same way and leaves the source loaded; `Dispose` hands the player to that thread too. libVLC 3's
  `set_media` and `stop` join the input thread, and an adaptive stream's segment download runs on threads whose reads
  the input's stop does not interrupt: a stalled segment kept the UI frozen for 130 s on Ubuntu (spec 3), and against a
  local server that stalls an HLS segment for 3 s the old core's switch took 5.5 s and its dispose 6.0 s. Nothing the
  platform thread calls waits on it now. This is Android's pattern (section 10).
- **Events.** The core subscribes to libVLC's events through libvlcpp's event manager (opening, buffering, playing,
  paused, stopped, end reached, error, time, length, seekable, vout, ES added/deleted/selected). A replaced player's are
  dropped by generation, and it tells its owner through a `ChangedCallback` that never calls back into libVLC. It
  reports `buffering` with a `bufferingProgress` while libVLC prebuffers: libVLC 3 itself says `playing` then, since
  `libvlc_Buffering` is never set. `isLive` no longer counts `buffering`, as on Android and Darwin.
- **`keepPicture`.** Through `VlcPictureHold` and the pixel sink's hold (section 19).
- **One sink, two outputs for a moment.** The old player's video output can still be writing the frame it locked when
  the new player's format reaches the sink, on that player's thread: a detach stops the next lock, not the one in
  flight. The sink retires its frame buffer at a format change instead of reallocating it, as it does the texture
  buffer (`AFrameInFlightKeepsItsBufferThroughAFormatChange`; under AddressSanitizer the old code wrote into freed
  memory). One frame of RGBA more for as long as a resolution lasts. Found by SkyStream's whole-part review of P1
  Part 2 (2026-10-15).
- **Refused seeks.** A log callback on the core's instance counts `INPUT_CONTROL_SET_TIME ... failed or not possible`
  (section 20), matching on the format string so no other message is formatted.
- **The plugin bank stays loaded.** The first core in the process makes one libVLC instance that is never released:
  libVLC 3 unloads its plugin bank with its last instance (spec 1.7).

Covered by the native suite (`test/native/vlc_player_core_test_suite.h`), including a local server that stalls an HLS
segment, which switching and disposing must not wait for.

The Windows and Linux wrappers no longer poll. A `VlcUpdatePump` (`src/native/vlc_update_pump.*`) sends a snapshot as soon
as the core reports a change, at most one per 100 ms while changes keep coming, and one a second regardless. The 500 ms
poll saw libVLC's one-second HLS time steps up to half a second late, which set off the controller's one-second stall
clock for a few milliseconds at segment boundaries on Windows. Linux's `Dispose` keeps its order (stop the updates,
dispose the core, unregister the texture, close the read path, free), and none of those steps waits on libVLC any more.

A libVLC 3 hazard the release thread must stay clear of: an instance's cleanup saves the configuration while holding
libVLC's configuration lock for reading, and takes it again (`config_AutoSaveConfigFile`, 3.0.24 `file.c`). With a
writer-preferring lock a writer queued between the two - a volume set that the audio output saves to the
configuration - deadlocks both. glibc's default lock and libVLC's own Windows lock let readers through, so this core's
platforms are not exposed; macOS's pthread lock prefers writers, and the native suite run there against VLCKit's libVLC
hung this way until it used `--aout=dummy`.

### 22. Windows: libVLC's plugin cache, made where it is used

VideoLAN's Windows archive has no `plugins.dat`, so libVLC loaded all 360 plugin DLLs when the first instance in a
process was made: 22.6-24.4 s on SkyStream's Windows VM (x64 emulated on ARM64). libVLC 3 trusts a cached entry only
when the DLL's modified time and size match exactly (3.0.24 `bank.c`), and ZIP files and Inno Setup both round times to
two seconds (and a ZIP restores them as local times), so a cache made in CI would be stale on users' machines. Instead:
- the bundle carries `vlc-cache-gen.exe`, and the installer runs it on the installed plugins (as VLC's own installer
  does) and removes `plugins.dat` on uninstall;
- the first player in a process makes the instance that keeps the plugin bank loaded (section 21) with
  `--reset-plugins-cache` when `plugins.dat` is missing or older than the executable or any plugin
  (`windows/vlc_plugin_cache.*`), so the portable build writes its own cache on its first launch. A time still to
  come counts for nothing there: a ZIP restores the build's clock reading in the user's time zone, so west of the CI's
  UTC the files are dated hours ahead, and no cache written in those hours could be newer (the installer sets
  `TimeStampsInUTC=yes`, which keeps the real times);
- CI checks that `vlc-cache-gen.exe` builds a cache from the bundle, then deletes it;
- the build copies the runtime's folders with `copy_directory_if_different` (CMake 3.26 and later): copying them
  whole gave every plugin DLL a new time on each build, so a debug launch never had a valid cache;
- `VLC_PLUGIN_PATH` is no longer set: libVLC already scans the `plugins` folder beside `libvlccore.dll`
  (`AllocateAllPlugins`, `config_GetLibDir`), and the variable pointed at the same folder, so every plugin was scanned
  and registered twice.

Most of the 23 s was the first load of 360 freshly written DLLs, not libVLC's walk: with the DLLs loaded before, a
first instance that walked them all and wrote the cache took 1.7 s, and one that read the cache 1.3 s. A valid cache
means only the plugins a media needs are loaded. Measured on the VM: the first open after launch 22.6-24.4 s before,
1.28-1.33 s after (also on the first launch after an installer-style `vlc-cache-gen` run, which itself took 21.2 s on
the freshly written files); later opens in the same process 0.75-2.4 s before, 0.12-0.28 s after.

### 23. iOS and macOS: the player is released off the main thread

VLCKit 3.7.4 stops and changes media asynchronously, but `-[VLCMediaPlayer dealloc]` releases the libVLC player, which
waits for the stream the asynchronous stop began stopping (VLCKit's patch 0023). The plugin dropped its last reference
on main, and VLCKit's own main-queue blocks could too: leaving a stalled HLS stream froze iOS for 130.5 s (SkyStream's
baseline, 2026-10-13), and the package's stalled-stream test hung for over eleven minutes on the iOS simulator with the
main thread in `-[VLCMediaPlayer dealloc]` -> `libvlc_media_player_destroy` -> `pthread_join`, reached from a
main-queue block's release. `dispose()` now stops the player, detaches the texture renderer, and hands the player to
`releaseLater`. That keeps it past the two main-queue turns VLCKit holds it for after a stop (its Stopped handler, and
on iOS the idle-timer block that handler queues), then lets it go on a concurrent queue. On iOS the audio session is
given up after that release, not while the stream still stops. Leaving the stalled stream now takes 70 ms on the iOS
simulator and 65 ms on macOS (which left in under 2 s before too). Covered by `test/native_teardown_order_test.dart`
and `example/integration_test/stalled_stream_teardown_test.dart`.

Players are made on libVLC instances kept for the process's life, one per set of options
(`VLCMediaPlayer(library:)`), not with `VLCMediaPlayer(options:)`, which gives each player an instance of its own that
its release ends. Ending an instance saves libVLC's configuration while holding the configuration lock for reading,
taken twice (3.0.24 `file.c`, `config_AutoSaveConfigFile`); macOS's audio output writes the configuration at every
start and close (`auhal.c`), and Darwin's lock makes a reader wait behind a queued writer, so an instance ending off
the main thread beside such a write would deadlock both, and then every thread that reads the configuration. The
native suite hit exactly this on macOS (section 21).

A source after the first gets a fresh player (`replacePlayer`), as on Android, Windows and Linux. VLCKit's patch 0023
starts a media set with `set_media_async` only once the old input has closed (`play()` sets `open_next` while
`close_input` is pending; the worker thread opens the new input after `input_Close`), so switching away from a stalled
HLS stream started the new source only when the stall ended: the package's stalled-stream test timed out waiting for
it on the iOS simulator and on macOS. The fresh player is made on the same library, gets the old one's volume, rate and
subtitle look, and the texture renderer moves to it (`-attachToMediaPlayer:`: the same texture and sink, the old
player's late callbacks made no-ops); the old one is stopped and handed to `releaseLater`. The new source now plays at
once: switching takes 8 ms on the iOS simulator and 20 ms on macOS, with the test's new source playing.

### 24. iOS and macOS: libVLC's own events, the held picture, the refused-seek log

`VlcPlayerEvents` (`darwin/VlcPlayerEvents.*`) attaches to the player's raw libVLC pointer: Opening, Buffering,
TimeChanged, Stopped, EndReached, EncounteredError, ESDeleted and ESSelected, which VLCKit 3.7.4's delegate doesn't
carry or turns into a state without a percentage. It moves to the fresh player of each new source (section 23), keeping
a hold armed for it. Snapshots report `buffering` with a `bufferingProgress` while libVLC prebuffers, as every backend
now does: VLCKit said `playing` through the buffer fill after a seek, and the controller's clock ran on over a frozen
picture (an MP4 seek on macOS looked resumed after 1.0 s; the position moved at 2.7 s). The texture renderer's sink
holds a retained copy of the picture on screen for `keepPicture` (section 19), drops libVLC's pictures meanwhile, and
lets go at the first picture finished after the new media's first time report. It holds the same way across every change
of player, as a bridge, since the new video output's `Configure` drops the picture it was showing; `pictureHeld` reports
only the `keepPicture` hold, `VlcPlayerEvents`'s decision, and the snapshot that ends one goes out at once rather than
at VLCKit's next time callback (section 30); the package's keep-picture test passes on the iOS simulator and macOS (no
capture of the film's opening, against 26 of 29 before on iOS). The refused-seek warning is read by a raw
`libvlc_log_set` callback (section 20), installed once per libVLC instance the plugin keeps (section 23) and reported to
every player on it: libVLC keeps one log callback per instance, and the controller matches the refused time against its
own seek. VLCKit's loggers format every message before checking its level, and they are used only under `--verbose=2`,
where this callback stands aside. A library made from registration to warm libVLC up was tried and taken out: the first
open after launch was no faster beyond run-to-run noise on either platform (VLCKit links its plugins in).

### 25. Android: the held picture, the first fill's percentage, and the wait for the surface

libVLC draws into the `TextureView` of each player's own `VLCVideoLayout` (section 29). For `keepPicture` (section 19)
the plugin copies the layout on show (`TextureView.getBitmap`, at most 1920 wide) just before the player swap and lays
the copy over every layout. The copy is taken away 120 ms after the new player's first time report, so the first frame
at the start position is in the view first. A media that fails, ends or is stopped before that keeps the copy up
(section 30), and a hold within those 120 ms keeps the copy still up rather than copying the view again
(`VlcHeldOverlay.kt`). `pictureHeld` is the decision's, not the copy's. The decision is `VlcPictureHold.kt`, the twin of
`vlc_picture_hold.h`. Buffering events before the player plays now send a snapshot too, so the first fill's percentage
reaches Dart. And the plugin reports how long libvlc-android held playback back for the view's surface
(`videoSurfaceWaitMs`): `MediaPlayer.play()` starts only once the attached views have a surface (3.7.7
`AWindow.areSurfacesWaiting`), and a `TextureView` gets one at its first draw. The re-send of the surface size the
design first called for is not needed: `attachViews` already registers a layout listener that does it (`VideoHelper`).
A play that didn't wait reports 0, so Dart, which keeps a value whose key is absent, no longer shows an earlier open's
wait (P1 Part 4).
The package's keep-picture test passes on the phone and TV emulators (no capture of the film's opening, against 22 of 26
before on the phone).

### 26. Android: libVLC's font database, built before the first video

libVLC's freetype text renderer has fontconfig build its font database the first time a video output is made in a
process, on the input thread and before the decoder gets its output, so nothing plays meanwhile. With no cache that is a
scan of every system font: 11.5 s on the phone emulator and 12.7 s on the TV emulator, for the first video after an
install (libVLC's `-vv` log: "spu text: Building font databases." … "Took N microseconds"). fontconfig then keeps a cache
in libvlc-android's home (`app_vlc/.cache/fontconfig`, about 0.8 MB), and later builds take under 4 ms. `VlcFontWarmup`
builds it when the plugin registers, once per process and only while there is no cache: on a background thread it makes
a `LibVLC` (libvlcjni sets `HOME` to that home) and calls the `FcInitLoadConfigAndFonts` that libvlc.so carries and
exports (`src/main/cpp/vlc_player_fonts.c`), the call libVLC's freetype makes. On fresh installs the build took 12.6 s on
the phone emulator and 13.4 s on the TV emulator, in the background, and the first video's picture then came in 0.41 s
and 0.37 s (11.8 s and 12.9 s before). A video opened while the build still runs waits for it at a start gate
(`VlcStartGate`, `VlcPlayRequests`; a pause, a stop or a newer request drops a waiting play): started alongside, its own
scan slowed both, and in SkyStream's QoE suite the first picture of a fresh install took 32 s (the build 35 s), past the
player screen's 30 s first-frame deadline, whose reopen stranded that player inside its scan. The gate opens when the
build ends, or after 60 s at most. An OS update that changes the system fonts leaves a stale cache, which libVLC
rebuilds at the next first video, as before.

### 27. A texture player whose create answers late is disposed

`attachTexturePlayer` counts attaches and detaches. A native player whose `create` answers after its widget was replaced or
detached is disposed instead of attached over the newer one. SkyStream mounts a new `VlcPlayer` when media has waited 30 s for
a native player that never came (once in about sixty iOS opens, 2026-10-13); without this, a late answer to the first create
would have taken the controller back from the second. Covered by `test/vlc_player_controller_test.dart`.

The widget that asked for that create is gone by the time it answers, and its own detach used to say "whatever is
attached", which took the replacement's player with it. The texture path now names the texture its create handed back
(`detach(textureId:)`), and a detach naming another texture does nothing (`test/vlc_player_widget_test.dart`).

`stop()` before a native player has attached no longer throws: the queued media then opens stopped when one attaches.
SkyStream's failed screen calls it so media still waiting for a player cannot start behind it
(`test/vlc_player_controller_test.dart`).

### 28. A seek gives the stall flag its first second, unless it goes nowhere new

`isStalled` rises when the position has not moved for `stallIndicatorDelay` while playback is expected. A seek to another
place now takes a raised flag down and starts that count again, so the first second after a committed seek shows no
spinner (SkyStream's spec 4). A seek to where playback already is, or to the target of a seek still on its way, leaves the
flag as it is: SkyStream's stall watchdog re-issues that to kick a stream that stopped, and the picture stays frozen
through it. Taking the flag down there split one 20 s stall into two, with the spinner gone for a second in between
(SkyStream's QoE suite, 2026-10-15). Covered by `test/vlc_player_stall_test.dart`.

## Known gaps, not yet addressed

- **Rendering path.** Android/iOS/macOS use `AndroidView`/`UiKitView`/
  `AppKitView` platform views; only Windows and Linux use a Flutter `Texture`.
  Platform views cost more on low-end Android TV hardware. Closing this means
  feeding a Flutter `SurfaceTextureEntry` to `IVLCVout.setVideoSurface` on
  Android; Apple needs `libvlc_video_set_callbacks` into a `CVPixelBuffer`.
  **Measure before building** — this is only worth it if it shows up.
- **No tvOS.** `ios/vlc_player.podspec` is `:ios, '13.0'` against `MobileVLCKit`.
  tvOS needs a separate target against `TVVLCKit`.
- **No DRM.** No ClearKey or Widevine surface. Content behind a licence server
  needs a different engine.
- **Windows fetches the VLC runtime at build time** from `download.videolan.org`
  (`windows/CMakeLists.txt`), so offline and sandboxed CI builds fail.
- **Linux requires system libVLC** (`pkg_check_modules(LIBVLC REQUIRED)`).
- **Android pulls `libvlc-all`** — every ABI, no splits. Filter in the host app.
- Upstream issue #1 (first frame jumps) and #7 (Swift Package Manager) are open
  and unaddressed here.

### 29. Android: every player draws into a view of its own

libVLC 3 draws a `VLCVideoLayout`'s `TextureView` through its OpenGL ES output: MediaCodec decodes into libvlc-android's
own SurfaceTexture, and the output draws that onto the view's, which it holds as an EGL window surface. Detaching a
player's views doesn't let it go at once. It asks for the video track to be turned off, which libVLC's input thread
does between reads, and the output then closes, or stays connected as the input resource's free vout (3.0
`src/input/resource.c`) until `stop()`'s `input_resource_Terminate`. An input thread stuck in a read does neither.
Every player used to share the one view. A new player whose output was asked for first (mostly 0.1-0.4 s into its
open, while the old stop took 0.03-0.87 s) couldn't connect: "cannot create EGL window surface", then "Opaque Vout request
failed", and libvlc-android's `:codec=mediacodec_ndk,all` decoded the whole media in software, its pictures failing
until the old output let go. On SkyStream's phone emulator that was 5 of 12 plain reopens and every 4K reopen, and
sound without a picture for as long as the old output held on (P1 Part 2's memory-4k run: for ever).

The platform view is now a container (`VlcRenderTarget.VideoLayout`) that makes a `VLCVideoLayout` for each player
(`VlcSurfaceHandover.kt` decides which shows):
- A new player's layout goes under the one on show. It comes to the front at the first of its first three frames that
  isn't black, or 120 ms after its first time report: an output's first frame can be its black clear. Looking at a
  frame copies it on the main thread (`TextureView.getBitmap`, 2-112 ms on the phone emulator, up to 0.24 s on the 4K
  TV one), so a dark opening waits for the time report. The held picture (section 25) stays over every layout.
- A replaced player keeps its views until its stop has returned, so its output keeps a live surface for as long as it
  holds one. Its video track goes at once, and its decoder with it.
- Its layout goes once it is released and a newer picture is up, from the main thread's queue: a view removed while
  the container draws (a `TextureView` callback) crashes its `dispatchDraw`.
- Each layout's SurfaceTexture outlives its view until its player has stopped (`VlcSurfaceKeeper.kt`). An output
  whose input is stuck in a read keeps drawing, and into a released SurfaceTexture that is `EGL_BAD_SURFACE` about 13
  times a second until its player stops, for ever if the stop never returns; on the emulator other players' video
  waited behind it. Flutter takes a platform view's view away before it disposes it, so the keeper is the view's
  listener from the attach, in front of libvlc-android's. A player whose stop never returns keeps its SurfaceTexture.
- While a player stops, libvlc-android doesn't hear that its view went (`VlcSurfaceKeeper.tellsLibVlc`). Its listener
  turns the video off at once, on the main thread, and `libvlc_video_set_track` waits for the input lock that
  `libvlc_media_player_stop` holds while it joins an input stuck in a read. Leaving a stream the player had switched
  away from held the app until that read gave up: 129 s on SkyStream's phone emulator, leaving during an HLS stall,
  and an ANR in its 403 failover row (P1 Part 3). The views go once the stop has returned, from the main thread.
- For the same lock, a replaced player's layout is held at its size (`pinSize`): libvlc-android's `VideoHelper` layout
  listener answers a resize of the container (a rotation, picture-in-picture) by calling `setAspectRatio` and
  `setScale` on the main thread when the player has no picture size yet, and only bounds that moved reach it.
- The texture target still shares one Flutter surface between players.

A test hook, `--vlc-player-release-delay-ms=N` in a player's options, holds every release back N ms
(`VlcReleaseDelay.kt`): stops return in a fraction of a second on the emulators, and the device test needs one that
doesn't.

Covered by `VlcSurfaceHandoverTest.kt`, `VlcSurfaceKeeperTest.kt`, `VlcReleaseDelayTest.kt`,
`example/integration_test/surface_handover_test.dart`, whose reopen and park cases fail on the shared view, and
`example/integration_test/stalled_stream_teardown_test.dart`'s leave after a switch, which waited out the stalled read
before `tellsLibVlc` (pinned in `test/native_teardown_order_test.dart`). Measured
on the emulators (SkyStream's P1 Part 3 research, 2026-10-15): hardware decoding kept in every reopen, the new picture
on screen 1.28-1.48 s after `setMedia` (1.25-1.65 s before, when hardware decoding survived), no EGL error, and no black
frame in a storm of 13 reopens.

### 30. `isPictureHeld` is the hold decision, the same on every platform

Part 2 reported each output's own state: the C++ pixel sink's hold, the Darwin renderer's, Android's overlay. They
disagreed, and a host recovering a stream over the held picture (SkyStream's P1 Part 3) needs one answer:
- **Darwin reported a hold at every source.** Its renderer holds across every change of player, asked or not: the new
  video output's `Configure` drops the picture the renderer was showing, and a nil `copyPixelBuffer` paints black. So
  `pictureHeld` was true after a failover or the next episode until that media's first picture, and Dart kept the old
  picture's size through the opening.
- **A media that failed, ended or was stopped before it played** left the C++ sink and the Darwin renderer holding,
  with a release pending that only a later media's picture could complete, while Android dropped its copy at once and
  showed what the failed media had drawn under it - the film's opening, if it had decoded its frame 0.
- **The hold's end reached Dart late:** on Windows and Linux the picture that ended it woke the texture but not the
  update pump, so the report waited for libVLC's next event or the 1 s heartbeat; on Darwin it waited for VLCKit's next
  time callback. The new picture was laid out at the old shape meanwhile.

Every backend now reports `VlcPictureHold`'s `held()` (`vlc_picture_hold.h`, and `VlcPictureHold.kt`), and the outputs
follow it:
- A hold starts only at a `setSource` with `keepPicture`, when the output has a picture of the media before, and carries
  on through further `keepPicture` sources.
- It ends at the current media's first time report after its Opening - in that report's own snapshot, which carries the
  new picture's size - or at once at a plain `setSource`, `stop` or dispose. The pixels follow a moment later: at the
  next picture libVLC finishes (C++, Darwin), or 120 ms on (Android).
- On Android and Darwin the first time report is libVLC's `PositionChanged`: libVLC sends a new time as
  `PositionChanged`, then `TimeChanged` (`lib/media_player.c`, `INPUT_EVENT_POSITION`). On Android a snapshot sent on
  the first with the hold still on was the first report that moved, still held, at the old picture's shape (Part 3's
  device runs, phone and TV). On Darwin VLCKit's own listeners come before the plugin's, and its `TimeChanged` one
  queues on main the time the next snapshot reads: a hold ended at `TimeChanged` could still be on when that snapshot
  went out, as the shape case below found in 1 of 32 macOS runs (Part 3's Task 3).
- A media that fails, ends or is stopped by libVLC before its first time report leaves the hold on: `OnMediaGone`
  changes nothing. The output keeps the held picture, Android's copy included, until the next `setSource` decides; a
  `play()` of the same media ends it at its first time report.
- Darwin's renderer still holds at every source, as a bridge; only a `keepPicture` hold is reported.
- Android keeps its copy's view until it is removed (`VlcHeldOverlay.kt`): a hold within the 120 ms after a release
  keeps that copy rather than copying the view again, which may by then show the newer media's picture at 0.

Covered by the hold suite (`AMediaGoingNeverEndsIt`, `AReopenAfterAFailureCarriesTheHoldOn`,
`APlainSourceAfterAFailureEndsIt`, `APlayAfterAFailureEndsItAtItsFirstTime`) and its Kotlin twin, the core suite
(`APlainSourceEndsTheReportedHoldAndBridgesThePicture`, `AHeldReopenThatFailsBeforeItPlaysKeepsTheHold`,
`TheHoldEndsInTheTimeReportsOwnSnapshotWithTheNewSize`, with test hooks for libVLC's Opening, time and media-gone
events), `VlcHeldOverlayTest.kt`, `test/native_picture_hold_test.dart` (the reports, and Android's and Darwin's first
time report, as source), `test/native/darwin_player_events_test.mm` (on real VLCKit players, a `TimeChanged` listener
ahead of the plugin's, where VLCKit's is, finds a held reopen's hold already ended at the new media's first move), and
three cases in `example/integration_test/keep_picture_test.dart`: a plain `setMedia` never reports a hold, a held media
that fails keeps reporting and showing the picture, and the first report that moves after a held reopen says not held at
the new picture's shape (`film_4x3.mp4` after the 16:9 `film.mp4`).

### 31. iOS and macOS: a picture in flight keeps its memory until its unlock

libVLC 3.0's vmem copies each picture into the planes its lock callback returned, then unlocks (`vmem.c`, `Prepare`);
`VlcVideoOutput::Detach` stops an output's next lock, not a copy already running. A player per source (section 23) puts
two players' outputs on the texture renderer for a moment, and the Darwin sink held the picture being filled by one
reference, which both of these dropped:
- the next player's output configures the sink, which tears its pool down, whatever the size;
- `dispose()` stops the player asynchronously and detaches the renderer in the same turn of the main thread, which tears
  it down too.

After a detach, or a format of another size, the locked planes were unmapped at once, and the old output's copy crashed
the app. At the same size the memory came back as the next player's first picture, and the old copy wrote into it. A
harness that drives the sink as two outputs do crashed 40 of 40 (SkyStream's P1 Part 3 research, 2026-10-15). A leave
during 2160p60 playback crashed the example app too: the copy faulted in `plane_CopyPixels` while the main thread
released the pool under `-detach`. It is rare with the picture on screen (2 of 541 leaves): a copy is in progress about
3 % of the time, and a picture Flutter has drawn stays mapped through its Metal textures. AddressSanitizer sees neither:
IOSurface memory has no shadow, and the copy runs inside VLCKit.

The lock now owns a reference to its picture until its unlock:
- `Acquire` leaves the pool's reference to the lock and retains another for `in_flight_`; `Release` always drops the
  lock's.
- `VlcFrameSink::orphan_release()` lets go of a picture whose unlock comes after `Detach`. `VlcVideoOutput` keeps it in
  its attachment, which outlives the sink, and calls it from a late unlock; the Darwin sink's unlocks the base address and
  drops the lock's reference. It is `nullptr` by default, so Windows and Linux are unchanged: their sink retires its
  buffers instead (section 21).
- `Configure`, `Cleanup`, `Teardown` and `Publish` still drop only the slot's reference.

Covered by `test/native/darwin_renderer_sink_test.mm`, which runs on the Mac against VLCKit's libVLC (SkyStream's
`darwin-sink.sh` runner): the renderer's translation unit, driven through the real `VlcVideoOutput` by the callbacks
libVLC stored on real players, in vmem's order. A picture locked before a detach, or before a format of another size,
stays mapped until its unlock and is freed by it; the next player's pictures never reuse a locked one; every picture is
freed once its output and the sink are done. And by `example/integration_test/dispose_stress_test.dart`: three
unpainted players changed from 1080p30 to 2160p60 and left during playback, 200 times, on macOS and the iOS simulator.

### 32. iOS and macOS: VLCKit's pause at the end and saved volume turned off; macOS retires players one at a time

VLCKit puts its own default options in front of every instance's (`VLCLibrary.m`, `_defaultOptions`). Every library the
plugins make (section 23) now gets `--no-play-and-pause` and `--no-volume-save` after the host's options, so they win:
- **`--play-and-pause`** starts VLCKit's macOS list ("We want every movie to pause instead of stopping at eof"), and
  libVLC's input then pauses at every end instead of ending (`input.c`, `MainLoop`). A finished film reported paused, not
  ended, and so did a lost connection: libVLC's HTTP access makes one attempt to resume a broken transfer, then reports an
  end of stream (`access/http/file.c`), and the film plays its buffer out first. A host saw a pause nobody asked for, and
  SkyStream's drop20-mp4 row stayed paused on macOS while iOS reopened (P1 Part 2). iOS's list has no such option.
- **`volume-save`** makes macOS's audio output write the volume into libVLC's configuration at every sound start and
  volume change (`auhal.c`, `VolumeSet`): on the main thread for the volume `replacePlayer` gives a fresh player, whose
  audio output exists from creation. VLCKit saves that configuration after every input close (its patches 0014 and 0023)
  under a read lock it takes twice (`config_AutoSaveConfigFile`), and Darwin's rwlock queues the second read behind a
  waiting writer: the two deadlock, and then every thread that reads the configuration, the main thread included. VLCKit's
  own `config_AutoSaveConfigFile` beside `config_PutInt` deadlocked 27 runs of 27. Nothing reads that configuration back:
  VLCKit leaves `ignore-config` on.
- One write stays: auhal's at an output's close (`auhal-audio-device`, unconditional), which a retired player's own
  thread makes right after its save (`media_player.c`, `worker_thread`). Two retired players closing at once deadlocked
  on it: three players changed and left together froze the example app in every run that didn't crash first (4 of 5),
  within 22 rounds, with the options above too. So the macOS plugin retires its players one at a time (`retire`): the
  old player pauses at once, and is stopped and let go once every player retired before it has gone, or has had 2 s to
  (a stalled stream can hold its close for minutes). iOS's audio output writes no configuration, and its plugin keeps
  stopping at once.

`volume-save` also made every new player start at the volume any player was last set to, which the desktop controls
start from. The macOS plugin now does that itself (`lastVolume`, given to every new player); iOS's audio output never
carried a volume.

Covered by `test/darwin_library_options_test.dart` (both plugins' line, the carry and `retire`, as source),
`test/native/darwin_library_options_test.cc` (the tail, read from the plugins' source, behind VLCKit's macOS defaults in
VLCKit's libVLC: `play-and-pause` off, and a volume set leaves the configuration alone),
`example/integration_test/player_defaults_test.dart` (a media played to its end reports ended, where macOS said paused;
and, on macOS, a new player starts at the volume the last one was set to) and
`example/integration_test/dispose_stress_test.dart` (three players retired together at every change and leave, 200
times, without a freeze). `retire` is pinned as source in `test/darwin_library_options_test.dart` and
`test/native_teardown_order_test.dart`.

### 33. What a recovery over a held picture needs: the held media's timeline, its start as the seek target, `pauseRequests`, the start gate

A host that recovers a stream over the held picture (section 30; SkyStream's P1 Part 3) keeps its controls usable
there, and tells a pause or a stop it asked for from one it did not:
- **A held media's timeline is the media before's until the hold ends.** While `pictureHeld` is true, a zero `duration`
  keeps the length before, an `isSeekable: false` keeps the answer before, and `isLive` keeps its value. A media still
  opening knows no length and says it cannot seek, and every backend's `isLive` is worked out from those two; a screen
  drawing its controls over the held picture lost its scrubber for the whole reopen.
- **An error no longer clears the video size.** The output keeps showing a picture after a failure - the held one, or
  what the failed media drew last - and a host laid out from the value drew it at no size while it offered a retry over
  it. Only `idle`, and `opening` without a hold, clear the size.
- **A change of `isPictureHeld` is published at once,** never held back by `eventThrottleInterval`. A held picture keeps
  its size, so the hold can be all a snapshot changes, and the hold's end is the report that lays the new picture out.
- **A held reopen's start is `pendingSeekTarget`** once `setSource` is answered, while the output holds: the engine
  reports 0 until the new media plays from its start, and a scrubber or a clock drawn from that jumped to the film's
  opening under a picture from minutes in. Every backend sends the new media's opening snapshot before it answers
  `setSource` (Windows and Linux in `SetSource`, Android before `result.success`, Darwin before `result(nil)`), so the
  published value already says whether the output holds. Darwin's event handler queued every event for a later turn of
  the main queue, so the answer reached Dart first and a host reading the hold after `await setMedia` saw none:
  SkyStream's recovery parked a failed source and gave its picture up (P1 Part 3's macOS outage rows). It now sends at
  once on the main thread, where every snapshot is made, and hops to main only from another thread. A start of 0, an
  output with nothing to hold, a plain `setMedia`, or a newer media or player since sets none. The start is not a seek:
  it went with the media, so it is never sent, never counted in `seekRequests`, and nothing waits for its echo or sends
  it again (the landing check, the refused-seek log). The playback clock already stands at the start. It goes when the
  published value's hold ends - libVLC's first time report, which only comes once playback runs from the start - or its
  state can no longer land (`idle`, `stopped`, `ended`, `error`). A `seekTo` replaces it with an ordinary seek from the
  start.
- **`pauseRequests`,** beside `seekRequests`, counts every `pause()` and `stop()`, a playlist's own stop, the pause the
  background policy sends, and an open the policy turns into a stopped one. The engine's snapshots say only `paused` or
  `stopped`, and a stop after a failure libVLC did not report as one looked the same as the viewer's.
- **`isStartGated`** is Android's `startGated`: true while a play waits at the font start gate (section 26), up to a
  minute with nothing wrong with the media. `VlcPlayRequests` says when a play starts and stops waiting, and the plugin
  sends a snapshot each time. A host watching for a stall waits it out.

Covered by `test/vlc_player_value_test.dart`, `test/vlc_player_event_pressure_test.dart`,
`test/vlc_player_pause_requests_test.dart`, `test/vlc_player_held_start_test.dart` (on the method-channel harness, whose
`setSource` sends the opening snapshot before it answers, as the backends do), `VlcPlayRequestsTest.kt`,
`test/native_picture_hold_test.dart` (Darwin's send, as source) and `example/integration_test/keep_picture_test.dart` (a
held reopen says so by the time `setMedia` returns).

### 34. An attach sends the queued media once

A host's `setMedia` can land while an attach is still getting the new player ready: the texture path's `create` has answered and the subtitle look is on its way, or the platform view's geometry is. `_setMedia` saw a player and sent `setSource`, and the attach then sent its queued media again, which every backend answers with a fresh player (sections 10, 21 and 23): the first player was retired mid-open. P1 Part 2's runs read it in up to 24 of 26 first opens on Windows, 23 of 66 on the phone emulator, 4 of 26 on macOS; Linux reads its memory without a channel call and showed none. The controller now counts the `setSource` calls it sends, and an attach skips its own when one went out since it set the view id. The look can then follow the media by one round trip; every backend applies a look live.

Covered by `test/vlc_attach_sends_media_once_test.dart`, beside `vlc_attach_race_test.dart`.

### 35. A background pause waits for the first `playing`

With the `pause` policy, a video that was still opening or refilling after a seek when the app left was never paused: the pause only acted on a player that said `playing`, and nothing looked again, so on Android it started with sound and no picture. A pause can't be sent then: libVLC 3.0.24's `libvlc_media_player_set_pause` stops an input that can't pause yet. The claim is now kept and sent at the first `playing`, as the policy's own pause, counted in `pauseRequests`; coming back first, or a play, pause, stop or new media, drops it. A media asked to play that hasn't played yet keeps the claim while the engine still says `idle` too: the Windows and Linux core reports idle for a moment after a play, before libVLC opens the input, and leaving then lost the pause (P1 Part 4's Windows run).

Covered by `test/vlc_background_policy_test.dart`'s group "a video not playing yet when the app leaves".

### 36. A clock that steps once a second gets 250 ms more before a stall

The stall flag rose after `stallIndicatorDelay` (1 s) without a moved snapshot. libVLC's HLS time, and the TV emulator's time events, move about once a second, so a step a little late raised it and the next step took it down: flashes of 1-177 ms over a playing picture on the TV, the phone, Windows and Linux (P1 Part 2's runs), which a heartbeat can't end. When the clock's last two moves were 900 ms or more apart, the deadline is now `stallIndicatorDelay` + 250 ms; a smooth clock keeps 1 s.

Covered by `test/vlc_player_stall_test.dart`'s group "a clock that moves in whole-second steps".

### 37. Windows and Linux send their snapshots in the order they were made

The Windows and Linux plugins make a snapshot on two threads, the update pump's and the platform thread's after a
command, and outside any lock, since libVLC's getters can take a while; each went out as it was finished. One the pump
began before a park's `SetSource` (P1 Part 3's recovery: the failed source again, not told to play, over a held
picture) could reach Dart after `SetSource`'s own "opening" with the hold: the failed player's "playing" (a starved
video plays its sound on) or "ended" (a false end), with no hold. SkyStream read that as the viewer playing the parked
media and reopened without the picture: the start-up view for 28.5 s of a 60 s drop and 62.5 s of a 2-minute outage
on Windows (P1 Part 3's Windows round). Linux delivers on its main loop, a command's snapshot at once and the pump's
queued (`g_main_context_invoke`), so one queued before a `SetSource` always ran after it.

`VlcPlayerCore::Snapshot()` now numbers each snapshot as it begins, before it reads anything (`VlcSnapshot::sequence`,
not part of `==`). `VlcSnapshotOrder` admits one only if none made after it has gone out, and keeps the old dedupe.
Windows admits under the lock it sends under. Linux admits where it delivers, on the main thread, in `SendEventOnMain`
(the order shared with the queued deliveries, which can outlive the player): admitted on the pump's thread, a queued
snapshot was taken before the command's own, which was then dropped as a repeat or as older, and `setSource` answered
before any snapshot said the picture was held (section 33; the P1 Part 4 review). Darwin makes every snapshot on its
main thread (section 33).

Admitted in order is still not delivered in order on Windows: a send from the update pump's thread reached Dart after
one the platform thread made later (queued to the platform thread, it seems, while the platform thread's own send goes
at once). P1 Part 4's Windows round measured it on a reopen: the new media's held "opening" (100) arrived before the
old media's "ended" (99), which let go of the picture and kept the start-up view up 7.5 s (`live-drop20`). So both
plugins send each snapshot's number in its event (`sequence`), and the controller applies none older than the last it
applied, counting from 0 again on each new native player (`_lastSequence`). Android and Darwin send no number, and
their events apply in the order they arrive.
Android sends on its main thread; whether a snapshot it makes elsewhere can arrive after a newer one is checked in P1
Part 5.

Covered by `test/native/vlc_snapshot_order_test_suite.h` (in both plugins' gtest runners),
`test/native/vlc_player_core_test_suite.h`'s "SnapshotsAreNumberedInTheOrderTheyAreMade",
`test/native_snapshot_order_test.dart` (both plugins' order and number, as source), and
`test/vlc_player_snapshot_order_test.dart` (the controller's order).

