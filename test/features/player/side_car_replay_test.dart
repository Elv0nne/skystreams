/// Recorded libVLC time reports, replayed through the real controller and the
/// side-car view.
///
/// Each trace in `vlc_time_traces/` is libVLC 3.0.24 on macOS running one
/// script - pause at 10 s, play at 13, seek 0.5 s back at 18, 3 s back at 23,
/// 10 s on at 28, 1.5x at 33, 1x at 38, pause at 42, seek 0.4 s back at 43,
/// play at 45, 2x at 50, 1x at 53 - over an MKV file, an MP4 file and an HLS
/// stream, turned into the snapshots a backend sends:
///
///  * `-android`: one per TimeChanged and per state event;
///  * `-desktop`: a 500 ms poll, plus one straight after each command.
///
/// A row is the time since the first Playing event in milliseconds, the state
/// where it changed, the position, and `seek` where a seek was asked for or
/// the speed where it changed. `-truth` is where playback really was, for each
/// stretch between two actions: `start,end,offset,rate`, the position being
/// offset + rate * time.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/side_car_subtitles.dart';
import 'package:skystream/features/player/presentation/vlc/side_car_subtitle_view.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';

import 'fake_vlc_engine.dart';

const String _traces = 'test/features/player/vlc_time_traces';

/// How often the screen is looked at: a frame at 60 Hz.
const Duration _frame = Duration(milliseconds: 16);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Error is the clock less where playback really was, in milliseconds,
  // sampled while playing from 0.8 s after an action to 50 ms before the next.
  // Android hears every time update, so its clock is within milliseconds; an
  // adaptive stream's time is a staircase, and the truth here a line through
  // its freshest steps, so tens either side. The desktops poll twice a second,
  // so their clocks run on from a report up to half a second old: late, but
  // not ahead.
  const bounds = <String, ({int low, int median, int high})>{
    'mkv-android': (low: -20, median: 10, high: 20),
    'mp4-android': (low: -20, median: 10, high: 20),
    'hls-android': (low: -100, median: 20, high: 100),
    'mkv-desktop': (low: -200, median: 60, high: 20),
    'mp4-desktop': (low: -400, median: 200, high: 20),
    'hls-desktop': (low: -500, median: 300, high: 20),
  };

  for (final media in const ['mkv', 'mp4', 'hls']) {
    for (final backend in const ['android', 'desktop']) {
      final trace = '$media-$backend';
      testWidgets('$trace: the clock never steps back, keeps time, and no line '
          'blinks', (tester) async {
        final replay = await _replay(tester, trace, media);
        final errors = replay.errors..sort();
        int at(double share) =>
            errors[((errors.length - 1) * share).round().clamp(
              0,
              errors.length - 1,
            )];
        final summary =
            '${errors.length} samples, error p5 ${at(0.05)} p50 ${at(0.5)} '
            'p95 ${at(0.95)} ms; blinks ${replay.blinks}; '
            'steps back ${replay.stepsBack}';
        final bound = bounds[trace]!;

        expect(replay.stepsBack, isEmpty, reason: summary);
        expect(replay.blinks, isEmpty, reason: summary);
        expect(errors.length, greaterThan(1500), reason: summary);
        expect(at(0.05), greaterThanOrEqualTo(bound.low), reason: summary);
        expect(at(0.5).abs(), lessThanOrEqualTo(bound.median), reason: summary);
        expect(at(0.95), lessThanOrEqualTo(bound.high), reason: summary);
      });
    }
  }

  // An adaptive stream's time is a staircase: it sits still for about a
  // second of wall time, then steps up to where playback is. Played faster,
  // the steps are as far apart in wall time and so further apart in the
  // media: at 3x a report trails the clock three times as far, which is not a
  // step back to take, nor a sign that the clock has run ahead to hold it for.
  // Up to the dialog's 4x.
  for (final speed in const [1.0, 1.5, 2.0, 2.5, 3.0, 4.0]) {
    testWidgets('hls-android staircase at ${speed}x: the clock never steps '
        'back and never stands still', (tester) async {
      final seen = await _staircase(tester, speed);
      expect(seen.stepsBack, isEmpty);
      expect(seen.stills, isEmpty);
    });
  }
}

/// What a replay saw.
class _Replay {
  /// Clock errors against the truth, in milliseconds.
  final List<int> errors = [];

  /// Readings lower than the one before, with no seek asked for in between.
  final List<String> stepsBack = [];

  /// Lines that went and came back within a second and a half, or an older
  /// line after a newer one, with no seek asked for in between.
  final List<String> blinks = [];
}

/// One snapshot row of a trace.
typedef _Row = ({Duration at, String? state, int position, String extra});

/// One stretch of the truth: position = offset + rate * time.
typedef _Stretch = ({double start, double end, double offset, double rate});

Duration _ms(double milliseconds) =>
    Duration(microseconds: (milliseconds * 1000).round());

List<List<String>> _csv(String name) => [
  for (final line in File('$_traces/$name.csv').readAsLinesSync())
    if (line.trim().isNotEmpty) line.split(','),
];

/// A one-second line every 1.37 s from 0.1 s, named C0, C1...: a boundary at
/// every phase of the engine's reports.
String _denseCues() {
  String stamp(int ms) {
    String two(int n) => n.toString().padLeft(2, '0');
    final rest = (ms % 1000).toString().padLeft(3, '0');
    return '00:${two(ms ~/ 60000)}:${two(ms ~/ 1000 % 60)},$rest';
  }

  final srt = StringBuffer();
  for (var i = 0; i < 70; i++) {
    final from = 100 + i * 1370;
    srt.write('${i + 1}\n${stamp(from)} --> ${stamp(from + 1000)}\nC$i\n\n');
  }
  return srt.toString();
}

/// The line numbers on screen.
Set<int> _shown(WidgetTester tester) => {
  for (final text in tester.widgetList<Text>(find.byType(Text)))
    if (text.textSpan?.toPlainText() case final String line
        when line.startsWith('C'))
      int.parse(line.substring(1)),
};

Future<_Replay> _replay(WidgetTester tester, String trace, String media) async {
  final List<_Row> rows = [
    for (final f in _csv(trace))
      (
        at: _ms(double.parse(f[0])),
        state: f[1].isEmpty ? null : f[1],
        position: int.parse(f[2]),
        extra: f.length > 3 ? f[3] : '',
      ),
  ];
  final List<_Stretch> truth = [
    for (final f in _csv('$media-truth'))
      (
        start: double.parse(f[0]),
        end: double.parse(f[1]),
        offset: double.parse(f[2]),
        rate: double.parse(f[3]),
      ),
  ];

  final engine = FakeVlcEngine()..install();
  // Throttled as the player screen throttles it.
  final controller = await engine.attach(
    eventThrottleInterval: const Duration(milliseconds: 250),
  );
  final subtitles = SideCarSubtitles(
    fetch: (url, headers) async => utf8.encode(_denseCues()),
  );
  final [track] = subtitles.replaceSourceTracks([
    (
      url: Uri.parse('https://x/r.srt'),
      label: null,
      language: null,
      headers: null,
    ),
  ]);
  await subtitles.select(track);

  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SideCarSubtitleView(
          controller: controller,
          subtitles: subtitles,
          settings: const PlayerSettings(),
        ),
      ),
    ),
  );

  final replay = _Replay();
  var now = Duration.zero;
  var state = 'playing';
  var speed = 1.0;
  final seeks = <Duration>[];
  Duration? lastReading;
  var seeksSeen = 0;
  var shown = <int>{};
  final hiddenAt = <int, Duration>{};
  var newest = -1;

  bool seekBetween(Duration from, Duration to) =>
      seeks.any((seek) => seek >= from && seek <= to);

  void look() {
    final reading = controller.playbackClock.position;
    final sought = seeks.length != seeksSeen;
    seeksSeen = seeks.length;
    if (lastReading != null && reading < lastReading! && !sought) {
      replay.stepsBack.add(
        '${now.inMilliseconds}: '
        '${lastReading!.inMilliseconds} -> ${reading.inMilliseconds}',
      );
    }
    lastReading = reading;

    final t = now.inMicroseconds / 1000;
    if (state == 'playing') {
      for (final stretch in truth) {
        if (t >= stretch.start + 800 && t <= stretch.end - 50) {
          final real = stretch.offset + stretch.rate * t;
          replay.errors.add((reading.inMicroseconds / 1000 - real).round());
        }
      }
    }

    final visible = _shown(tester);
    if (sought) newest = -1;
    for (final line in visible.difference(shown)) {
      final gone = hiddenAt[line];
      if (gone != null &&
          now - gone < const Duration(milliseconds: 1500) &&
          !seekBetween(gone - _ms(50), now + _ms(50))) {
        replay.blinks.add('C$line @${now.inMilliseconds}');
      } else if (line < newest) {
        replay.blinks.add('C$line after C$newest @${now.inMilliseconds}');
      }
      newest = math.max(newest, line);
    }
    for (final line in shown.difference(visible)) {
      hiddenAt[line] = now;
    }
    shown = visible;
  }

  var next = 0;
  var frameAt = _frame;
  final end = rows.last.at + const Duration(milliseconds: 600);
  while (now < end) {
    final rowAt = next < rows.length ? rows[next].at : null;
    final step = rowAt != null && rowAt <= frameAt ? rowAt : frameAt;
    if (step > now) await tester.pump(step - now);
    now = step;
    if (rowAt != null && rowAt == step) {
      final row = rows[next++];
      state = row.state ?? state;
      if (row.extra == 'seek') {
        seeks.add(now);
        await controller.seekTo(Duration(milliseconds: row.position));
      } else if (row.extra.isNotEmpty) {
        speed = double.parse(row.extra);
      }
      await engine.emit(<String, Object?>{
        'state': state,
        'position': row.position,
        'playbackSpeed': speed,
      });
      await tester.pump();
    } else {
      frameAt += _frame;
    }
    look();
  }

  await engine.emit(<String, Object?>{'state': 'paused', 'position': 0});
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 300));
  subtitles.dispose();
  controller.dispose();
  engine.dispose();
  return replay;
}

/// The 1x stretches of the hls-android trace, each from a second after the
/// action that began it to 50 ms before the next, replayed at [speed]: each
/// report trails where playback is by [speed] times what it trailed by at 1x.
/// Each stretch begins with a seek an hour on from the last.
///
/// Returns the readings lower than the one before, and the frames on which
/// the clock stood still - after the first one and a half seconds of a
/// stretch, which the first report after the seek may hold while the clock
/// waits for it to catch up.
Future<({List<String> stepsBack, List<String> stills})> _staircase(
  WidgetTester tester,
  double speed,
) async {
  final rows = _csv('hls-android');
  final engine = FakeVlcEngine()..install();
  final controller = await engine.attach();
  final stepsBack = <String>[];
  final stills = <String>[];
  var hour = 0;
  for (final f in _csv('hls-truth')) {
    if (double.parse(f[3]) != 1) continue;
    final start = double.parse(f[0]);
    final end = double.parse(f[1]);
    final offset = double.parse(f[2]);
    final reports = [
      for (final row in rows)
        if (double.parse(row[0]) case final at
            when at >= start + 1000 && at <= end - 50)
          (at: at, lag: int.parse(row[2]) - (offset + at)),
    ];
    final base = ++hour * 3600000;
    final first = reports.first.at;
    await controller.seekTo(Duration(milliseconds: base));
    await engine.emit(<String, Object?>{
      'state': 'playing',
      'position': base,
      'playbackSpeed': speed,
    });

    var at = first;
    var lookedAt = at;
    var last = controller.playbackClock.position;
    void look() {
      final reading = controller.playbackClock.position;
      final when = '${speed}x, ${at.round()} ms';
      if (reading < last) {
        stepsBack.add(
          '$when: ${last.inMilliseconds} -> ${reading.inMilliseconds}',
        );
      } else if (reading == last && at > lookedAt && at > first + 1500) {
        stills.add('$when: ${reading.inMilliseconds}');
      }
      last = reading;
      lookedAt = at;
    }

    for (final report in reports.skip(1)) {
      while (at + 16 < report.at) {
        await tester.pump(_frame);
        at += 16;
        look();
      }
      await tester.pump(_ms(report.at - at));
      at = report.at;
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': base + (speed * (at - first + report.lag)).round(),
        'playbackSpeed': speed,
      });
      look();
    }
  }
  await engine.emit(<String, Object?>{'state': 'paused', 'position': 0});
  controller.dispose();
  engine.dispose();
  return (stepsBack: stepsBack, stills: stills);
}
