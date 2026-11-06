/// CloudStream extensions, end to end on a real platform: the path a user takes.
///
/// Settings → CloudStream Extensions → add a repository → install an extension → Search →
/// open a result → Play, then the player must report playback moving forward.
///
/// ```
/// flutter test integration_test/cloudstream/playback_test.dart -d DEVICE --dart-define=CS3_E2E=true
///   [--dart-define=CS3_REPO=REPO_JSON_URL] [--dart-define=CS3_PLUGIN=INTERNAL_NAME]
///   [--dart-define=CS3_QUERY=SEARCH] [--dart-define=CS3_PLAY_SECONDS=20]
/// ```
///
/// Defaults: CloudStream's official repository, Internet Archive, a public-domain film.
/// Lines starting `CS3-E2E` report progress; `CS3-E2E PLAYING` marks the moment to take a
/// screenshot of the device, the video keeps playing for CS3_PLAY_SECONDS after it.
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:skystream/features/search/presentation/widgets/search_result_section.dart';
import 'package:skystream/shared/widgets/custom_widgets.dart';
import 'package:skystream/shared/widgets/multimedia_card.dart';
import 'package:vlc_player/vlc_player.dart';

import 'support.dart';

const _repo = String.fromEnvironment('CS3_REPO', defaultValue: englishRepository);
const _plugin = String.fromEnvironment('CS3_PLUGIN', defaultValue: 'InternetArchiveProvider');
// With the year: archive.org's ranking for the bare title has drifted to podcasts.
const _query = String.fromEnvironment('CS3_QUERY', defaultValue: 'His Girl Friday 1940');
const _playSeconds = int.fromEnvironment('CS3_PLAY_SECONDS', defaultValue: 20);

/// Saves the video frame on screen, taken by libVLC itself, as a PNG in the app's temporary
/// directory: proof of decoded pictures that needs no screen-recording permission.
Future<void> _snapshot(WidgetTester tester, void Function(String) step, String name) async {
  try {
    final controller = tester.widget<VlcPlayer>(find.byType(VlcPlayer)).controller;
    final png = await controller.takeSnapshot(width: 960, height: 540);
    final file = File('${(await getTemporaryDirectory()).path}/cs3-e2e-$name.png');
    await file.writeAsBytes(png);
    step('SNAPSHOT ${file.path} (${png.length} bytes)');
  } catch (error) {
    step('SNAPSHOT failed: $error');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('install a CloudStream extension, find a video and play it', (tester) async {
    final started = DateTime.now();
    void step(String message) => print('CS3-E2E ${DateTime.now().difference(started).inSeconds}s $message');

    await withApp(tester, (container) async {
      // Which way up it opened: a run that leaves a simulator turned shows here, in the next run.
      final opened = tester.view.physicalSize / tester.view.devicePixelRatio;
      step('app started: ${opened.width.round()}x${opened.height.round()}');

      // Settings → CloudStream Extensions, through the tile.
      go(tester, '/settings');
      final tile = find.text('CloudStream Extensions');
      await waitFor(tester, find.text('Settings'));
      await reveal(tester, tile);
      await tester.tap(tile.first);
      await waitFor(tester, find.text('Add Repository'));
      step('CloudStream screen open');

      final install = find.byKey(const ValueKey('cs3_install_$_plugin'));
      final uninstall = find.byKey(const ValueKey('cs3_uninstall_$_plugin'));
      if (uninstall.evaluate().isEmpty) {
        await tester.tap(find.text('Add Repository').first);
        await waitFor(tester, find.byType(TextField));
        await typeInto(tester, find.byType(TextField).last, _repo);
        await tester.tap(find.text('Add').last);
        // Adding fetches the repository; its answer is a snackbar either way.
        await waitFor(tester, find.byType(SnackBar), timeout: const Duration(minutes: 2));
        step('add repository: ${snackBarText(tester)}');
        await tester.tap(find.text('Repositories'));
        await waitFor(tester, install);
        // Tap once the tab has slid in; a slow display (Xvfb) can still be animating it.
        await pumpFor(tester, const Duration(seconds: 2));
        await reveal(tester, install);
        await tester.tap(install.first);
        await waitFor(tester, uninstall, timeout: const Duration(minutes: 5));
      }
      expect(find.textContaining('does not load'), findsNothing, reason: 'the engine failed to load $_plugin');
      step('$_plugin installed');

      // Search, the way a user looks for something to watch.
      go(tester, '/search');
      await waitFor(tester, find.byType(TextField));
      await typeInto(tester, find.byType(TextField).first, _query);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await pumpFor(tester, const Duration(seconds: 1));
      // In a profile build the simulated input action may not reach the field; submit it the way
      // pressing Enter does.
      if (find.textContaining('Press the Search key').evaluate().isNotEmpty) {
        tester.widget<TextField>(find.byType(TextField).first).onSubmitted?.call(_query);
      }
      // The extension's own results: a search asks every provider installed, and another one's
      // (a YouTube video, from a device's own extensions) can come first.
      final section = find.byWidgetPredicate(
        (w) => w is SearchResultSection && w.providerId.contains('/$_plugin/'),
      );
      final result = find.descendant(of: section, matching: find.byType(MultimediaCard));
      await waitFor(tester, result, timeout: const Duration(minutes: 2));
      step('search found ${result.evaluate().length} results from $_plugin');
      // Centred: another provider's row above can leave it at the window's edge, where a tap misses.
      await Scrollable.ensureVisible(tester.element(result.first), alignment: 0.5);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(result.first);

      // Details, then Play. Play shows while the details load, and is enabled once they have
      // episodes; it reads "Resume" once an earlier run saved progress, and names the episode
      // ("Play E1", "Play S1 E1") when archive.org's entry loads as a series, which it sometimes does.
      final playLabel = find.byWidgetPredicate(
        (w) => w is Text && RegExp(r'^(Play|Resume)( S\d+)?( E\d+)?$').hasMatch(w.data ?? ''),
      );
      final play = find.ancestor(of: playLabel, matching: find.byType(CustomButton));
      await pumpUntil(
        tester,
        () => play.evaluate().isNotEmpty && tester.widget<CustomButton>(play.first).onPressed != null,
        what: 'Play to be enabled',
      );
      step('details loaded');
      await tester.ensureVisible(play.first);
      await tester.tap(play.first);

      // The player: wait for the position to move. Getting links runs the extension's own
      // requests first, which can take a while.
      await waitFor(tester, find.byType(VlcPlayer), timeout: const Duration(minutes: 3));
      step('player open');
      // The view is rebuilt when the player moves between sources, so keep its controller.
      final controller = tester.widget<VlcPlayer>(find.byType(VlcPlayer)).controller;
      VlcPlayerValue value() => controller.value;
      var lastState = '';
      try {
        await pumpUntil(
          tester,
          () {
            final v = value();
            final now = '${v.state.name} ${v.position.inSeconds}s${v.errorDescription != null ? ' error: ${v.errorDescription}' : ''}';
            if (now.split(' ').first != lastState.split(' ').first) step('player: $now');
            lastState = now;
            return v.state == VlcPlaybackState.playing && v.position > const Duration(seconds: 3);
          },
          what: 'playback to start',
          timeout: const Duration(minutes: 3),
        );
      } on TestFailure {
        // The player's own words when it gave up, from its failed screen.
        final shown = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().join(' | ');
        step('FAILED player screen: $shown');
        rethrow;
      }
      final startedAt = value().position;
      step('PLAYING at ${startedAt.inSeconds}s of ${value().duration.inMinutes} min');
      await _snapshot(tester, step, 'playing');

      // Adds up forward playback while it plays. The player may reopen the stream on its own
      // (quality change, recovery), so two single readings could miss that it played.
      var played = Duration.zero;
      var reopened = 0;
      var last = value().position;
      final until = DateTime.now().add(const Duration(seconds: _playSeconds));
      while (DateTime.now().isBefore(until)) {
        await tester.pump(const Duration(milliseconds: 250));
        final now = value().position;
        final delta = now - last;
        if (delta > Duration.zero && delta < const Duration(seconds: 3)) played += delta;
        if (delta < -const Duration(seconds: 2)) reopened++;
        last = now;
      }
      final state = value().state;
      await _snapshot(tester, step, 'later');
      step('RESULT played ${played.inSeconds}s in ${_playSeconds}s, now at ${last.inSeconds}s, state ${state.name}'
          '${reopened > 0 ? ', stream reopened $reopened time(s)' : ''}');

      // Leave the player the way a user does, so it saves progress while the app is still up.
      // The player turned a phone to fit the video, and hid the status bar: leaving hands both
      // back. Sampled every 50 ms for 3 s: how long each took after Back.
      final view = tester.view;
      bool sideways() => view.physicalSize.width > view.physicalSize.height;
      // Only a screen that opened upright was turned: a window or a television is wide throughout.
      final turned = opened.height > opened.width && sideways();
      final topBefore = view.viewPadding.top;
      // The bars fade a few seconds in, and the arrow can't be pressed until a tap brings them back.
      if (find.byTooltip('Back').hitTestable().evaluate().isEmpty) {
        final screen = view.physicalSize / view.devicePixelRatio;
        await tester.tapAt(Offset(screen.width / 2, screen.height / 3));
        await pumpUntil(tester, () => find.byTooltip('Back').hitTestable().evaluate().isNotEmpty,
            what: 'the player\'s bars', timeout: const Duration(seconds: 5));
      }
      final sinceBack = Stopwatch()..start();
      await tester.pageBack();
      step('back pressed');
      int? upright, topChanged;
      while (sinceBack.elapsed < const Duration(seconds: 3)) {
        await tester.pump(const Duration(milliseconds: 50));
        if (upright == null && turned && !sideways()) upright = sinceBack.elapsedMilliseconds;
        if (topChanged == null && view.viewPadding.top != topBefore) topChanged = sinceBack.elapsedMilliseconds;
      }
      final size = view.physicalSize / view.devicePixelRatio;
      step('after the player: ${size.width.round()}x${size.height.round()}, '
          'top inset ${(view.viewPadding.top / view.devicePixelRatio).round()}'
          '${turned ? ', upright after ${upright ?? 'never'} ms' : ''}'
          '${topChanged != null ? ', top inset changed after $topChanged ms' : ''}');

      expect(played, greaterThan(const Duration(seconds: _playSeconds ~/ 2)), reason: 'playback did not advance');
    });
  }, skip: skipReason != null, timeout: const Timeout(Duration(minutes: 20)));
}
