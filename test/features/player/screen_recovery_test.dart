/// Recovery on the real screen over the fake engine (spec 2): the check, the
/// back-off, the wait, the park, the labels, and what the viewer can do while
/// it recovers.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/domain/qoe_log.dart';
import 'package:skystream/features/player/domain/source_check.dart';
import 'package:skystream/features/player/domain/stream_resolver.dart'
    show ProbeOutcome;
import 'package:skystream/features/player/presentation/vlc/ended_card.dart';
import 'package:skystream/features/player/presentation/vlc/source_check_provider.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_screen.dart'
    show VlcPlayerScreen, openingOverlayKey;
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart' show VlcPlayer, VlcPlayerController;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

const _answers = CheckResult(
  kind: CheckClass.answers,
  outcome: ProbeOutcome.healthy,
  status: 206,
);
const _noAnswer = CheckResult(
  kind: CheckClass.network,
  outcome: ProbeOutcome.unhealthy,
  fault: NetworkFault.refused,
);

/// The screen's wakelock: whether the display is kept on.
class _Wakelock extends WakelockPlusPlatformInterface {
  bool held = false;

  @override
  Future<void> toggle({required bool enable}) async => held = enable;

  @override
  Future<bool> get enabled async => held;
}

/// Two sources on two hosts.
const _two = <StreamResult>[
  StreamResult(url: 'https://a.test/film.m3u8', source: 'A', providerName: 'A'),
  StreamResult(url: 'https://b.test/film.m3u8', source: 'B', providerName: 'B'),
];

/// One source.
const _one = <StreamResult>[
  StreamResult(url: 'https://a.test/film.m3u8', source: 'A', providerName: 'A'),
];

void main() {
  late FakeVlcEngine engine;

  /// What the server answers, by host; a host not listed answers.
  late Map<String, CheckResult> answers;
  late List<String> checked;

  Future<CheckResult> check(StreamResult stream) async {
    final host = Uri.parse(stream.url).host;
    checked.add(host);
    return answers[host] ?? _answers;
  }

  setUp(() {
    engine = FakeVlcEngine()..holdsPictures = true;
    installEngineMocks(engine: engine);
    answers = <String, CheckResult>{};
    checked = <String>[];
  });
  tearDown(removeEngineMocks);

  Future<AppLocalizations> english() =>
      AppLocalizations.delegate.load(const Locale('en'));

  Future<void> play(WidgetTester tester, List<StreamResult> sources) async {
    await pumpPlayer(
      tester,
      preloadedStreams: sources,
      overrides: [sourceCheckProvider.overrideWithValue(check)],
    );
    await sendFirstFrame(tester);
    await sendEvent(tester, snapshot(position: 120000, duration: 5400000));
    await settle(tester);
  }

  Map<Object?, Object?> lastOpen() =>
      engine.callsTo('setSource').last.arguments as Map<Object?, Object?>;

  int opens() => engine.callsTo('setSource').length;

  Future<void> fail(WidgetTester tester) async {
    await sendEvent(tester, snapshot(state: 'error'));
    await settle(tester);
  }

  testWidgets(
    'a failure of a source that played is checked, parked over its picture, '
    'and reopened 1 s later keeping it, where playback was',
    variant: texturePlatform,
    (tester) async {
      final l10n = await english();
      await play(tester, _two);
      final before = opens();

      // The error, and a moment for the check and the park: inside the 1 s
      // back-off.
      await sendSnapshot(tester, snapshot(state: 'error'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(checked, ['a.test']);
      // The park: the same media, held, not told to play.
      expect(opens(), before + 1);
      expect(lastOpen()['keepPicture'], isTrue);
      expect(lastOpen()['autoPlay'], isFalse);
      expect(find.byKey(openingOverlayKey), findsNothing);
      expect(find.text(l10n.playerReconnecting), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(opens(), before + 2);
      expect(lastOpen()['uri'], 'https://a.test/film.m3u8');
      expect(lastOpen()['keepPicture'], isTrue);
      expect(lastOpen()['autoPlay'], isTrue);
      expect(lastOpen()['startPosition'], 120000);
      expect(find.byType(VlcPlayerControls), findsOneWidget);
      expect(find.text(l10n.playerReconnecting), findsOneWidget);

      await engine.endHold(snapshot(position: 120400, duration: 5400000));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(l10n.playerReconnecting), findsNothing);

      await sendEvent(tester, snapshot(state: 'paused'));
    },
  );

  testWidgets(
    'no answer waits over the picture, says Reconnecting…, and reopens the '
    'moment the server answers',
    variant: texturePlatform,
    (tester) async {
      final l10n = await english();
      await play(tester, _one);
      answers['a.test'] = _noAnswer;

      await fail(tester);
      final parked = opens();
      // A minute of no answer: checks every 2 s, nothing reopened.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(seconds: 2));
      }
      expect(opens(), parked);
      expect(checked.length, greaterThanOrEqualTo(30));
      expect(find.text(l10n.playerReconnecting), findsOneWidget);
      expect(find.byKey(openingOverlayKey), findsNothing);

      answers.remove('a.test');
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);

      expect(opens(), parked + 1);
      expect(lastOpen()['autoPlay'], isTrue);
      expect(lastOpen()['keepPicture'], isTrue);

      final waits = QoeLog.latest!.events
          .where((e) => e.kind == QoeEventKind.wait)
          .toList();
      expect(waits.single.fields['label'], 'reconnecting');
      expect(
        QoeLog.latest!.events.where((e) => e.kind == QoeEventKind.waitEnd),
        hasLength(1),
      );

      await sendEvent(tester, snapshot(state: 'paused'));
    },
  );

  testWidgets(
    'offline: Waiting for network…, nothing checked until the network comes '
    'back, then checked at once',
    variant: texturePlatform,
    (tester) async {
      final l10n = await english();
      await play(tester, _one);
      await sendConnectivity(tester, ['none']);

      await fail(tester);
      checked.clear();
      await tester.pump(const Duration(seconds: 5));

      expect(find.text(l10n.playerWaitingForNetwork), findsOneWidget);
      expect(checked, isEmpty);

      await sendConnectivity(tester, ['wifi']);
      await settle(tester);

      expect(checked, ['a.test']);
      expect(lastOpen()['autoPlay'], isTrue);

      await sendEvent(tester, snapshot(state: 'paused'));
    },
  );

  testWidgets(
    "a film's real end, and the stop libVLC sends after it, leave the ended "
    'card up and reopen nothing',
    variant: texturePlatform,
    (tester) async {
      // Every backend follows an end with a stop, its input gone: the
      // player_defaults device test reads "... playing ended stopped" on all
      // five. Read as a stop nobody asked for, it reopened the film's last
      // seconds at 1, 2, 4 and 8 s, then failed over (P1 Part 3 review,
      // finding 1).
      await pumpPlayer(
        tester,
        preloadedStreams: _one,
        overrides: [sourceCheckProvider.overrideWithValue(check)],
      );
      await sendFirstFrame(tester);
      await sendEvent(tester, snapshot(position: 1199000, duration: 1200000));
      await settle(tester);
      final before = opens();

      await sendEvent(tester, snapshot(state: 'ended'));
      await sendEvent(tester, snapshot(state: 'stopped'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 20));
      await settle(tester);

      expect(find.byKey(endedCardKey), findsOneWidget);
      expect(opens(), before, reason: 'nothing reopens');
      expect(checked, isEmpty, reason: 'nothing is checked');
      expect([
        for (final e in QoeLog.latest!.events)
          if (e.kind == QoeEventKind.error) e.fields['sign'],
      ], isEmpty);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a film opened while offline opens again when the network comes back',
    variant: texturePlatform,
    (tester) async {
      // One source, never played: the network coming back is no proof it's
      // dead, and giving it up there left the failed screen as the network
      // returned (P1 Part 3 review, finding 2).
      final l10n = await english();
      await pumpPlayer(
        tester,
        preloadedStreams: _one,
        overrides: [sourceCheckProvider.overrideWithValue(check)],
      );
      await sendConnectivity(tester, ['none']);
      await fail(tester);
      final before = opens();
      await tester.pump(const Duration(seconds: 5));

      await sendConnectivity(tester, ['wifi']);
      await settle(tester);

      expect(opens(), before + 1, reason: 'opened again, not given up');
      expect(lastOpen()['uri'], 'https://a.test/film.m3u8');
      expect(find.text(l10n.playerNoSourcesPlayable(1)), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final pictured in const [false, true]) {
    testWidgets(
      'a play during a wait that fails again goes back to the policy, '
      '${pictured ? 'after' : 'before'} its picture',
      variant: texturePlatform,
      (tester) async {
        // The play of a parked media is a new attempt, with its own edges,
        // clocks and checks: a second error of the same kind was swallowed
        // (P1 Part 3 review, finding 3).
        answers['a.test'] = _noAnswer;
        await play(tester, _one);
        await fail(tester);
        await tester.pump(const Duration(seconds: 3));
        List<Object?> signs() => [
          for (final e in QoeLog.latest!.events)
            if (e.kind == QoeEventKind.error) e.fields['sign'],
        ];
        expect(signs(), ['engineError']);

        final controller = tester
            .widget<VlcPlayer>(find.byType(VlcPlayer))
            .controller;
        unawaited(controller.play());
        await sendEvent(tester, snapshot(position: 120000, duration: 5400000));
        if (pictured) {
          await sendEvent(
            tester,
            snapshot(position: 121000, duration: 5400000),
          );
        }
        await settle(tester);
        await fail(tester);

        expect(signs(), ['engineError', 'engineError']);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    "a report from the failed player while it is parked isn't the viewer's "
    'play',
    variant: texturePlatform,
    (tester) async {
      // A starved or pictureless player is still sending snapshots when the
      // park replaces it: one already on its way, saying playing, ended the
      // recovery as if the viewer had pressed play (P1 Part 3 review,
      // finding 4).
      final l10n = await english();
      answers['a.test'] = _noAnswer;
      await play(tester, _one);
      final held = engine.holdNextReply('setSource');
      await sendSnapshot(tester, snapshot(state: 'error'));
      await tester.pump(const Duration(milliseconds: 50));

      await sendEvent(tester, snapshot(position: 121000, duration: 5400000));
      held.complete();
      await settle(tester);
      await tester.pump(const Duration(seconds: 3));

      expect(find.text(l10n.playerReconnecting), findsOneWidget);
      expect(
        [
          for (final e in QoeLog.latest!.events)
            if (e.kind == QoeEventKind.firstFrame) e,
        ],
        hasLength(1),
        reason: 'no first frame of the parked media',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a source that never played fails over at once, with the start-up view '
    'naming the next',
    variant: texturePlatform,
    (tester) async {
      await pumpPlayer(
        tester,
        preloadedStreams: _two,
        overrides: [sourceCheckProvider.overrideWithValue(check)],
      );

      await fail(tester);

      expect(lastOpen()['uri'], 'https://b.test/film.m3u8');
      expect(lastOpen().containsKey('keepPicture'), isFalse);
      expect(find.byKey(openingOverlayKey), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a seek while reconnecting moves where the reopen starts',
    variant: texturePlatform,
    (tester) async {
      await play(tester, _one);
      answers['a.test'] = _noAnswer;
      await fail(tester);
      final controller = tester
          .widget<VlcPlayerControls>(find.byType(VlcPlayerControls))
          .controller;

      await controller.seekTo(const Duration(minutes: 10));
      await tester.pump(VlcPlayerController.seekMergeWindow);
      answers.remove('a.test');
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);

      expect(lastOpen()['startPosition'], 600000);

      await sendEvent(tester, snapshot(state: 'paused'));
    },
  );

  testWidgets(
    'a pause during a wait opens the reopen paused',
    variant: texturePlatform,
    (tester) async {
      await play(tester, _one);
      answers['a.test'] = _noAnswer;
      await fail(tester);
      final controller = tester
          .widget<VlcPlayerControls>(find.byType(VlcPlayerControls))
          .controller;

      await controller.pause();
      answers.remove('a.test');
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);

      expect(lastOpen()['autoPlay'], isFalse);
      expect(lastOpen()['keepPicture'], isTrue);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a pick during a wait replaces the recovery',
    variant: texturePlatform,
    (tester) async {
      await play(tester, _two);
      answers['a.test'] = _noAnswer;
      answers['b.test'] = _noAnswer;
      await fail(tester);
      final state = tester.state(find.byType(VlcPlayerScreen)) as dynamic;

      // The startup view's row, as a remote picks it: B, not on trial.
      state.debugPickSource(1);
      await settle(tester);
      final afterPick = opens();
      checked.clear();
      await tester.pump(const Duration(seconds: 10));

      expect(lastOpen()['uri'], 'https://b.test/film.m3u8');
      expect(opens(), afterPick, reason: 'the old recovery reopened nothing');
      expect(checked, isNot(contains('a.test')));

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'leaving during a check leaves nothing running',
    variant: texturePlatform,
    (tester) async {
      final held = Completer<CheckResult>();
      await pumpPlayer(
        tester,
        preloadedStreams: _one,
        overrides: [
          sourceCheckProvider.overrideWithValue((stream) => held.future),
        ],
      );
      await sendFirstFrame(tester);
      await settle(tester);
      await fail(tester);

      await tester.pumpWidget(const SizedBox());
      held.complete(_answers);
      await tester.pump(const Duration(minutes: 1));

      // flutter_test fails the test on a timer still pending here.
    },
  );

  testWidgets(
    'a source that answers but keeps failing ends on the failed screen with '
    'Retry',
    variant: texturePlatform,
    (tester) async {
      final l10n = await english();
      await play(tester, _one);

      for (var i = 0; i < 5; i++) {
        await fail(tester);
        await tester.pump(const Duration(seconds: 9));
        await settle(tester);
        if (find.text(l10n.retry).evaluate().isNotEmpty) break;
        await engine.endHold(snapshot(position: 120400, duration: 5400000));
        await tester.pump(const Duration(milliseconds: 400));
      }

      expect(find.text(l10n.retry), findsOneWidget);
      expect(
        QoeLog.latest!.events.where((e) => e.kind == QoeEventKind.gaveUp),
        hasLength(1),
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  /// Watches the screen's wakelock for the rest of the test.
  _Wakelock watchWakelock() {
    final wakelock = _Wakelock();
    final before = wakelockPlusPlatformInstance;
    wakelockPlusPlatformInstance = wakelock;
    addTearDown(() => wakelockPlusPlatformInstance = before);
    return wakelock;
  }

  testWidgets(
    'a wait that never ends lets the display sleep after 30 minutes',
    variant: texturePlatform,
    (tester) async {
      // A played source whose server never answers waits for ever (spec 2),
      // and a phone left on "Reconnecting..." stayed lit all night (P1 Part 3
      // review, finding 7).
      final wakelock = watchWakelock();
      answers['a.test'] = _noAnswer;
      await play(tester, _one);
      await fail(tester);
      await tester.pump(const Duration(minutes: 29));
      expect(wakelock.held, isTrue, reason: 'a wait keeps the screen on');

      await tester.pump(const Duration(minutes: 2));
      expect(wakelock.held, isFalse, reason: 'not all night');

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the screen stays awake while recovery waits over the picture',
    variant: texturePlatform,
    (tester) async {
      // A not-playing edge after a picture lets the display sleep, and a
      // dropped file says ended: a phone slept through the wait, and the
      // reopen played its sound to a dark screen.
      final l10n = await english();
      final wakelock = watchWakelock();
      answers['a.test'] = _noAnswer;
      await play(tester, _one);
      expect(wakelock.held, isTrue, reason: 'playing');

      await sendEvent(
        tester,
        snapshot(state: 'ended', position: 130000, duration: 5400000),
      );
      await settle(tester);
      await tester.pump(const Duration(seconds: 10));

      expect(find.text(l10n.playerReconnecting), findsOneWidget);
      expect(wakelock.held, isTrue, reason: 'recovery is waiting');

      await sendEvent(tester, snapshot(state: 'paused'));
    },
  );

  testWidgets(
    'the failed screen lets the display sleep, and Retry wakes it',
    variant: texturePlatform,
    (tester) async {
      final l10n = await english();
      final wakelock = watchWakelock();
      answers['a.test'] = _noAnswer;
      await pumpPlayer(
        tester,
        preloadedStreams: _one,
        overrides: [sourceCheckProvider.overrideWithValue(check)],
      );
      await settle(tester);

      // It never plays, and its server never answers: recovery waits, then
      // gives up.
      await fail(tester);
      for (var i = 0; i < 12 && find.text(l10n.retry).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(seconds: 5));
        await settle(tester);
      }
      expect(find.text(l10n.retry), findsOneWidget);
      expect(
        wakelock.held,
        isFalse,
        reason: 'nothing plays on the failed screen',
      );

      await tester.tap(find.text(l10n.retry));
      await settle(tester);
      expect(wakelock.held, isTrue, reason: 'Retry opens again');

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a live feed that drops reconnects 2 s later at the live start, keeping '
    'the picture',
    variant: texturePlatform,
    (tester) async {
      final l10n = await english();
      const url = 'https://a.test/live/index.m3u8';
      await pumpPlayer(
        tester,
        item: MultimediaItem(
          title: 'Channel',
          url: url,
          posterUrl: '',
          contentType: MultimediaContentType.livestream,
          provider: 'Remote',
        ),
        videoUrl: url,
        overrides: [sourceCheckProvider.overrideWithValue(check)],
      );
      await sendFirstFrame(tester);
      await settle(tester);
      final before = opens();

      await sendEvent(tester, snapshot(state: 'ended'));
      await settle(tester);
      expect(find.text(l10n.playerReconnecting), findsOneWidget);
      expect(find.byKey(openingOverlayKey), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      await settle(tester);

      expect(opens(), before + 2, reason: 'the park, then the reconnect');
      expect(lastOpen()['keepPicture'], isTrue);
      expect(lastOpen().containsKey('startPosition'), isFalse);

      await sendEvent(tester, snapshot(state: 'paused'));
    },
  );

  testWidgets(
    'a failure reported again during its recovery changes nothing: a viewer '
    'who paused finds the reopen paused',
    variant: texturePlatform,
    (tester) async {
      final held = Completer<CheckResult>();
      await pumpPlayer(
        tester,
        preloadedStreams: _one,
        overrides: [
          sourceCheckProvider.overrideWithValue((stream) => held.future),
        ],
      );
      await sendFirstFrame(tester);
      await sendEvent(tester, snapshot(position: 120000, duration: 5400000));
      await settle(tester);
      // A stall: recovery checks and keeps the player, which libVLC may yet
      // ride out.
      for (var i = 0; i < 27; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      final controller = tester
          .widget<VlcPlayerControls>(find.byType(VlcPlayerControls))
          .controller;

      // The viewer pauses while the check is out, and then the stalled
      // player errors: the same failure, reported again.
      await controller.pause();
      await fail(tester);
      held.complete(_answers);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(
        QoeLog.latest!.events.where(
          (e) => e.kind == QoeEventKind.error && e.fields['sign'] != null,
        ),
        hasLength(1),
      );
      expect(lastOpen()['autoPlay'], isFalse, reason: 'the viewer paused');

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a picture that never reaches the screen goes behind the start-up view, '
    'saying why',
    variant: texturePlatform,
    (tester) async {
      final l10n = await english();
      await play(tester, _one);
      engine.decodedPictures(displayed: 0, lost: 0);

      var position = 120000;
      // Stopped the moment the source is given up on: after the park the
      // engine reports nothing more, and a position fed past it would read as
      // the viewer playing the parked media.
      final before = opens();
      for (var i = 0; i < 16 && opens() == before; i++) {
        position += 1000;
        await sendSnapshot(tester, <String, Object?>{
          ...snapshot(position: position, duration: 5400000),
          'videoSize': <String, Object?>{'width': 1920, 'height': 1080},
        });
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 700));
      }
      await settle(tester);

      expect(find.byKey(openingOverlayKey), findsOneWidget);
      expect(
        find.textContaining(l10n.playerReasonSourceNeverStarted),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
    },
  );
}
