/// What the CloudStream integration tests share: starting the app, waiting on the screen,
/// moving between screens, screenshots, and setting CloudStream up.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/cloudstream/cloudstream_models.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/main.dart' as app;

import 'frame_watch.dart';

/// These tests reach real repositories and sites, and install extensions, so they only run when
/// asked to, with `--dart-define=CS3_E2E=true`. CI's smoke runs leave this folder out as well.
const cloudStreamTests = bool.fromEnvironment('CS3_E2E');

/// Why the tests skip when not asked for.
const String? skipReason = cloudStreamTests ? null : 'CloudStream end-to-end tests run with --dart-define=CS3_E2E=true';

/// CloudStream's official repository.
const englishRepository = 'https://raw.githubusercontent.com/recloudstream/extensions/master/repo.json';

/// Starts the app, runs [body] with its provider container, and puts back the error widget
/// SkyStream's main() installs: the test framework checks it was, failure or not.
Future<void> withApp(WidgetTester tester, Future<void> Function(ProviderContainer container) body) async {
  final errorWidgetBuilder = ErrorWidget.builder;
  keepFramesComing();
  try {
    app.main();
    await waitFor(tester, find.byType(Scaffold), timeout: const Duration(minutes: 3));
    await body(ProviderScope.containerOf(tester.element(find.byType(Scaffold).first)));
  } finally {
    ErrorWidget.builder = errorWidgetBuilder;
  }
}

/// Keeps the app's frames coming while this test process runs, and says in the log when they stop
/// anyway (see [FrameWatch]). Every pump waits for a frame, and on a Mac frames stopped while the
/// display slept, so on macOS the display stays awake while the app runs. The iOS simulator's app
/// can't keep the Mac's display awake: run its tests under `caffeinate -di`.
void keepFramesComing() {
  if (_keepingFrames) return;
  _keepingFrames = true;
  if (Platform.isMacOS) {
    unawaited(
      Process.start(
        '/usr/bin/caffeinate',
        ['-di', '-w', '$pid'],
        mode: ProcessStartMode.detached,
      ).then((_) {}, onError: (Object e) => _say('CS3-AWAKE not kept, the display may sleep: $e')),
    );
  }
  // In the root zone: the watch outlives the test that started it.
  Zone.root.run(() => Timer.periodic(const Duration(seconds: 5), (_) => _say(_frames.check(asked: _pumping))));
}

var _keepingFrames = false;
final _frames = FrameWatch(DateTime.now);
var _pumping = false;

/// [WidgetTester.pump], watched by [keepFramesComing].
Future<void> _pump(WidgetTester tester, Duration duration) async {
  keepFramesComing();
  _pumping = true;
  try {
    await tester.pump(duration);
  } finally {
    _pumping = false;
    _say(_frames.frame());
  }
}

/// Prints [line], if there is one: the frame watch's lines belong in the test's log.
void _say(String? line) {
  // ignore: avoid_print
  if (line != null) print(line);
}

/// Pumps frames for [duration] of real time: the app does real network and engine work.
Future<void> pumpFor(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await _pump(tester, const Duration(milliseconds: 200));
  }
}

/// [future]'s value, with frames pumped until it completes. The window must keep drawing: Linux's
/// runner shows it only after a frame, and its hidden pages take input only once it shows.
Future<T> whilePumping<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  future.whenComplete(() => done = true).ignore();
  while (!done) {
    await _pump(tester, const Duration(milliseconds: 100));
  }
  return future;
}

/// Pumps until [done], or fails with what was on screen instead.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  required String what,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await _pump(tester, const Duration(milliseconds: 250));
    if (done()) return;
  }
  final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().take(60).join(' | ');
  throw TestFailure('Timed out waiting for $what. On screen: $texts');
}

/// [finder] is described, not printed: printing a finder lists its last results, and for one kept across tests
/// those can be a previous app's unmounted elements, which throw (P1 Part 4's TV run).
Future<void> waitFor(WidgetTester tester, Finder finder, {Duration timeout = const Duration(minutes: 2)}) =>
    pumpUntil(tester, () => finder.evaluate().isNotEmpty, what: finder.describeMatch(Plurality.many), timeout: timeout);

/// Scrolls the first scrollable until [finder] is built and visible: lists build lazily.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
    if (find.byType(Scrollable).evaluate().isEmpty) break;
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await _pump(tester, const Duration(milliseconds: 200));
  }
  await tester.ensureVisible(finder.first);
  await tester.pump(const Duration(milliseconds: 200));
}

/// Goes to [location]. A snackbar still showing while routes change trips a debug-only Hero
/// assertion, so they go first.
void go(WidgetTester tester, String location) {
  for (final messenger in tester.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
    messenger.clearSnackBars();
  }
  GoRouter.of(tester.element(find.byType(Scaffold).first)).go(location);
}

/// Types [text] into the field [finder] finds. In a profile build the simulated keyboard may not
/// reach the field, so its controller gets the text then.
Future<void> typeInto(WidgetTester tester, Finder finder, String text) async {
  await tester.enterText(finder, text);
  await tester.pump();
  final field = tester.widget<TextField>(finder);
  if (field.controller != null && field.controller!.text != text) {
    field.controller!.text = text;
    await tester.pump();
  }
}

/// The text of the snackbars on screen.
String snackBarText(WidgetTester tester) => [
  for (final bar in tester.widgetList<SnackBar>(find.byType(SnackBar)))
    if (bar.content case final Text text) text.data ?? '',
].join(' | ');

/// Renders what is on screen (or the route holding [of], such as a dialog) to a PNG in the
/// temporary directory, without screen-recording permissions, and returns its path.
Future<String> screenshot(WidgetTester tester, String name, {Finder? of}) async {
  await tester.pump();
  final candidates = of == null
      ? tester.renderObjectList<RenderRepaintBoundary>(find.byType(RepaintBoundary)).toList()
      : tester
            .renderObjectList<RenderRepaintBoundary>(find.ancestor(of: of.first, matching: find.byType(RepaintBoundary)))
            .toList()
            .reversed
            .toList();
  // The page's boundary is the first one with a layer of its own; debugLayer exists only in debug
  // builds, so in profile builds the candidates are tried in turn.
  ui.Image? image;
  Object? failure;
  for (final boundary in candidates.where((b) => b.size.width > 300)) {
    if (kDebugMode && boundary.debugLayer == null) continue;
    try {
      image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
      if (image != null) break;
    } catch (e) {
      failure = e;
    }
  }
  if (image == null) throw StateError('nothing on screen to capture: $failure');
  final bytes = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
  final file = File('${(await getTemporaryDirectory()).path}/$name.png');
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  return file.path;
}

/// Makes sure [internalName] from [repository] is installed, through CloudStream's API rather
/// than its screen. Returns what this added, for [undo].
Future<CloudStreamChanges> ensureInstalled(
  WidgetTester tester,
  ProviderContainer container, {
  String repository = englishRepository,
  required String internalName,
}) async {
  final notifier = container.read(cloudStreamRepositoryProvider.notifier);
  final changes = await CloudStreamChanges.note(tester, container);
  await tester.runAsync(() async {
    final repo = await notifier.addRepository(repository);
    final plugin = repo.plugins.firstWhere((p) => p.internalName == internalName);
    if (container.read(cloudStreamRepositoryProvider).installedFor(plugin) == null) await notifier.install(plugin);
  });
  return changes;
}

/// CloudStream's repositories, installed plugins and removed repositories at one moment, to put
/// a device's own setup back after a test changed it.
class CloudStreamChanges {
  CloudStreamChanges._(this._repositories, this._installed, this._removed);

  /// The device's setup, once CloudStream has read it: noted while it is still loading, the setup
  /// looks empty, and [undo] would remove what the device had.
  static Future<CloudStreamChanges> note(WidgetTester tester, ProviderContainer container) async {
    while (container.read(cloudStreamRepositoryProvider).isLoading) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final state = container.read(cloudStreamRepositoryProvider);
    final prefs = await SharedPreferences.getInstance();
    return CloudStreamChanges._(
      {for (final r in state.repositories) r.url},
      {for (final p in state.installed) CloudStreamRepository.keyOf(p.info)},
      // None counts too: removing a repository marks it as removed by the user, and undo removes.
      prefs.getStringList(CloudStreamRepository.removedReposKey) ?? const [],
    );
  }

  final Set<String> _repositories;
  final Set<String> _installed;
  final List<String> _removed;

  bool hadRepository(String url) => _repositories.contains(url);

  /// Uninstalls the plugins and removes the repositories added since, and puts the removed list
  /// back.
  Future<void> undo(WidgetTester tester, ProviderContainer container) => tester.runAsync(() async {
    final notifier = container.read(cloudStreamRepositoryProvider.notifier);
    final state = container.read(cloudStreamRepositoryProvider);
    for (final plugin in [...state.installed]) {
      if (!_installed.contains(CloudStreamRepository.keyOf(plugin.info))) await notifier.uninstall(plugin);
    }
    for (final CsRepository repo in [...state.repositories]) {
      if (!_repositories.contains(repo.url)) await notifier.removeRepository(repo.url);
    }
    await (await SharedPreferences.getInstance()).setStringList(CloudStreamRepository.removedReposKey, _removed);
  });
}

/// [value] as JSON in ASCII alone, every other character escaped (`\uXXXX`). Windows writes a test's
/// output in its console's code page, which loses emoji and accents; escaped, a report line reads the
/// same on every platform.
String asciiJson(Object? value) => jsonEncode(value)
    .replaceAllMapped(RegExp(r'[^\x00-\x7f]'), (m) => '\\u${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}');
