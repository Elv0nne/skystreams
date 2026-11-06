import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/playback_recovery.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

/// A seek is not a dead source, however long it takes to land.
///
/// Seeking freezes the reported position on purpose: the demuxer repositions
/// and refills before it reports anything at the new place, and every backend
/// keeps publishing the OLD position while that happens. The watchdog only
/// asks whether the position moved, so on a slow source that freeze outlasts
/// [kStallRecoverAfter] and the source is declared dead.
///
/// What the viewer saw: skip forward, "Reconnecting", then the media reopened -
/// duration blank, position back at zero, and every audio and subtitle track
/// back at the engine's own choice, because a reopen restores the position and
/// nothing else.
void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  Future<AppLocalizations> english() =>
      AppLocalizations.delegate.load(const Locale('en'));

  testWidgets(
    'a seek that takes longer than the recover threshold is not a dead source',
    variant: texturePlatform,
    (tester) async {
      await pumpPlayer(tester);
      await sendFirstFrame(tester);

      final opensBefore =
          engine.methods.where((m) => m == 'setSource').length;
      expect(opensBefore, 1, reason: 'one open so far: the media playing');

      // Let the source go quiet for most of the recover window first. This is
      // the ordinary state of a stream that is working hard - the watchdog is
      // already part-wound when the viewer reaches for the scrubber.
      for (var i = 0; i < kStallRecoverAfter.inSeconds - 5; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(
        engine.methods.where((m) => m == 'setSource').length,
        opensBefore,
        reason: 'not given up on yet',
      );

      // Now the viewer skips. Every seek in the player funnels through this
      // controller, and the engine deliberately answers with nothing: a
      // backend keeps publishing the OLD position until it has decoded a frame
      // at the new one, which is exactly the freeze being measured.
      final player = tester.widget<VlcPlayer>(
        find.byType(VlcPlayer, skipOffstage: false),
      );
      await player.controller.seekTo(const Duration(minutes: 10));
      await tester.pump();
      expect(engine.methods, contains('seekTo'));

      // Ten more seconds of freeze. Measured from before the seek that is past
      // the threshold and the media gets reopened - which restores the
      // position and nothing else, so every audio and subtitle choice reverts.
      // Measured from the seek it is well inside the window.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(
        engine.methods.where((m) => m == 'setSource').length,
        opensBefore,
        reason: 'a seek must not make the player re-open the media',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a nudge while a seek is on its way re-sends the seek, not the old '
    'position',
    variant: texturePlatform,
    (tester) async {
      // The nudge re-seeks to shake a quiet source loose. Taken from the
      // published position it went to the place the viewer had just left -
      // every backend keeps publishing that until the seek lands - so a skip
      // on a slow source ended with the picture jumping back and
      // "Reconnecting" on screen.
      await pumpPlayer(tester);
      await sendFirstFrame(tester);
      final player = tester.widget<VlcPlayer>(
        find.byType(VlcPlayer, skipOffstage: false),
      );

      await player.controller.seekTo(const Duration(minutes: 10));
      for (var i = 0; i < kStallNudgeAfterSeek.inSeconds + 1; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      final seeks = <Object?>[
        for (final call in engine.callsTo('seekTo'))
          (call.arguments as Map)['position'],
      ];
      expect(seeks.length, greaterThan(1), reason: 'the nudge seeked');
      expect(seeks.last, const Duration(minutes: 10).inMilliseconds);

      await tester.pumpWidget(const SizedBox());
    },
  );

  /// Stats as the engine reports them, with [read] bytes fetched so far.
  void fetched(int read) {
    engine.mediaStats = <String, Object?>{
      'available': true,
      'displayedPictures': 100,
      'lostPictures': 0,
      'readBytes': read,
      'demuxReadBytes': 1000000,
    };
  }

  testWidgets(
    'a seek still refilling is not nudged, and not called a reconnect',
    variant: texturePlatform,
    (tester) async {
      // After a seek a 4K remux fetches its keyframe run-up and three seconds
      // of buffer before it plays again, which on an ordinary line outlasts
      // the nudge. The nudge's fresh request threw the refill away and
      // started it over, with "Reconnecting" on screen the whole time.
      await pumpPlayer(tester);
      await sendFirstFrame(tester);
      final l10n = await english();
      final player = tester.widget<VlcPlayer>(
        find.byType(VlcPlayer, skipOffstage: false),
      );
      final opensBefore = engine.methods.where((m) => m == 'setSource').length;

      await player.controller.seekTo(const Duration(minutes: 10));
      var read = 50000000;
      for (var i = 0; i < kStallRecoverAfter.inSeconds + 5; i++) {
        read += 2000000;
        fetched(read);
        await tester.pump(const Duration(seconds: 1));
      }

      expect(engine.callsTo('seekTo'), hasLength(1), reason: 'no nudge');
      expect(find.text(l10n.playerReconnecting), findsNothing);
      expect(
        engine.methods.where((m) => m == 'setSource').length,
        opensBefore,
        reason: 'nor a reopen at the usual deadline',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'one whose bytes have stopped as well is nudged as before',
    variant: texturePlatform,
    (tester) async {
      // The counters are there and say nothing is coming: a half-open socket,
      // which is what the nudge is for.
      await pumpPlayer(tester);
      await sendFirstFrame(tester);
      final l10n = await english();
      final player = tester.widget<VlcPlayer>(
        find.byType(VlcPlayer, skipOffstage: false),
      );

      fetched(50000000);
      await player.controller.seekTo(const Duration(minutes: 10));
      for (var i = 0; i < kStallNudgeAfterSeek.inSeconds + 2; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(engine.callsTo('seekTo').length, greaterThan(1));
      expect(find.text(l10n.playerReconnecting), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a refill after a seek gets longer before it is called a reconnect',
    variant: texturePlatform,
    (tester) async {
      // With no counters to go by - libVLC's stand still while its input
      // thread waits on the refill - a seek still gets time for its keyframe
      // run-up and buffer before anyone says "Reconnecting".
      await pumpPlayer(tester);
      await sendFirstFrame(tester);
      final l10n = await english();
      final player = tester.widget<VlcPlayer>(
        find.byType(VlcPlayer, skipOffstage: false),
      );

      await player.controller.seekTo(const Duration(minutes: 10));
      for (var i = 0; i < kStallNudgeAfter.inSeconds + 5; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(engine.callsTo('seekTo'), hasLength(1), reason: 'no nudge yet');
      expect(find.text(l10n.playerReconnecting), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a freeze nobody asked for is still caught',
    variant: texturePlatform,
    (tester) async {
      // The other half, and the one a blanket suppression would break: without
      // a seek the watchdog must still speak up.
      await pumpPlayer(tester);
      await sendFirstFrame(tester);
      final l10n = await english();

      for (var i = 0; i < 11; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(find.text(l10n.playerReconnecting), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );
}
