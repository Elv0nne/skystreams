/// The QoE suite (spec section 7.2): plays `tool/qoe`'s media through the
/// real player screen, on the scenario server's link, and prints one
/// `QOE {json}` line per scenario for `tool/qoe/report.py`.
///
/// ```
/// flutter test integration_test/player/qoe_test.dart -d DEVICE \
///   --dart-define=QOE_E2E=true --dart-define=QOE_HOST=127.0.0.1 \
///   [--dart-define=QOE_PORT=18081] [--dart-define=QOE_PORT2=18082] \
///   [--dart-define=QOE_ONLY=a,b] \
///   [--dart-define=QOE_LIVE_DELAYS=15000,6000,8000,10000]
/// ```
///
/// `tool/qoe/README.md` has each platform's server address, and the profile
/// run the start-up scenarios are judged on.
// The printed lines are the report.
// ignore_for_file: avoid_print
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_torrent_server/flutter_torrent_server.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/router/app_router.dart';
import 'package:skystream/features/player/domain/live_window.dart';
import 'package:skystream/features/player/domain/media_options.dart';
import 'package:skystream/features/player/domain/qoe_log.dart';
import 'package:skystream/features/player/presentation/player_debug_flags.dart';
import 'package:skystream/features/player/presentation/vlc/ended_card.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_row.dart';
import 'package:skystream/features/player/presentation/vlc/player_startup_view.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';
import 'package:window_manager/window_manager.dart';

import '../cloudstream/support.dart';
import 'qoe_measures.dart';

const _run = bool.fromEnvironment('QOE_E2E');
const _host = String.fromEnvironment('QOE_HOST', defaultValue: '127.0.0.1');
const _port = int.fromEnvironment('QOE_PORT', defaultValue: 18081);

/// The second scenario server: the two-source rows' other host, which
/// `run.sh` starts beside the first.
const _port2 = int.fromEnvironment('QOE_PORT2', defaultValue: 18082);
const _only = String.fromEnvironment('QOE_ONLY');

/// The live delays the live start and jitter scenarios run at (spec 1.9), in
/// milliseconds: each runs once per delay, named `<scenario>@<ms>`. Unset,
/// each runs once, at the app's own.
const _liveDelays = String.fromEnvironment('QOE_LIVE_DELAYS');

/// The player, whether or not it is on stage yet: the screen may build it
/// before the first picture.
final _player = find.byType(VlcPlayer, skipOffstage: false);

/// Every scenario plays its own address, so none resumes where an earlier
/// one left off: history is kept per address.
String _tag = 'none';

String _url(String path) => path.startsWith('_control/')
    ? 'http://$_host:$_port/$path'
    : 'http://$_host:$_port/$path?qoe=$_tag';

/// The scenario server's clock minus this device's, from the last control
/// call. An emulator's or a VM's clock can be seconds off the Mac's, and the
/// live feed's program dates and the server's request times are the Mac's.
int _serverClockOffsetMs = 0;

/// Changes the link of the server on [port] from now on (reset, rate, stall,
/// drop, schedule, status), the live feed (live, live-stop), or the device's
/// network (offline), and reads the server's clock. Returns the server's
/// answer: `epochMs` is its clock when the change took.
Future<Map<String, Object?>> _control(
  WidgetTester tester,
  String cmd, [
  Map<String, String> query = const {},
  int port = _port,
]) async {
  final answer = await tester.runAsync(() async {
    final uri = Uri.parse('http://$_host:$port/_control/$cmd')
        .replace(queryParameters: query.isEmpty ? null : query);
    final sent = DateTime.now().millisecondsSinceEpoch;
    final response = await http.get(uri).timeout(const Duration(seconds: 5));
    final back = DateTime.now().millisecondsSinceEpoch;
    final answer = jsonDecode(response.body);
    if (answer is! Map<String, Object?>) return const <String, Object?>{};
    if (answer['epochMs'] case final num epochMs) {
      _serverClockOffsetMs = epochMs.round() - (sent + back) ~/ 2;
    }
    return answer;
  });
  return answer ?? const <String, Object?>{};
}

/// A text file the scenario server serves, or empty when it has none yet.
Future<String> _fetch(WidgetTester tester, String path) async {
  final body = await tester.runAsync(() async {
    final response = await http
        .get(Uri.parse('http://$_host:$_port/$path'))
        .timeout(const Duration(seconds: 5));
    return response.statusCode == 200 ? response.body : '';
  });
  return body ?? '';
}

/// The paths the server was asked for since [deviceEpochMs], a time on this
/// device's clock, oldest first.
Future<List<String>> _requestsSince(
  WidgetTester tester,
  int deviceEpochMs,
) async {
  final rows = await tester.runAsync(() async {
    final uri = Uri.parse(_url('_control/requests')).replace(
      queryParameters: {'since': '${deviceEpochMs + _serverClockOffsetMs}'},
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 5));
    return jsonDecode(response.body);
  });
  return [
    if (rows is List)
      for (final row in rows)
        if (row is Map) '${row['path']}',
  ];
}

/// Every request the server answered since [serverEpochMs], a time on its
/// own clock, with its method, status and range; null when the server's log
/// could not be read in three tries of 10 s. One 5 s read timed out at the
/// end of a Windows outage row, and the row was scored on no requests.
Future<List<ServedRequest>?> _servedSince(
  WidgetTester tester,
  int serverEpochMs,
) async {
  for (var attempt = 0; attempt < 3; attempt += 1) {
    final rows = await tester.runAsync(() async {
      try {
        final uri = Uri.parse(_url('_control/requests'))
            .replace(queryParameters: {'since': '$serverEpochMs'});
        final response = await http
            .get(uri)
            .timeout(const Duration(seconds: 10));
        return jsonDecode(response.body);
      } on Object catch (error) {
        print('qoe: the server log read failed ($error)');
        return null;
      }
    });
    if (rows is List) {
      return [
        for (final row in rows)
          if (row is Map)
            (
              t: (row['t'] as num).round(),
              method: '${row['method']}',
              path: '${row['path']}',
              status: (row['status'] as num?)?.toInt() ?? 0,
              range: '${row['range'] ?? ''}',
            ),
      ];
    }
  }
  return null;
}

/// Whether the second scenario server answers on [_port2].
Future<bool> _secondServer(WidgetTester tester) async {
  final up = await tester.runAsync(() async {
    try {
      // A time after every request, so the answer is an empty list.
      final uri = Uri.parse(
        'http://$_host:$_port2/_control/requests?since=${1 << 52}',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } on Object {
      return false;
    }
  });
  return up ?? false;
}

/// [path] on both scenario servers: source A on the first, which a
/// two-source row cuts, and B on the second. Recovery tells hosts apart with
/// their ports, so the two are two hosts.
List<StreamResult> _twoSources(String path) => [
  StreamResult(url: _url(path), source: 'A', providerName: 'QoE'),
  StreamResult(
    url: 'http://$_host:$_port2/$path?qoe=$_tag',
    source: 'B',
    providerName: 'QoE',
  ),
];

MultimediaItem _item(
  String path, {
  bool live = false,
  int? minutes,
  String provider = 'Remote',
}) => MultimediaItem(
  title: 'QoE $path',
  url: _url(path),
  posterUrl: '',
  provider: provider,
  contentType: live
      ? MultimediaContentType.livestream
      : MultimediaContentType.movie,
  duration: minutes,
);

/// One value the controller published, at a time on the scenario's clock.
typedef _Sample = ({
  int t,
  VlcPlaybackState state,
  int pos,
  bool stalled,
  double h,
  int? audio,
  int? subtitle,
  bool held,
});

/// The status lines recovery shows over the picture (the app's en strings),
/// by the label its waits carry in the QoE log.
const _statusTexts = {
  'reconnecting': 'Reconnecting…',
  'waitingForNetwork': 'Waiting for network…',
};

/// Every value the controller publishes, with the time since the scenario
/// began, and the process's peak memory.
class _Trace {
  _Trace(this.controller)
    : clock = Stopwatch()..start(),
      startEpochMs = DateTime.now().millisecondsSinceEpoch,
      rssAtOpen = ProcessInfo.currentRss {
    controller.addListener(_onValue);
    _rss = Timer.periodic(const Duration(seconds: 1), (_) {
      final rss = ProcessInfo.currentRss;
      if (rss > maxRss) maxRss = rss;
    });
  }

  final VlcPlayerController controller;
  final Stopwatch clock;

  /// This device's clock when [clock] started: the trace's time 0.
  final int startEpochMs;

  /// Resident memory when the player appeared, before its buffer filled.
  final int rssAtOpen;
  final samples = <_Sample>[];
  int maxRss = 0;
  Timer? _rss;
  int startupViews = 0;

  /// The decoder's count of video pictures, read once a second after
  /// [watchPictures]. libVLC's outputs show the last picture again every
  /// 80 ms and count each showing as displayed, so only the decoder's count
  /// tells a moving picture from a frozen one.
  final pictures = <PictureSample>[];

  /// The status lines seen over the picture, by label ([_statusTexts]).
  final statuses = <({int t, String label})>[];
  Timer? _pictureTimer;
  bool _readingPictures = false;

  void _onValue() {
    final v = controller.value;
    samples.add((
      t: clock.elapsedMilliseconds,
      state: v.state,
      pos: v.position.inMilliseconds,
      stalled: v.isStalled,
      h: v.videoSize?.height ?? 0,
      audio: v.activeAudioTrackId,
      subtitle: v.activeSubtitleTrackId,
      held: v.isPictureHeld,
    ));
  }

  /// Starts reading the decoder's count once a second. Only the outage rows
  /// ask: everything else measures what it always did.
  void watchPictures() {
    _pictureTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_readPicture()),
    );
  }

  /// One reading, skipped while the last is still out: a platform thread
  /// busy with a reopen answers late, and readings must not pile up.
  Future<void> _readPicture() async {
    if (_readingPictures) return;
    _readingPictures = true;
    try {
      final stats = await controller.getMediaStats();
      if (stats.isAvailable) {
        pictures.add((
          t: clock.elapsedMilliseconds,
          pos: controller.value.position.inMilliseconds,
          decoded: stats.decodedVideo,
        ));
      }
    } on Object {
      // A player detached or gone between readings: none this second.
    } finally {
      _readingPictures = false;
    }
  }

  void dispose() {
    controller.removeListener(_onValue);
    _rss?.cancel();
    _pictureTimer?.cancel();
  }

  int get now => clock.elapsedMilliseconds;

  /// First time after [from] the position reached [target] and kept moving:
  /// within 1.5 s of it, or up to [early] ms before it (an HLS seek lands on
  /// a segment boundary, up to a segment early).
  int? resumedAt(
    int from,
    int target, {
    int until = 1 << 30,
    int early = 1500,
  }) => landing(from, target, until: until, early: early)?.$1;

  /// When and where a seek to [target] began to play.
  (int, int)? landing(
    int from,
    int target, {
    int until = 1 << 30,
    int early = 1500,
  }) {
    final s = samples.where((x) => x.t >= from && x.t <= until).toList();
    for (var i = 1; i < s.length; i++) {
      final a = s[i - 1], b = s[i];
      final near = a.pos >= target - early && a.pos <= target + 1500;
      if (near &&
          b.pos > a.pos &&
          b.state == VlcPlaybackState.playing &&
          !b.stalled) {
        return (a.t - from, a.pos);
      }
    }
    return null;
  }

  /// Stalls in a stretch: isStalled rising edges and their total length.
  ({int count, int ms}) stalls({int from = 0, int? until}) {
    var count = 0, ms = 0, since = -1;
    for (final x in samples.where(
      (x) => x.t >= from && (until == null || x.t <= until),
    )) {
      if (x.stalled && since < 0) {
        since = x.t;
        count++;
      } else if (!x.stalled && since >= 0) {
        ms += x.t - since;
        since = -1;
      }
    }
    if (since >= 0) ms += (until ?? now) - since;
    return (count: count, ms: ms);
  }

  /// Whether the session ended or failed after [from], and the states it
  /// passed through, in order.
  ({bool endedOrError, List<String> states}) statesAfter(int from) {
    final states = <String>[];
    var ended = false;
    for (final x in samples.where((x) => x.t >= from)) {
      if (x.state == VlcPlaybackState.ended ||
          x.state == VlcPlaybackState.error) {
        ended = true;
      }
      if (states.isEmpty || states.last != x.state.name) {
        states.add(x.state.name);
      }
    }
    return (endedOrError: ended, states: states);
  }
}

int _pushEpochMs = 0;
int _firstPosMs = 0;

/// Opens [path] as a viewer would, through the player route, and returns the
/// controller, its trace, and the time from the push to a moving picture.
/// [sources] is a list of links handed in, as a sheet hands in the ones it
/// gathered.
Future<(VlcPlayerController, _Trace, int)> _open(
  WidgetTester tester,
  String path, {
  bool live = false,
  int? minutes,
  List<StreamResult>? sources,
  Duration timeout = const Duration(minutes: 2),
  void Function()? whileOpening,
}) async {
  final clock = Stopwatch()..start();
  _pushEpochMs = DateTime.now().millisecondsSinceEpoch;
  // A `Remote` item is a direct link, and plays only itself: a list handed
  // in plays for an item of any other provider.
  final item = _item(
    path,
    live: live,
    minutes: minutes,
    provider: sources == null ? 'Remote' : 'QoE',
  );
  unawaited(
    PlayerRoute(
      $extra: PlayerRouteExtra(
        item: item,
        videoUrl: item.url,
        preloadedStreams: sources,
      ),
    ).push<void>(tester.element(find.byType(Scaffold).first)),
  );
  await waitFor(tester, _player, timeout: const Duration(minutes: 1));
  final controller = tester.widget<VlcPlayer>(_player).controller;
  final traceAt = clock.elapsedMilliseconds;
  final trace = _Trace(controller);
  await pumpUntil(
    tester,
    () {
      whileOpening?.call();
      return controller.value.videoSize != null &&
          controller.value.position > Duration.zero;
    },
    what: 'a moving picture',
    timeout: timeout,
  );
  _firstPosMs = controller.value.position.inMilliseconds;
  // When the controller published it, not when the poll noticed.
  final moving = trace.samples.where((x) => x.h > 0 && x.pos > 0).firstOrNull;
  return (
    controller,
    trace,
    moving == null ? clock.elapsedMilliseconds : traceAt + moving.t,
  );
}

/// The longest the Dart event loop went without running a timer during the
/// last [_leave].
int _lastLeaveBlockMs = 0;

/// Backs out of the player as Back does, and returns how long that took.
Future<int> _leave(WidgetTester tester) async {
  final clock = Stopwatch()..start();
  var last = 0, maxGap = 0;
  final ticker = Timer.periodic(const Duration(milliseconds: 8), (_) {
    final now = clock.elapsedMilliseconds;
    if (now - last > maxGap) maxGap = now - last;
    last = now;
  });
  // The first Back can be spent putting the bars or the panel away.
  for (var i = 0; i < 3 && _player.evaluate().isNotEmpty; i++) {
    await tester.binding.handlePopRoute();
    await pumpFor(tester, const Duration(milliseconds: 500));
  }
  ticker.cancel();
  _lastLeaveBlockMs = maxGap;
  return clock.elapsedMilliseconds;
}

/// Plays on for [d], or until [until] holds, counting the 250 ms ticks the
/// start-up view was up, and noting each tick a status line showed over the
/// picture.
Future<void> _watch(
  WidgetTester tester,
  _Trace trace,
  Duration d, {
  bool Function()? until,
}) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await pumpFor(tester, const Duration(milliseconds: 250));
    if (until != null && until()) return;
    if (find.byType(PlayerStartupView).evaluate().isNotEmpty) {
      trace.startupViews++;
      continue;
    }
    for (final MapEntry(key: label, value: text) in _statusTexts.entries) {
      if (find.text(text).evaluate().isNotEmpty) {
        trace.statuses.add((t: trace.now, label: label));
      }
    }
  }
}

/// What the screen's QoE log recorded for the open just measured: the
/// start-up split (spec 1.8) and the buffer it chose (spec 1.2).
Map<String, Object?> _qoeFields() {
  final events = QoeLog.latest?.events ?? const <QoeEvent>[];
  final first = events
      .where((e) => e.kind == QoeEventKind.firstFrame)
      .firstOrNull;
  final buffer = events.where((e) => e.kind == QoeEventKind.buffer).lastOrNull;
  return {
    if (first != null) 'appMs': first.fields['appMs'],
    if (first != null) 'engineMs': first.fields['engineMs'],
    if (buffer != null) 'buffer': buffer.fields,
  };
}

void _report(String name, Map<String, Object?> fields) {
  print(
    'QOE ${asciiJson({'scenario': name, 'platform': Platform.operatingSystem, 'tag': _tag, 'pushEpochMs': _pushEpochMs, 'firstPosMs': _firstPosMs, ..._qoeFields(), ...fields})}',
  );
}

/// A row this run can't take, and why, for the report's table.
void _skip(String name, String why) => print(
  'QOE ${asciiJson({'scenario': name, 'platform': Platform.operatingSystem, 'skipped': why})}',
);

/// The screen's QoE log, on [trace]'s clock. The log starts with the screen,
/// a frame or two after the push, so its events are placed up to that much
/// early.
List<TimedEvent> _timedEvents(_Trace trace) => [
  for (final e in QoeLog.latest?.events ?? const <QoeEvent>[])
    (
      kind: e.kind.name,
      t: _pushEpochMs + e.atMs - trace.startEpochMs,
      fields: e.fields,
    ),
];

/// The start of every request path of [path]'s media: its folder for HLS
/// (`/hls/`), the file itself otherwise.
String _mediaPrefix(String path) =>
    path.contains('/') ? '/${path.split('/').first}/' : '/$path';

/// An outage row (spec 7.2): plays [path] on a 30 Mbit/s link, cuts it with
/// the control command [cmd] for [secs] ([query] says more), watches
/// [after], and reports what the viewer saw and what recovery did, for
/// `report.py`'s `outage()`.
///
/// - [live] plays a live HLS feed started for the row.
/// - [twoSources] hands in the media on both servers, and the cut is A's.
/// - [endOutageWhen] ends the outage early, once the QoE events since the
///   cut satisfy it. The row then reports the outage as long as it was.
///
/// HLS is cut 12 s after its picture moved, past the video-health verdict
/// (9–11 s after the first picture): a step-down there, which the emulators'
/// decoders bring on, is over before the cut, so the row measures the
/// recovery and not the decoder. A file is cut after 8 s, as before: nothing
/// reopens it at the verdict, and each second more on this link adds about
/// 6 s of film to its read-ahead, past the window's end on a 20 s drop.
Future<void> _outage(
  WidgetTester tester,
  String name,
  String path, {
  required String cmd,
  required int secs,
  Map<String, String> query = const {},
  Duration after = const Duration(seconds: 75),
  bool live = false,
  bool twoSources = false,
  bool Function(List<TimedEvent> sinceCut)? endOutageWhen,
}) async {
  if (twoSources && !await _secondServer(tester)) {
    _skip(name, 'no second server on port $_port2 (run.sh starts one)');
    return;
  }
  final adaptive = path.endsWith('.m3u8');
  await _control(tester, 'reset', {'kbps': '30000'});
  if (twoSources) await _control(tester, 'reset', {'kbps': '30000'}, _port2);
  if (live) await _startLiveFeed(tester, 'hls', 6);
  final (controller, trace, ttff) = await _open(
    tester,
    path,
    live: live,
    sources: twoSources ? _twoSources(path) : null,
  );
  trace.watchPictures();
  await _watch(tester, trace, Duration(seconds: adaptive ? 12 : 8));
  final cut = trace.now;
  final endAt = cut + after.inMilliseconds;
  final viewsBefore = trace.startupViews;
  final cutAnswer = await _control(tester, cmd, {'secs': '$secs', ...query});
  if (cutAnswer['ok'] == false) {
    await _leave(tester);
    trace.dispose();
    _skip(name, '${cutAnswer['why']}');
    return;
  }
  int epochOf(Map<String, Object?> answer) =>
      ((answer['epochMs'] as num?) ?? 0).round();
  // The offline mode takes the device off its network a moment after it
  // answers, so that its answer gets through first.
  final outageStart =
      epochOf(cutAnswer) + ((cutAnswer['delayMs'] as num?) ?? 0).round();
  var outageMs = secs * 1000;
  if (endOutageWhen != null) {
    await _watch(
      tester,
      trace,
      after,
      until: () => endOutageWhen([
        for (final e in _timedEvents(trace))
          if (e.t >= cut) e,
      ]),
    );
    if (trace.now < endAt) {
      final ended = await _control(tester, 'reset', {'kbps': '30000'});
      outageMs = epochOf(ended) - outageStart;
    }
  }
  if (trace.now < endAt) {
    await _watch(tester, trace, Duration(milliseconds: endAt - trace.now));
  }
  final end = trace.now;
  final s = trace.stalls(from: cut);
  final states = trace.statesAfter(cut);
  final playingAtEnd =
      controller.value.isPlaying && !controller.value.isStalled;
  final finalState = controller.value.state.name;
  final endPos = controller.value.position.inMilliseconds;
  final events = _timedEvents(trace);
  // The player's states from a second before the cut, each with the hold (*)
  // and the position, and recovery's events: what a row's numbers alone
  // can't say (P1 Part 3's Windows round needed both).
  final changes = <String>[];
  String? lastKey;
  for (final x in trace.samples) {
    if (x.t < cut - 1000) continue;
    final key = '${x.state.name}/${x.held}';
    if (key == lastKey) continue;
    lastKey = key;
    changes.add('${x.t - cut}:${x.state.name}${x.held ? '*' : ''}@${x.pos}');
  }
  print('qoe_states: $name ${changes.take(80).join(' ')}');
  print(
    'qoe_events: $name ${[for (final e in events)
      if (e.t >= cut - 1000) '${e.t - cut}:${e.kind}${e.fields}'].take(40).join(' | ')}',
  );
  final requests = await _servedSince(
    tester,
    trace.startEpochMs + _serverClockOffsetMs,
  );
  final leave = await _leave(tester);
  trace.dispose();
  _report(name, {
    'ttffMs': ttff,
    'stalls': s.count,
    'stalledMs': s.ms,
    'endedOrError': states.endedOrError,
    'startupViews': trace.startupViews - viewsBefore,
    'playingAtEnd': playingAtEnd,
    'states': states.states.take(12).toList(),
    'finalState': finalState,
    'endPosMs': endPos,
    'leaveMs': leave,
    'requestsRead': requests != null,
    ...outageMeasures(
      pictures: trace.pictures,
      heldPictureSeen: trace.samples.any((x) => x.t >= cut && x.held),
      statusSeen: {
        for (final x in trace.statuses)
          if (x.t >= cut) x.label,
      },
      events: events,
      requests: requests ?? const <ServedRequest>[],
      cut: cut,
      end: end,
      traceEpochMs: trace.startEpochMs,
      serverOffsetMs: _serverClockOffsetMs,
      outageStartMs: outageStart,
      outageMs: outageMs,
      media: live
          ? 'live'
          : adaptive
          ? 'hls'
          : 'file',
      pathPrefix: _mediaPrefix(path),
    ),
  });
}

/// [whenAsked] scenarios run only when `QOE_ONLY` names them: they need the
/// host to do something to the device while they run.
void _scenario(
  String name,
  Future<void> Function(WidgetTester tester) body, {
  bool whenAsked = false,
}) {
  // `name@ms` is one delay of a live scenario: asking for the scenario asks
  // for every delay.
  final names = _only.split(',');
  final asked = names.contains(name) || names.contains(name.split('@').first);
  final skipped =
      !_run ||
      (whenAsked && !asked) ||
      (_only.isNotEmpty && name != 'warmup' && !asked);
  testWidgets(name, skip: skipped, (tester) async {
    _tag = '$name-${DateTime.now().millisecondsSinceEpoch}';
    await withApp(tester, (_) async {
      await _keepOnTop();
      try {
        await body(tester);
      } finally {
        await _control(tester, 'live-stop');
        await _control(tester, 'reset', {'kbps': '0'});
      }
    });
  });
}

/// Registers [name] once per delay in `QOE_LIVE_DELAYS`, the app's live delay
/// set to it ([PlayerDiagnostics.liveDelayMs]), or once at the app's own.
/// [body] gets the name to report under.
void _liveScenario(
  String name,
  Future<void> Function(WidgetTester tester, String name) body,
) {
  final delays = [
    for (final part in _liveDelays.split(','))
      if (int.tryParse(part.trim()) case final ms? when ms > 0) ms,
  ];
  if (delays.isEmpty) return _scenario(name, (tester) => body(tester, name));
  for (final ms in delays) {
    _scenario('$name@$ms', (tester) async {
      PlayerDiagnostics.environment = {
        ...Platform.environment,
        'SKYSTREAM_LIVE_DELAY_MS': '$ms',
      };
      try {
        await body(tester, '$name@$ms');
      } finally {
        PlayerDiagnostics.environment = Platform.environment;
      }
    });
  }
}

/// Keeps the test window above other apps' windows on macOS. A window that is
/// fully covered gets no frames there, and the suite waits on frames: a run
/// on the owner's Mac stalled for minutes behind an editor's window.
Future<void> _keepOnTop() async {
  if (!Platform.isMacOS) return;
  try {
    await windowManager.setAlwaysOnTop(true);
  } on Object {
    // A window manager that isn't set up leaves the window as it is.
  }
}

Future<void> _startup(
  WidgetTester tester,
  String name,
  String path,
  String kbps, {
  bool live = false,
}) async {
  await _control(tester, 'reset', {'kbps': kbps});
  final (controller, trace, ttff) = await _open(tester, path, live: live);
  await _watch(tester, trace, const Duration(seconds: 12));
  final leave = await _leave(tester);
  trace.dispose();
  _report(name, {
    'ttffMs': ttff,
    'height': controller.value.videoSize?.height,
    'stalls': trace.stalls().count,
    'maxRssMb': trace.maxRss ~/ (1 << 20),
    'leaveMs': leave,
    'leaveBlockMs': _lastLeaveBlockMs,
  });
}

Future<void> _seeks(
  WidgetTester tester,
  String name,
  String path,
  String kbps,
  List<int> steps,
) async {
  await _control(tester, 'reset', {'kbps': kbps});
  final (controller, trace, ttff) = await _open(tester, path);
  await _watch(tester, trace, const Duration(seconds: 5));
  final results = <Map<String, Object?>>[];
  for (final step in steps) {
    final from = controller.value.position.inMilliseconds;
    final target = (from + step).clamp(0, 1 << 30);
    final at = trace.now;
    unawaited(controller.seekTo(Duration(milliseconds: target)));
    await _watch(tester, trace, const Duration(seconds: 8));
    final early = path.endsWith('.m3u8') ? 7000 : 1500;
    final landed = trace.landing(at, target, early: early);
    results.add({
      'step': step ~/ 1000,
      'resumeMs': landed?.$1,
      'landedOffMs': landed == null ? null : landed.$2 - target,
      'posAfterMs': controller.value.position.inMilliseconds - target,
    });
  }
  final leave = await _leave(tester);
  trace.dispose();
  _report(name, {
    'ttffMs': ttff,
    'seeks': results,
    'stalls': trace.stalls().count,
    'startupViews': trace.startupViews,
    'maxRssMb': trace.maxRss ~/ (1 << 20),
    'leaveMs': leave,
  });
}

/// Opens the panel on Audio or Subtitles and taps the first track row that
/// isn't on, as a viewer does: a tap on the picture for the bars, Options,
/// the tab, the row. Returns the tap's time on [trace]'s clock and the
/// position then.
Future<(int, int)> _pickOtherTrack(
  WidgetTester tester,
  _Trace trace, {
  required bool audio,
}) async {
  final l10n = AppLocalizations.of(
    tester.element(find.byType(Scaffold).first),
  )!;
  // Hidden bars stay mounted behind an IgnorePointer: only an Options button
  // that answers a tap is one a viewer can press.
  final options = find.byTooltip(l10n.options).hitTestable();
  if (options.evaluate().isEmpty) {
    await tester.tapAt(tester.getCenter(_player));
    await waitFor(tester, options, timeout: const Duration(seconds: 10));
  }
  await tester.tap(options);
  await waitFor(
    tester,
    find.byType(PlayerPanel),
    timeout: const Duration(seconds: 10),
  );
  // The panel slides in in a quarter of a second, and takes longer on an
  // emulator busy decoding, so the tab is waited for, not timed (a fixed
  // 600 ms missed it on the loaded phone and TV emulators).
  final tab = audio ? l10n.audio : l10n.subtitles;
  final tabFinder = find
      .descendant(of: find.byType(PlayerPanel), matching: find.text(tab))
      .hitTestable();
  await waitFor(tester, tabFinder, timeout: const Duration(seconds: 10));
  await tester.tap(tabFinder.first);
  // Off and Retry are rows too; the tracks come first after Off. They load
  // from the engine, so they are waited for as well.
  final row = find.byWidgetPredicate(
    (w) =>
        w is PanelRow &&
        !w.selected &&
        w.label != l10n.off &&
        w.label != l10n.retry,
  );
  await pumpUntil(
    tester,
    () => row.evaluate().isNotEmpty,
    what: 'another track under $tab',
    timeout: const Duration(seconds: 10),
  );
  await tester.ensureVisible(row.first);
  await pumpFor(tester, const Duration(milliseconds: 300));
  // The panel reloads its lists when the engine's track revision moves, and
  // the rows remount: on a slow emulator that lands between the find and the
  // tap (the phone's switch-audio-mkv), so the row is waited for again.
  await pumpUntil(
    tester,
    () => row.evaluate().isNotEmpty,
    what: 'another track under $tab, after a reload',
    timeout: const Duration(seconds: 10),
  );
  // F9 (P1 Part 4): on the emulators the first pick took the track already
  // on. Whether the panel ticked its row late, or something put track 1
  // back after the tap, these say.
  final tapped = tester.widget<PanelRow>(row.first);
  final ticked = [
    for (final element
        in find
            .byWidgetPredicate((w) => w is PanelRow && w.selected)
            .evaluate())
      (element.widget as PanelRow).label,
  ];
  final value = trace.controller.value;
  print(
    'qoe_tick: $tab tap "${tapped.label}" selected=${tapped.selected}; '
    'ticked $ticked; active audio ${value.activeAudioTrackId} '
    'subtitle ${value.activeSubtitleTrackId}',
  );
  final at = trace.now;
  final pos = trace.controller.value.position.inMilliseconds;
  await tester.tap(row.first);
  return (at, pos);
}

/// Closes the panel, if a pick left it open.
Future<void> _closePanel(WidgetTester tester) async {
  if (find.byType(PlayerPanel).evaluate().isEmpty) return;
  await tester.binding.handlePopRoute();
  await pumpUntil(
    tester,
    () => find.byType(PlayerPanel).evaluate().isEmpty,
    what: 'the panel to close',
    timeout: const Duration(seconds: 10),
  );
}

/// Two track switches through the panel, each watched for 8 s: when the
/// engine said the new track was on, the time stalled, and when the picture
/// moved on from where it was at the tap.
Future<void> _switch(
  WidgetTester tester,
  String name,
  String path, {
  required bool audio,
}) async {
  await _control(tester, 'reset', {'kbps': '30000'});
  final (controller, trace, ttff) = await _open(tester, path);
  await _watch(tester, trace, const Duration(seconds: 6));
  int? onNow() => audio
      ? controller.value.activeAudioTrackId
      : controller.value.activeSubtitleTrackId;
  final results = <Map<String, Object?>>[];
  for (var i = 0; i < 2; i++) {
    final before = onNow();
    final (at, pos) = await _pickOtherTrack(tester, trace, audio: audio);
    await _watch(tester, trace, const Duration(seconds: 8));
    final switched = trace.samples.where((x) {
      final on = audio ? x.audio : x.subtitle;
      return x.t >= at && on != null && on != before;
    }).firstOrNull;
    results.add({
      'from': before,
      'to': onNow(),
      'switchedMs': switched == null ? null : switched.t - at,
      'rebufferMs': trace.stalls(from: at, until: at + 8000).ms,
      'resumeMs': trace.resumedAt(at, pos, until: at + 8000),
    });
    await _closePanel(tester);
  }
  final leave = await _leave(tester);
  trace.dispose();
  _report(name, {'ttffMs': ttff, 'switches': results, 'leaveMs': leave});
}

/// Starts a live HLS feed ([kind] `hls` or `hls-long`) and waits until it
/// lists [segments] segments, so the player meets a channel already running.
Future<void> _startLiveFeed(
  WidgetTester tester,
  String kind,
  int segments,
) async {
  await _control(tester, 'live', {'kind': kind, 'secs': '600'});
  final deadline = DateTime.now().add(Duration(seconds: segments * 4 + 30));
  while (DateTime.now().isBefore(deadline)) {
    final playlist = await _fetch(tester, 'live/index.m3u8');
    if ('#EXTINF'.allMatches(playlist).length >= segments) return;
    await pumpFor(tester, const Duration(seconds: 1));
  }
  throw TestFailure('the live feed never listed $segments segments');
}

/// Each listed segment's number and program date (epoch ms, the Mac's clock)
/// in a live media playlist.
Map<int, int> _programDates(String playlist) {
  final dates = <int, int>{};
  int? date;
  for (final line in const LineSplitter().convert(playlist)) {
    const tag = '#EXT-X-PROGRAM-DATE-TIME:';
    if (line.startsWith(tag)) {
      date = DateTime.parse(line.substring(tag.length).trim())
          .millisecondsSinceEpoch;
      continue;
    }
    final segment = RegExp(r'^seg(\d+)\.ts').firstMatch(line.trim());
    if (segment != null && date != null) {
      dates[int.parse(segment.group(1)!)] = date;
      date = null;
    }
  }
  return dates;
}

/// How far behind real time the first picture of a live HLS feed was: the
/// program date of the first segment the player fetched, against the moment
/// the picture moved, both on the Mac's clock. Segments are 4 s, so one
/// listed date places a segment that has already left the window.
Future<int?> _behindRealTime(WidgetTester tester, int firstFrameEpochMs) async {
  final first = (await _requestsSince(tester, _pushEpochMs - 2000))
      .map((path) => RegExp(r'live/seg(\d+)\.ts').firstMatch(path))
      .nonNulls
      .firstOrNull;
  if (first == null) return null;
  final dates = _programDates(await _fetch(tester, 'live/index.m3u8'));
  if (dates.isEmpty) return null;
  final segment = int.parse(first.group(1)!);
  final (known, knownDate) = (dates.keys.first, dates.values.first);
  final played = dates[segment] ?? knownDate + (segment - known) * 4000;
  return firstFrameEpochMs + _serverClockOffsetMs - played;
}

/// WebTorrent's Sintel (Blender Foundation, CC BY 3.0), as a magnet with its
/// trackers: the phase-5 real torrent (spec 5; research A, section 5). Its
/// public swarm serves it: TorrServer drops webseeds.
const _sintelHash = '08ada5a7a6183aae1e09d831df6748d566095a10';
const _sintelMagnet =
    'magnet:?xt=urn:btih:$_sintelHash&dn=Sintel'
    '&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337'
    '&tr=udp%3A%2F%2Fexplodie.org%3A6969'
    '&tr=udp%3A%2F%2Ftracker.leechers-paradise.org%3A6969'
    '&tr=udp%3A%2F%2Ftracker.coppersurfer.tk%3A6969'
    '&tr=udp%3A%2F%2Ftracker.empire-js.us%3A1337';

/// TorrServer's own answer to [body] on [path], with the app's token.
Future<Map<String, Object?>> _torrServer(
  WidgetTester tester,
  String path,
  Map<String, Object?> body,
) async {
  final answer = await tester.runAsync(() async {
    final response = await http
        .post(
          Uri.parse('http://127.0.0.1:8090/$path'),
          headers: {
            'Content-Type': 'application/json',
            FlutterTorrentServer.authTokenHeader:
                FlutterTorrentServer().authToken ?? '',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 5));
    final decoded = response.statusCode == 200
        ? jsonDecode(response.body)
        : null;
    return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
  });
  return answer ?? const <String, Object?>{};
}

/// One real-torrent row: Sintel under a [label] with no size, on a 15-minute
/// item, so the rule plans from the label's bitrate guess; seeks of +10,
/// +60 and -30 s, measured as the seek rows measure them; two minutes of
/// play.
Future<void> _torrentRow(WidgetTester tester, String name, String label) async {
  await _control(tester, 'reset', {'kbps': '0'});
  final pushed = Stopwatch()..start();
  int? peerLineMs;
  final (controller, trace, ttff) = await _open(
    tester,
    'prog.mp4',
    minutes: 15,
    sources: [
      StreamResult(
        url: _sintelMagnet,
        source: 'Sintel · $label · Torrent',
        providerName: 'QoE',
      ),
    ],
    timeout: const Duration(minutes: 3),
    whileOpening: () {
      if (peerLineMs == null &&
          find.textContaining(' peers · ').evaluate().isNotEmpty) {
        peerLineMs = pushed.elapsedMilliseconds;
      }
    },
  );
  final settings = await _torrServer(tester, 'settings', {'action': 'get'});
  final cache = await _torrServer(tester, 'cache', {
    'action': 'get',
    'hash': _sintelHash,
  });
  final atFirst = await _torrServer(tester, 'torrents', {
    'action': 'get',
    'hash': _sintelHash,
  });
  final resumes = <int?>[];
  for (final step in const [10, 60, -30]) {
    final from = controller.value.position.inMilliseconds;
    final target = (from + step * 1000).clamp(0, 1 << 30);
    final at = trace.now;
    unawaited(controller.seekTo(Duration(milliseconds: target)));
    await _watch(tester, trace, const Duration(seconds: 8));
    resumes.add(trace.resumedAt(at, target));
  }
  await _watch(tester, trace, const Duration(seconds: 60));
  final later = await _torrServer(tester, 'torrents', {
    'action': 'get',
    'hash': _sintelHash,
  });
  await _watch(tester, trace, const Duration(seconds: 60));
  final event = (QoeLog.latest?.events ?? const <QoeEvent>[])
      .where((e) => e.kind == QoeEventKind.torrent)
      .firstOrNull;
  final leave = await _leave(tester);
  trace.dispose();
  _report(name, {
    'ttffMs': ttff,
    'peerLineMs': peerLineMs,
    'torrent': event?.fields,
    'readBack': {
      for (final key in const [
        'CacheSize',
        'ReaderReadAHead',
        'PreloadCache',
        'RetrackersMode',
        'ConnectionsLimit',
        'TorrentDisconnectTimeout',
      ])
        key: settings[key],
    },
    'cacheCapacity': cache['Capacity'],
    'peersAtFirstFrame': atFirst['active_peers'] ?? 0,
    'totalPeersAtFirstFrame': atFirst['total_peers'] ?? 0,
    'peers60s': later['active_peers'] ?? 0,
    'stalls': trace.stalls().count,
    'seekResumeMs': resumes,
    'maxRssMb': trace.maxRss ~/ (1 << 20),
    'leaveMs': leave,
  });
}

void main() {
  // Frames as the app gets them outside a test. The default policy draws only
  // when the test pumps (every 250 ms here), which made every step that waits
  // for a frame look up to 250 ms slower.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  // The first open after the app starts pays for cold code paths (on the
  // Android emulator, libVLC's first MP4 open stalled 12 s or for good), so it
  // is measured on its own and kept out of the warm numbers.
  _scenario('warmup', (tester) async {
    await _control(tester, 'reset', {'kbps': '30000'});
    final attempts = <Object?>[];
    for (var i = 0; i < 3; i++) {
      _tag = 'warmup$i-${DateTime.now().millisecondsSinceEpoch}';
      try {
        final (_, trace, ttff) = await _open(tester, 'prog.mp4');
        await _watch(tester, trace, const Duration(seconds: 5));
        await _leave(tester);
        trace.dispose();
        attempts.add(ttff);
        break;
      } on TestFailure catch (e) {
        attempts.add('failed: ${e.message?.split('On screen: ').last}');
        await _leave(tester);
      }
    }
    _report('warmup', {
      'attempts': attempts,
      'ttffMs': attempts.last is int ? attempts.last : null,
    });
  });

  _scenario(
    'start-mp4-8M',
    (t) => _startup(t, 'start-mp4-8M', 'prog.mp4', '8000'),
  );
  _scenario(
    'start-mkv-8M',
    (t) => _startup(t, 'start-mkv-8M', 'prog.mkv', '8000'),
  );
  _scenario(
    'start-hls-8M',
    (t) => _startup(t, 'start-hls-8M', 'hls/master.m3u8', '8000'),
  );
  _scenario(
    'start-mp4-30M',
    (t) => _startup(t, 'start-mp4-30M', 'prog.mp4', '30000'),
  );
  // An IPTV-style channel: every connection gets its own live encoder.
  _scenario(
    'live-ts-start',
    (t) => _startup(t, 'live-ts-start', 'live.ts', '30000', live: true),
  );

  for (final (name, path, kbps) in const [
    ('resume-mp4-8M', 'prog.mp4', '8000'),
    ('resume-hls-8M', 'hls/master.m3u8', '8000'),
  ]) {
    _scenario(name, (tester) async {
      await _control(tester, 'reset', {'kbps': '30000'});
      final (first, firstTrace, _) = await _open(tester, path);
      final seekAt = firstTrace.now;
      unawaited(first.seekTo(const Duration(seconds: 180)));
      // Until the seek has landed and played a little, so the history holds
      // 3 min.
      await pumpUntil(
        tester,
        () => first.value.position >= const Duration(seconds: 183),
        what: 'the seek to 3 min',
        timeout: const Duration(seconds: 60),
      );
      final seekMs = firstTrace.now - seekAt;
      final savedAt = first.value.position.inMilliseconds;
      await _leave(tester);
      firstTrace.dispose();
      await _control(tester, 'reset', {'kbps': kbps});
      final (_, trace, ttff) = await _open(tester, path);
      await _watch(tester, trace, const Duration(seconds: 8));
      final leave = await _leave(tester);
      trace.dispose();
      _report(name, {
        'ttffMs': ttff,
        'savedAtMs': savedAt,
        'seekTo180Ms': seekMs,
        'stalls': trace.stalls().count,
        'leaveMs': leave,
      });
    });
  }

  _scenario(
    'seeks-mp4-30M',
    (t) => _seeks(t, 'seeks-mp4-30M', 'prog.mp4', '30000', [
      10000,
      60000,
      -10000,
      -60000,
    ]),
  );
  _scenario(
    'seeks-mp4-8M',
    (t) => _seeks(t, 'seeks-mp4-8M', 'prog.mp4', '8000', [
      10000,
      60000,
      -10000,
      -60000,
    ]),
  );
  _scenario(
    'seeks-hls-8M',
    (t) => _seeks(t, 'seeks-hls-8M', 'hls/master.m3u8', '8000', [
      10000,
      60000,
      -60000,
    ]),
  );

  _scenario('storm-mp4-30M', (tester) async {
    await _control(tester, 'reset', {'kbps': '30000'});
    final (controller, trace, ttff) = await _open(tester, 'prog.mp4');
    await _watch(tester, trace, const Duration(seconds: 8));
    final start = trace.now;
    var target = controller.value.position.inMilliseconds;
    // Each seek: seconds to jump, then the ms to wait. Bursts, pauses, and
    // a run of five quick steps at the end.
    const storm = [
      (10, 600),
      (10, 600),
      (10, 2800),
      (-10, 600),
      (-10, 600),
      (-10, 2800),
      (10, 700),
      (-10, 700),
      (10, 700),
      (-10, 2900),
      (-30, 4000),
      (30, 4000),
      (5, 250),
      (5, 250),
      (5, 250),
      (5, 250),
      (5, 250),
    ];
    for (final (step, gap) in storm) {
      target = (target + step * 1000).clamp(0, 1 << 30);
      unawaited(controller.seekTo(Duration(milliseconds: target)));
      await _watch(tester, trace, Duration(milliseconds: gap));
    }
    final last = trace.now;
    await _watch(tester, trace, const Duration(seconds: 10));
    final settled = trace.resumedAt(last, target);
    final leave = await _leave(tester);
    trace.dispose();
    _report('storm-mp4-30M', {
      'ttffMs': ttff,
      'stormMs': last - start,
      'finalResumeMs': settled,
      'stalled': trace.stalls(from: start).ms,
      'maxRssMb': trace.maxRss ~/ (1 << 20),
      'leaveMs': leave,
    });
  });

  _scenario('weak-hls-3500', (tester) async {
    await _control(tester, 'reset', {'kbps': '3500'});
    final (controller, trace, ttff) = await _open(tester, 'hls/master.m3u8');
    final from = trace.now;
    await _watch(tester, trace, const Duration(seconds: 90));
    // 75 s is the baseline's window; 90 s is the spec's target's.
    final s75 = trace.stalls(from: from, until: from + 75000);
    final s90 = trace.stalls(from: from, until: from + 90000);
    final leave = await _leave(tester);
    trace.dispose();
    _report('weak-hls-3500', {
      'ttffMs': ttff,
      'stalls': s75.count,
      'stalledMs': s75.ms,
      'stalls90': s90.count,
      'stalledMs90': s90.ms,
      'height': controller.value.videoSize?.height,
      'leaveMs': leave,
    });
  });

  // 30 s at 3 Mbit/s, under the 720p rung with its audio (3.1), then back
  // to 30.
  _scenario('collapse-hls', (tester) async {
    await _control(tester, 'reset', {'kbps': '30000'});
    final (controller, trace, ttff) = await _open(tester, 'hls/master.m3u8');
    await _watch(tester, trace, const Duration(seconds: 15));
    final cut = trace.now;
    await _control(tester, 'schedule', {'steps': '0:3000,30:30000'});
    await _watch(tester, trace, const Duration(seconds: 75));
    final s = trace.stalls(from: cut);
    final heights = [
      for (final x in trace.samples)
        if (x.t >= cut && x.t <= cut + 30000 && x.h > 0) x.h,
    ];
    final leave = await _leave(tester);
    trace.dispose();
    _report('collapse-hls', {
      'ttffMs': ttff,
      'stalls': s.count,
      'stalledMs': s.ms,
      'minHeight': heights.isEmpty
          ? null
          : heights.reduce((a, b) => a < b ? a : b),
      'heightAtEnd': controller.value.videoSize?.height,
      'leaveMs': leave,
    });
  });

  // The spec's 20 s outages (7.2). A 20 s drop must be over well inside the
  // window: the file plays some 51 s of read-ahead first.
  for (final (name, path, cmd) in const [
    ('drop20-mp4', 'prog.mp4', 'drop'),
    ('stall20-hls', 'hls/master.m3u8', 'stall'),
    ('drop20-hls', 'hls/master.m3u8', 'drop'),
  ]) {
    _scenario(name, (t) => _outage(t, name, path, cmd: cmd, secs: 20));
  }

  // The spec's longer outages (7.2): past the buffer, so recovery waits over
  // the picture, and two minutes with no source used up.
  for (final (name, path, secs, after) in const [
    ('drop60-mp4', 'prog.mp4', 60, Duration(seconds: 120)),
    ('drop60-hls', 'hls/master.m3u8', 60, Duration(seconds: 120)),
    ('outage120-hls', 'hls/master.m3u8', 120, Duration(seconds: 180)),
  ]) {
    _scenario(
      name,
      (t) => _outage(t, name, path, cmd: 'drop', secs: secs, after: after),
    );
  }

  // Two minutes offline (spec 7.2): the server takes the phone emulator off
  // its cellular link through adb. A Mac, a simulator or a VM shares its
  // network with the server, so only Android can be cut off alone.
  _scenario('offline-120', (tester) async {
    if (!Platform.isAndroid) {
      _skip('offline-120', 'Android only: this device shares the network');
      return;
    }
    await _outage(
      tester,
      'offline-120',
      'hls/master.m3u8',
      cmd: 'offline',
      secs: 120,
      after: const Duration(seconds: 180),
    );
  });

  // Spec 2's other answers, on a device: a refused source fails over at
  // once; a busy one is waited out as Retry-After asks; a host that stays
  // down while another answers is left after 30 s; a live stream reconnects
  // over its picture.
  _scenario(
    'gone403-2src',
    (t) => _outage(
      t,
      'gone403-2src',
      'hls/master.m3u8',
      cmd: 'status',
      secs: 150,
      query: {'code': '403'},
      twoSources: true,
    ),
  );
  _scenario(
    'busy503-ra',
    (t) => _outage(
      t,
      'busy503-ra',
      'hls/master.m3u8',
      cmd: 'status',
      secs: 120,
      query: {'code': '503', 'retryAfter': '4'},
      // Ended once recovery has met it twice. When recovery first checks
      // depends on how much the player had buffered, and a fifth busy answer
      // would fail the only source over.
      endOutageWhen: (events) =>
          events
              .where((e) => e.kind == 'check' && e.fields['kind'] == 'busy')
              .length >=
          2,
    ),
  );
  _scenario(
    'hostdown-2src',
    (t) => _outage(
      t,
      'hostdown-2src',
      'hls/master.m3u8',
      cmd: 'drop',
      secs: 120,
      after: const Duration(seconds: 100),
      twoSources: true,
    ),
  );
  _scenario(
    'live-drop20',
    (t) => _outage(
      t,
      'live-drop20',
      'live/index.m3u8',
      cmd: 'drop',
      secs: 20,
      live: true,
    ),
  );

  _scenario(
    'switch-audio-mkv',
    (t) => _switch(t, 'switch-audio-mkv', 'prog.mkv', audio: true),
  );
  _scenario(
    'switch-audio-hls',
    (t) => _switch(t, 'switch-audio-hls', 'hls/master.m3u8', audio: true),
  );
  _scenario(
    'switch-subs-mkv',
    (t) => _switch(t, 'switch-subs-mkv', 'prog.mkv', audio: false),
  );

  _scenario('memory-mp4-30M', (tester) async {
    await _control(tester, 'reset', {'kbps': '30000'});
    final (_, trace, ttff) = await _open(tester, 'prog.mp4');
    await _watch(tester, trace, const Duration(seconds: 60));
    final leave = await _leave(tester);
    trace.dispose();
    _report('memory-mp4-30M', {
      'ttffMs': ttff,
      'maxRssMb': trace.maxRss ~/ (1 << 20),
      'rssAtOpenMb': trace.rssAtOpen ~/ (1 << 20),
      'leaveMs': leave,
    });
  });

  // A film played to its end (P1 Part 3 review, finding 1): every backend
  // follows the end with a stop, which must leave the ended card up and
  // reopen nothing.
  _scenario('end-mp4', (tester) async {
    await _control(tester, 'reset', {'kbps': '30000'});
    final (controller, trace, ttff) = await _open(
      tester,
      'prog.mp4',
      minutes: 10,
    );
    unawaited(controller.seekTo(const Duration(seconds: 594)));
    bool carded() => find.byKey(endedCardKey).evaluate().isNotEmpty;
    await _watch(tester, trace, const Duration(seconds: 30), until: carded);
    final cardedAtEnd = carded();
    // What follows the end: nothing may reopen it.
    await pumpFor(tester, const Duration(seconds: 15));
    final afterEnd = [
      for (final e in QoeLog.latest?.events ?? const <QoeEvent>[])
        if (e.kind == QoeEventKind.reopen ||
            e.kind == QoeEventKind.failover ||
            e.kind == QoeEventKind.error)
          e.kind.name,
    ];
    final stillCarded = carded();
    final leave = await _leave(tester);
    trace.dispose();
    _report('end-mp4', {
      'ttffMs': ttff,
      'endedCard': cardedAtEnd && stillCarded,
      'afterEnd': afterEnd,
      'finalState': controller.value.state.name,
      'leaveMs': leave,
    });
  });

  // The 4K-class file, with its runtime known (3 minutes), so the buffer rule
  // works from its real bitrate. The link outruns the file.
  _scenario('memory-4k', (tester) async {
    await _control(tester, 'reset', {'kbps': '60000'});
    final (controller, trace, ttff) = await _open(
      tester,
      'big4k.mp4',
      minutes: 3,
    );
    await _watch(tester, trace, const Duration(seconds: 60));
    final leave = await _leave(tester);
    trace.dispose();
    _report('memory-4k', {
      'ttffMs': ttff,
      'maxRssMb': trace.maxRss ~/ (1 << 20),
      'rssAtOpenMb': trace.rssAtOpen ~/ (1 << 20),
      'height': controller.value.videoSize?.height,
      'stalls': trace.stalls().count,
      'leaveMs': leave,
    });
  });

  _liveScenario('live-hls-start', (tester, name) async {
    await _control(tester, 'reset', {'kbps': '30000'});
    await _startLiveFeed(tester, 'hls', 6);
    final (controller, trace, ttff) = await _open(
      tester,
      'live/index.m3u8',
      live: true,
    );
    final behind = await _behindRealTime(tester, _pushEpochMs + ttff);
    await _watch(tester, trace, const Duration(seconds: 20));
    final windowMs = controller.value.duration.inMilliseconds;
    final fraction = controller.value.positionFraction;
    final leave = await _leave(tester);
    trace.dispose();
    _report(name, {
      'liveDelayMs': PlayerDiagnostics.liveDelayMs ?? kLiveDelayMs,
      'ttffMs': ttff,
      'behindRealTimeMs': behind,
      'stalls': trace.stalls().count,
      'height': controller.value.videoSize?.height,
      'windowMs': windowMs,
      'fraction': fraction,
      'leaveMs': leave,
    });
  });

  // What the live delay (spec 1.9) is chosen on: a link that dips to
  // 1.5 Mbit/s for 2 s in every 6, and stops for 3 s once.
  _liveScenario('live-hls-jitter', (tester, name) async {
    await _control(tester, 'reset', {'kbps': '30000'});
    await _startLiveFeed(tester, 'hls', 6);
    await _control(tester, 'schedule', {
      'steps': [for (var i = 0; i < 25; i++) '${i * 6}:6000,${i * 6 + 4}:1500']
          .join(','),
    });
    final (controller, trace, ttff) = await _open(
      tester,
      'live/index.m3u8',
      live: true,
    );
    final behind = await _behindRealTime(tester, _pushEpochMs + ttff);
    final from = trace.now;
    await _watch(tester, trace, const Duration(seconds: 40));
    await _control(tester, 'stall', {'secs': '3'});
    await _watch(tester, trace, const Duration(seconds: 50));
    final s = trace.stalls(from: from);
    final after = trace.statesAfter(from);
    final playingAtEnd =
        controller.value.isPlaying && !controller.value.isStalled;
    final leave = await _leave(tester);
    trace.dispose();
    _report(name, {
      'liveDelayMs': PlayerDiagnostics.liveDelayMs ?? kLiveDelayMs,
      'ttffMs': ttff,
      'behindRealTimeMs': behind,
      'stalls': s.count,
      'stalledMs': s.ms,
      'endedOrError': after.endedOrError,
      'startupViews': trace.startupViews,
      'playingAtEnd': playingAtEnd,
      'leaveMs': leave,
    });
  });

  // Android only, and only when asked: the host kills the codec service 12 s
  // after this scenario's first request (Task 12 of the P1 plan), and the
  // screen reopens decoding in software.
  _scenario('codec-death', whenAsked: true, (tester) async {
    await _control(tester, 'reset', {'kbps': '30000'});
    final (controller, trace, ttff) = await _open(tester, 'prog.mp4');
    final from = trace.now;
    await _watch(tester, trace, const Duration(seconds: 75));
    final reopens = [
      for (final e in QoeLog.latest?.events ?? const <QoeEvent>[])
        if (e.kind == QoeEventKind.reopen) e.fields['reason'],
    ];
    var lastMove = -1;
    final after = trace.samples.where((x) => x.t >= from).toList();
    for (var i = 1; i < after.length; i++) {
      if (after[i].pos > after[i - 1].pos) lastMove = after[i].t - from;
    }
    final playingAtEnd =
        controller.value.isPlaying && !controller.value.isStalled;
    final leave = await _leave(tester);
    trace.dispose();
    _report('codec-death', {
      'ttffMs': ttff,
      'reopens': reopens,
      'playingAtEnd': playingAtEnd,
      'lastMoveMs': lastMove,
      'height': controller.value.videoSize?.height,
      'leaveMs': leave,
    });
  });

  // Spec section 8, through the screen's own path (the controls' callbacks):
  // 30 s back in a two-minute window, then LIVE.
  _scenario('live-hls-seek', (tester) async {
    await _control(tester, 'reset', {'kbps': '30000'});
    // A minute of window, so 30 s back has room behind the start delay.
    await _startLiveFeed(tester, 'hls-long', 15);
    final (controller, trace, ttff) = await _open(
      tester,
      'live/index.m3u8',
      live: true,
    );
    await _watch(tester, trace, const Duration(seconds: 6));
    const segment = Duration(seconds: 4);
    final window = LiveWindow.of(controller.value, targetDuration: segment);
    if (window == null) throw TestFailure('no live window was reported');
    final controls = tester.widget<VlcPlayerControls>(
      find.byType(VlcPlayerControls),
    );
    final back = window.step(const Duration(seconds: -30));
    if (back == null) throw TestFailure('no room 30 s back');
    final target =
        controller.value.position + window.length * (back - window.fraction);
    final at = trace.now;
    controls.onLiveSeek!(back);
    await _watch(tester, trace, const Duration(seconds: 15));
    final landed = trace.landing(
      at,
      target.inMilliseconds,
      early: segment.inMilliseconds,
    );
    final behindAfterSeek = LiveWindow.of(
      controller.value,
      targetDuration: segment,
    )?.behind;

    final liveAt = trace.now;
    tester
        .widget<VlcPlayerControls>(find.byType(VlcPlayerControls))
        .onGoLive!();
    await _watch(tester, trace, const Duration(seconds: 15));
    final behindAfterLive = LiveWindow.of(
      controller.value,
      targetDuration: segment,
    )?.behind;
    final reopens = [
      for (final e in QoeLog.latest?.events ?? const <QoeEvent>[])
        if (e.kind == QoeEventKind.reopen) e.fields['reason'],
    ];
    final leave = await _leave(tester);
    trace.dispose();
    _report('live-hls-seek', {
      'ttffMs': ttff,
      'windowMs': window.length.inMilliseconds,
      'stepMs': (window.length * (back - window.fraction)).inMilliseconds,
      'resumeMs': landed?.$1,
      'landedOffMs': landed == null ? null : landed.$2 - target.inMilliseconds,
      'behindAfterSeekMs': behindAfterSeek?.inMilliseconds,
      'liveMs': trace.now - liveAt,
      'behindAfterLiveMs': behindAfterLive?.inMilliseconds,
      'reopens': reopens,
      'stalls': trace.stalls().count,
      'leaveMs': leave,
    });
  });

  // Spec section 8: a paused live stream resumes at the edge (libVLC 3 keeps
  // nothing it skipped), so the delay behind live is the same after a pause.
  _scenario('live-hls-pause', (tester) async {
    await _control(tester, 'reset', {'kbps': '30000'});
    await _startLiveFeed(tester, 'hls', 6);
    final (controller, trace, ttff) = await _open(
      tester,
      'live/index.m3u8',
      live: true,
    );
    await _watch(tester, trace, const Duration(seconds: 6));
    const segment = Duration(seconds: 4);
    final before = LiveWindow.of(
      controller.value,
      targetDuration: segment,
    )?.behind;
    unawaited(controller.pause());
    await _watch(tester, trace, const Duration(seconds: 15));
    final resumeAt = trace.now;
    unawaited(controller.play());
    await _watch(tester, trace, const Duration(seconds: 10));
    final after = LiveWindow.of(
      controller.value,
      targetDuration: segment,
    )?.behind;
    final leave = await _leave(tester);
    trace.dispose();
    _report('live-hls-pause', {
      'ttffMs': ttff,
      'behindBeforeMs': before?.inMilliseconds,
      'behindAfterMs': after?.inMilliseconds,
      'stalls': trace.stalls(from: resumeAt).count,
      'leaveMs': leave,
    });
  });

  // The phase-5 real torrent (spec 5), only when named: it needs the
  // internet and a public swarm.
  _scenario(
    'torrent-sintel',
    (tester) => _torrentRow(tester, 'torrent-sintel', '1080p'),
    whenAsked: true,
  );
  _scenario(
    'torrent-sintel-again',
    (tester) => _torrentRow(tester, 'torrent-sintel-again', '1080p'),
    whenAsked: true,
  );
  _scenario(
    'torrent-sintel-720p',
    (tester) => _torrentRow(tester, 'torrent-sintel-720p', '720p'),
    whenAsked: true,
  );

  // Last: on iOS and Ubuntu today, leaving freezes the app for 130 s.
  _scenario('leave-during-stall-hls', (tester) async {
    await _control(tester, 'reset', {'kbps': '30000'});
    final (_, trace, ttff) = await _open(tester, 'hls/master.m3u8');
    await _watch(tester, trace, const Duration(seconds: 6));
    await _control(tester, 'stall', {'secs': '150'});
    await _watch(tester, trace, const Duration(seconds: 20));
    final leave = await _leave(tester);
    trace.dispose();
    _report('leave-during-stall-hls', {
      'ttffMs': ttff,
      'leaveMs': leave,
      'leaveBlockMs': _lastLeaveBlockMs,
    });
  });
}
