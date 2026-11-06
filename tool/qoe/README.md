# The QoE suite's tools

The device suite (`integration_test/player/qoe_test.dart`) plays this folder's media through the real player screen
and prints one `QOE {json}` line per scenario. The spec is `docs/superpowers/specs/2026-10-13-p1-streaming-fixes-design.md`.

## Once: the media (about 10 minutes, on the Mac)

```bash
bash tool/qoe/mkmedia.sh "$PWD/tool/qoe/media"
```

`tool/qoe/media/` is git-ignored.

## Each run: the server, then the suite

| Target | Server bind | `QOE_HOST` |
|---|---|---|
| macOS, iOS simulator | 127.0.0.1 | 127.0.0.1 |
| Android emulators (on their cellular link) | 127.0.0.1 | 10.0.2.2 |
| Windows and Ubuntu VMs | 10.211.55.2 only | 10.211.55.2 |

```bash
python3 tool/qoe/server.py tool/qoe/media 18081 --bind 127.0.0.1 --log /tmp/qoe-server.csv &
python3 tool/qoe/server.py tool/qoe/media 18082 --bind 127.0.0.1 --log /tmp/qoe-server2.csv &
flutter test integration_test/player/qoe_test.dart -d <device> --dart-define=QOE_E2E=true --dart-define=QOE_HOST=127.0.0.1 > /tmp/qoe.log 2>&1
python3 tool/qoe/report.py macos=/tmp/qoe.log --compare tool/qoe/baselines.json
```

- `--dart-define=QOE_ONLY=name,name` runs some scenarios (the warm-up always runs).
- The live HLS scenarios start their own feed through `/_control/live`; the live TS channel at `/live.ts` needs nothing started.
- The second server (18082, `--dart-define=QOE_PORT2=…`) is the two-source rows' other host. Without it they
  report skipped.
- Stop the servers afterwards, and on a VM delete the test tree.

`tool/qoe/run.sh` does all of that for one device, and stops what it started. It refuses to start while something
else serves 18081 or 18082:

```bash
QOE_MIRROR=/path/to/a/scratch/mirror bash tool/qoe/run.sh macos my-run ''   # the whole suite on macOS
bash tool/qoe/run.sh android my-run live-hls-start,live-hls-jitter           # two scenarios on the phone emulator
QOE_AVD=Television_4K bash tool/qoe/run.sh android my-tv-run ''              # the TV emulator
```

Its log is `build/qoe/<name>.log`.

## The outage rows

An outage row cuts the link and reports what the viewer saw and what recovery did:

- `pictureFrozenMs`, the longest the decoder went without a new picture from the cut on, and `pictureMovingAtEnd`.
  The decoder's count is read once a second (`getMediaStats().decodedVideo`): libVLC shows a frozen picture again
  every 80 ms and counts it as displayed, so the position or the displayed count can't tell a frozen picture under
  running sound.
- `heldPictureSeen` (a reopen kept the last picture on screen) and `statusSeen` ("Reconnecting…" or "Waiting for
  network…" over the picture).
- From the screen's QoE log: `reopens`, `waits`, `checks`, `failovers`, `gaveUp`, and the failures' `signs`.
- `reopenAfterServerMs`: the reopen's first media request at the server, after the server answered again or
  recovery noticed the failure, whichever came later. A check's first kilobyte (`bytes=0-1023`) and HEADs don't
  count. `spotOffMs`: where the reopen started, against where the picture stopped.

`report.py` prints PASS only when a row keeps every rule of `outage_rule`, and otherwise the first rule it broke.
Each row's own expectations are in its `EXPECT`.

| Row | The cut | A pass shows |
|---|---|---|
| `drop20-mp4`, `drop20-hls` | every connection dropped for 20 s | the reopen within 2.5 s of the server answering again, where the picture stopped, with the picture kept |
| `stall20-hls` | 20 s with nothing sent | the picture back within the stall and 4 s |
| `drop60-mp4`, `drop60-hls` | dropped for 60 s | a wait with "Reconnecting…" over the picture once the buffer runs out |
| `outage120-hls` | dropped for 2 minutes | the same, and no source used up |
| `offline-120` | the phone emulator off its network for 2 minutes | "Waiting for network…", then playback resumes by itself |
| `gone403-2src` | source A answers 403 for 150 s | a failover to B, on the second server, at once |
| `busy503-ra` | 503 with `Retry-After: 4`, until recovery has checked twice | checks 4 s apart, no failover, a reopen once it answers |
| `hostdown-2src` | A dropped for 2 minutes while B answers | a failover to B 28–40 s after A's first unanswered check |
| `live-drop20` | a live HLS feed dropped for 20 s | a live reconnect over the kept picture |

`offline-120` runs on the Android phone emulator only. `run.sh` hands the server the emulator's serial
(`QOE_ADB_SERIAL`), and `/_control/offline?secs=S` turns the device's mobile data and Wi-Fi off a second after it
answers (so the answer gets through), then back on after S. A television has no cellular link to turn off, and a
Mac, a simulator or a VM shares its network with the server: there the row reports skipped.

## The real torrent

Three rows play WebTorrent's Sintel (Blender Foundation, CC BY 3.0) from its public swarm through the app's
TorrServer. They run only when named, as they need the internet. Each reports the first frame and when the peer
line showed before it, the buffer settings the server's start wrote (`torrent`, from the QoE log) and what
TorrServer reads back (`readBack`, `cacheCapacity`), the peers at the first frame and a minute later, stalls, three
seeks, memory and the leave.

| Row | What it plays | Expected |
|---|---|---|
| `torrent-sintel` | Sintel under a 1080p label | `applied`: 256 MB, 75 % read-ahead (`unchanged` on a test identity whose TorrServer already holds them) |
| `torrent-sintel-again` | the same again: TorrServer kept the settings | `unchanged`, nothing written |
| `torrent-sintel-720p` | under a 720p label | `applied`: 128 MB, 75 % |

```bash
QOE_MIRROR=/path/to/a/scratch/mirror bash tool/qoe/run.sh macos my-torrent-run torrent-sintel,torrent-sintel-again,torrent-sintel-720p
```

## Tests

```bash
python3 -B -m unittest discover -s tool/qoe                     # report.py's rule, server.py's control endpoint
flutter test test/integration_support/qoe_measures_test.dart    # the suite's outage measures
```
