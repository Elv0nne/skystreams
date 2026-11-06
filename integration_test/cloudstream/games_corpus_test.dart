/// Ayu's games on a device (Phase 7c part 1). For each game:
/// - Play opens it full screen: its window asks for the whole screen, and no sheet shows.
/// - On the JVM its page finishes, START starts it, and its frame rate is read over 2 s.
/// - Two Backs a second apart save and close it, and the Play call ends with no links, saying a full-screen window
///   showed.
/// One `CS3-GAMES {json}` line per game. A game that fails says why in its line, and the run goes on.
///
/// For the matrix (Phase 7c part 3), `GAMES_SAVES` adds a game's saves to it:
/// - after START, 20 s of play, then its frame rate, and a save to slot 1 from the page's own menu (its message);
/// - the save's length as the extension keeps it and as the page keeps it, then Back twice;
/// - Play again: the page offers RESUME, RESUME restores the game and loading slot 1 restores the save (their messages).
/// 2048 and Flappy Bird keep no saves: they start and close. On Android the app can't script the extension's own
/// WebView: the test opens each game, prints `CS3-MATRIX ready NAME ROUND`, and waits while the Mac-side driver
/// (`cdp/matrix.mjs` in the part's workspace: Chrome's remote debugging, and adb's Back key) plays and closes it.
///
/// `GAMES_AUDIO` (the JVM) adds whether Flappy Bird's sounds can play (`audio` in its line): what its browser says of
/// Ogg Vorbis and MP3, its buzz.js sounds' states, and its wing sound loaded from the served folder and from a blob of
/// the same bytes. The served copy failing where the blob plays points at the server (byte ranges), not the format.
///
/// For Android's frame-rate check (Task 9):
/// - `GAMES_HOLD_S` holds each game that long after it shows, before its Backs, drawing none of the app's frames, as a
///   game session doesn't (the test's own frames would compete with the lent page's).
/// - `GAMES_NATIVE` is the check's own build, where full-screen windows show natively. No view is waited for, and the
///   check's script closes the game.
///
/// ```
/// flutter test integration_test/cloudstream/games_corpus_test.dart -d DEVICE --dart-define=CS3_E2E=true \
///   [--dart-define=GAMES_ONLY=all|Castlevania,Game2048] [--dart-define=GAMES_HOLD_S=90] [--dart-define=GAMES_NATIVE=true] \
///   [--dart-define=GAMES_SAVES=true] [--dart-define=GAMES_AUDIO=true]
/// ```
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_pages.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_full_screen.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_sheet.dart';

import 'support.dart';

const _repo = 'https://raw.githubusercontent.com/errorcode26/Ayu-CloudStream-Games/builds/repo.json';
const _all = [
  'AriaOfSorrow',
  'AvatarAirbender',
  'Castlevania',
  'Contra',
  'DesertStrike',
  'Doom',
  'FlappyBird',
  'Game2048',
  'JackieChan',
  'LittleMermaid',
  'MedalOfHonor',
  'MetalSlugAdvance',
  'MinishCap',
  'OnePiece',
  'Pokemon',
  'PrinceOfPersia',
  'SeriousSam',
  'SuperMario',
  'TekkenAdvance',
  'TombRaider',
  'Zelda',
];
const _only = String.fromEnvironment(
  'GAMES_ONLY',
  defaultValue: 'Castlevania,Contra,SuperMario,Zelda,Game2048,FlappyBird',
);
const _holdS = int.fromEnvironment('GAMES_HOLD_S');
const _native = bool.fromEnvironment('GAMES_NATIVE');
const _saves = bool.fromEnvironment('GAMES_SAVES');
const _audio = bool.fromEnvironment('GAMES_AUDIO');

/// The games that keep saves (the GBA and NES pages): all but 2048 and Flappy Bird.
bool _keepsSaves(String name) => name != 'Game2048' && name != 'FlappyBird';

/// Presses START (the GBA and NES pages); 2048 and Flappy Bird start on a key or a tap.
const _start =
    "(() => { const b = document.getElementById('btn-play'); if (b) { b.click(); return 'START'; } return 'no START'; })()";

/// Starts counting the page's frames, by its own requestAnimationFrame: one loop, however often it's asked.
const _countFrames =
    '(() => { window.__cs3Frames = 0; if (!window.__cs3Counting) { window.__cs3Counting = true; '
    '(function tick() { window.__cs3Frames++; requestAnimationFrame(tick); })(); } return true; })()';

/// Starts Flappy Bird's sound probe (`GAMES_AUDIO`): `window.__cs3Audio` gets what its browser says of Ogg Vorbis and
/// MP3, and how its wing sound loads, from the served folder (`served`) and from a blob of the same bytes (`blob`): the
/// media events seen, and the first of `canplaythrough`, `playing` or `error` (else `timeout`). Each tries a muted play
/// too, as WebKit on iOS buffers no media before one.
const _audioStart = r"""(() => {
  const out = window.__cs3Audio = {ogg: '', mp3: '', served: null, blob: null};
  const el = document.createElement('audio');
  out.ogg = el.canPlayType('audio/ogg; codecs="vorbis"');
  out.mp3 = el.canPlayType('audio/mpeg');
  const probe = (src, key) => {
    const a = new Audio();
    const seen = [];
    const done = (what) => {
      // NaN and Infinity as text: the browsers' evaluate answers null for a value JSON can't hold.
      const duration = isFinite(a.duration) ? a.duration : String(a.duration);
      if (!out[key]) out[key] = {what: what, seen: seen, ready: a.readyState, error: a.error ? a.error.code : null, duration: duration};
    };
    ['loadedmetadata', 'canplay', 'canplaythrough', 'playing'].forEach((e) => a.addEventListener(e, () => {
      seen.push(e);
      if (e === 'canplaythrough' || e === 'playing') done(e);
    }));
    a.addEventListener('error', () => done('error'));
    a.preload = 'auto';
    a.muted = true;
    a.src = src;
    a.load();
    const playing = a.play();
    if (playing && playing.catch) playing.catch((e) => seen.push('play: ' + e.name));
    setTimeout(() => done('timeout'), 8000);
  };
  probe('assets/sounds/sfx_wing.ogg', 'served');
  fetch('assets/sounds/sfx_wing.ogg').then((r) => r.blob()).then(
    (b) => probe(URL.createObjectURL(b), 'blob'),
    (e) => { out.blob = {what: 'fetch failed: ' + e}; });
  return true;
})()""";

/// The sound probe's results, with the states of the page's own buzz.js sounds.
const _audioRead = r"""(() => {
  const out = window.__cs3Audio || {};
  try {
    out.sounds = ((window.buzz && buzz.sounds) || []).map((s) => ({
      ready: s.sound.readyState, network: s.sound.networkState, error: s.sound.error ? s.sound.error.code : null}));
  } catch (e) {
    out.sounds = String(e);
  }
  return out;
})()""";

/// Whether the page offers RESUME: its button shows when the game has a save.
const _resumeOffered =
    "(() => { const b = document.getElementById('btn-resume'); return !!b && getComputedStyle(b).display !== 'none'; })()";

/// Saves to slot 1 from the page's own menu, and closes the menu: the page's message.
const _saveSlot1 =
    "(() => { const g = (id) => document.getElementById(id); g('btn-open-menu').click(); g('slot-seg-1').click(); "
    "g('menu-btn-save').click(); const message = g('toast').innerText; g('menu-btn-resume').click(); return message; })()";

/// RESUME: the game restores its last state: the page's message.
const _resume =
    "(() => { document.getElementById('btn-resume').click(); return document.getElementById('toast').innerText; })()";

/// Loads slot 1 from the page's own menu: the page's message.
const _loadSlot1 =
    "(() => { const g = (id) => document.getElementById(id); g('btn-open-menu').click(); g('slot-seg-1').click(); "
    "g('menu-btn-load').click(); const message = g('toast').innerText; "
    "if (getComputedStyle(g('system-menu')).display !== 'none') g('menu-btn-resume').click(); return message; })()";

/// The slot-1 save's length as the extension keeps it (an answering call: the NES pages' key is the game's, the GBA
/// pages' `slot1`), and as the page keeps it (localStorage).
const _savedLengths =
    "(() => { const key = typeof getSlotStorageKey === 'function' ? getSlotStorageKey(1) : 'slot1'; "
    "const app = window.AndroidApp && AndroidApp.loadGameState ? String(AndroidApp.loadGameState(key) || '').length : null; "
    "const page = Object.keys(localStorage).filter((k) => /_slot1\$/.test(k)).map((k) => localStorage.getItem(k).length); "
    "return {app: app, page: page}; })()";

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    "Ayu's games: full screen, Back twice closes them, and Play ends quietly",
    (tester) async {
      await withApp(tester, (container) async {
        final host = container.read(cloudStreamEngineHostProvider);
        final notifier = container.read(cloudStreamRepositoryProvider.notifier);
        final changes = await CloudStreamChanges.note(tester, container);
        final events = <Map<String, dynamic>>[];
        // Each event with the time it came, for when a game's window went against when its call answered.
        final listening = host.events.listen((event) => events.add({...event, 'at': DateTime.now()}));
        try {
          final names = _only == 'all' ? _all : _only.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
          for (final name in names) {
            final line = <String, Object?>{'game': name};
            try {
              await _game(tester, host, notifier, events, name, line);
            } catch (e) {
              line['error'] = '$e'.split('\n').first;
            }
            print('CS3-GAMES ${asciiJson(line)}');
          }
        } finally {
          await listening.cancel();
          await changes.undo(tester, container);
        }
      });
    },
    skip: skipReason != null,
    timeout: const Timeout(Duration(minutes: 150)),
  );
}

Future<void> _game(
  WidgetTester tester,
  CloudStreamEngineHost host,
  CloudStreamRepository notifier,
  List<Map<String, dynamic>> events,
  String name,
  Map<String, Object?> line,
) async {
  late String path;
  late String provider;
  String? pluginUrl;
  await tester.runAsync(() async {
    final repo = await notifier.addRepository(_repo);
    final listed = repo.plugins.firstWhere((p) => p.internalName == name);
    final installed = await notifier.install(listed);
    path = installed.filePath;
    pluginUrl = listed.url;
    provider = installed.providers.first.name;
  });
  final home = await whilePumping(
    tester,
    host.run(
      path,
      (e) => e.mainPage(provider, plugin: path),
      kind: 'mainPage',
      pluginUrl: pluginUrl,
    ),
  );
  final items = ((home['sections'] as List).first as Map)['items'] as List;
  final url = (items.first as Map)['url'] as String;
  final title = await whilePumping(
    tester,
    host.run(
      path,
      (e) => e.load(provider, url, plugin: path),
      kind: 'load',
      pluginUrl: pluginUrl,
    ),
  );
  await _play(tester, host, events, name, line, path: path, provider: provider, pluginUrl: pluginUrl, title: title);
  if (_saves && _keepsSaves(name) && line['error'] == null) {
    final again = <String, Object?>{};
    line['again'] = again;
    await _play(
      tester,
      host,
      events,
      name,
      again,
      path: path,
      provider: provider,
      pluginUrl: pluginUrl,
      title: title,
      round: 2,
    );
  }
}

/// One Play of [name]'s game, its report in [line]: round 2 is Play again, after round 1's save (`GAMES_SAVES`).
Future<void> _play(
  WidgetTester tester,
  CloudStreamEngineHost host,
  List<Map<String, dynamic>> events,
  String name,
  Map<String, Object?> line, {
  required String path,
  required String provider,
  required String? pluginUrl,
  required Map<String, dynamic> title,
  int round = 1,
}) async {
  final saves = _saves && _keepsSaves(name);
  // On Android the Mac-side driver plays the game and closes it (the app can't script the extension's own WebView).
  final driven = _saves && Platform.isAndroid;
  // What Play puts under a game: the player's opaque page. Over Home, a game that turns the phone has Flutter lay Home
  // out once at its old width in the frame the view covers it, and report a header overflow nobody sees (debug only).
  final navigator = Navigator.of(tester.element(find.byType(Scaffold).first), rootNavigator: true);
  final under = PageRouteBuilder<void>(
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (_, _, _) => const ColoredBox(color: Colors.black),
  );
  unawaited(navigator.push(under));
  await pumpFor(tester, const Duration(milliseconds: 300));
  final from = events.length;
  final played = Stopwatch()..start();
  Map<String, dynamic>? answer;
  Object? failure;
  var ended = false;
  DateTime? answeredAt;
  final call = host
      .run(
        path,
        (e) => e.loadLinks(provider, title['dataUrl'] as String, plugin: path),
        kind: 'loadLinks',
        pluginUrl: pluginUrl,
      )
      .then<void>(
        (value) {
          answer = value;
        },
        onError: (Object e) {
          failure = e;
        },
      )
      .whenComplete(() {
        ended = true;
        answeredAt = DateTime.now();
      });

  if (!_native) {
    await pumpUntil(
      tester,
      () => find.byType(ExtensionFullScreen).evaluate().isNotEmpty || ended,
      what: '$name full screen',
      timeout: const Duration(minutes: 3),
    );
    line['shownMs'] = played.elapsedMilliseconds;
    final ui = events.skip(from).lastWhere((e) => e['event'] == 'ui', orElse: () => const {});
    final windows = (ui['windows'] as List?) ?? const [];
    line['fullScreen'] = windows.isNotEmpty && (windows.last as Map)['fullScreen'] == true;
    line['sheet'] = find.byType(ExtensionSheet).evaluate().isNotEmpty;
    if (driven) print('CS3-MATRIX ready $name $round');
    // The JVM's page: the app's own browser (Android lends the extension's WebView, which the app can't script).
    final session = ui['session'];
    final node = windows.isEmpty ? null : ((windows.last as Map)['root'] as Map)['id'];
    if (!Platform.isAndroid && session is int && node is int) {
      final until = DateTime.now().add(const Duration(seconds: 60));
      while (ExtensionPages.shared.at(session, node) == null && DateTime.now().isBefore(until) && !ended) {
        await pumpFor(tester, const Duration(milliseconds: 500));
      }
      final page = ExtensionPages.shared.at(session, node);
      line['jvmPage'] = page != null;
      if (page != null) {
        Future<Object?> read(String script) async =>
            jsonDecode(await whilePumping(tester, page.browser.evaluate(script)));
        Future<int?> fps() async {
          await read(_countFrames);
          final watch = Stopwatch()..start();
          await pumpFor(tester, const Duration(seconds: 2));
          final frames = await read('window.__cs3Frames');
          return frames is num ? (frames / (watch.elapsedMilliseconds / 1000)).round() : null;
        }

        // Its scripts load the emulator and the game after the page itself.
        await pumpFor(tester, const Duration(seconds: 8));
        if (round == 1) {
          if (saves) line['resumeBefore'] = await read(_resumeOffered);
          line['start'] = await read(_start);
          // Off Android the page is served from the app (Phase 7c part 2), where a GBA game reads its game file.
          line['served'] = await read('location.protocol');
          line['romError'] = await read(
            "document.body ? document.body.innerText.indexOf('ROM load error') >= 0 : null",
          );
          if (_audio && name == 'FlappyBird') {
            await read(_audioStart);
            // The blob's probe starts after its fetch, with its own 8 s.
            await pumpFor(tester, const Duration(seconds: 12));
            line['audio'] = await read(_audioRead);
          }
          await pumpFor(tester, Duration(seconds: saves ? 20 : 3));
          line['fps'] = await fps();
          // A page its browser counts as hidden (an occluded window) draws no frames: what the reading means.
          line['visibility'] = await read('document.visibilityState');
          line['size'] = await read('innerWidth + "x" + innerHeight');
          if (saves) {
            line['saved'] = await read(_saveSlot1);
            line['savedLengths'] = await read(_savedLengths);
          }
        } else {
          line['resumeOffered'] = await read(_resumeOffered);
          line['resumed'] = await read(_resume);
          await pumpFor(tester, const Duration(seconds: 3));
          line['loaded'] = await read(_loadSlot1);
          line['savedLengths'] = await read(_savedLengths);
          line['fps'] = await fps();
        }
      }
    }
  }
  if (_holdS > 0) {
    print('CS3-GAMES holding $name');
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: _holdS)));
  }
  if (driven) {
    await pumpUntil(
      tester,
      () => ended,
      what: "$name's Play call ending (the Mac-side driver closes it)",
      timeout: const Duration(minutes: 4),
    );
  } else if (!_native) {
    final closing = Stopwatch()..start();
    await tester.binding.handlePopRoute();
    await pumpFor(tester, const Duration(seconds: 1));
    // A game that closes on its first Back (none of Ayu's) leaves nothing for a second.
    if (find.byType(ExtensionFullScreen).evaluate().isNotEmpty) await tester.binding.handlePopRoute();
    await pumpUntil(tester, () => ended, what: "$name's Play call ending", timeout: const Duration(minutes: 2));
    line['closedMs'] = closing.elapsedMilliseconds;
  } else {
    await pumpUntil(
      tester,
      () => ended,
      what: "$name's Play call ending (the check's script closes it)",
      timeout: const Duration(minutes: 10),
    );
  }
  await call;
  navigator.removeRoute(under);
  await pumpFor(tester, const Duration(milliseconds: 300));
  // How long after the game's full-screen window went (its last screen's update without one, or the screen's end) the
  // call answered: what tells a game's end from a check the extension went on from (the quiet end's cutoff).
  int? screen;
  DateTime? goneAt;
  for (final event in events.skip(from)) {
    final windows = (event['windows'] as List?) ?? const [];
    final full = windows.any((window) => (window as Map)['fullScreen'] == true);
    if (event['event'] == 'ui' && full) {
      screen = event['session'] as int?;
      goneAt = null;
    } else if (screen != null && event['session'] == screen && goneAt == null) {
      if (event['event'] == 'uiClosed' || (event['event'] == 'ui' && !full)) goneAt = event['at'] as DateTime;
    }
  }
  if (goneAt != null && answeredAt != null) line['goneMs'] = answeredAt!.difference(goneAt).inMilliseconds;
  line['links'] = (answer?['links'] as List?)?.length;
  line['completed'] = answer?['completed'];
  line['callFullScreen'] = answer?['fullScreen'];
  if (failure != null) line['error'] = '$failure'.split('\n').first;
}
