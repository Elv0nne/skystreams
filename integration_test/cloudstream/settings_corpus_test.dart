/// The 79 extensions with their own settings screen in MegaRepo's 30 repositories (2026-10-05), each
/// installed, opened through the engine as SkyStream's sheet opens it, read, changed once (its first
/// ticked toggle, then its save), its restart alert answered Yes if it shows one, closed, and loaded
/// afresh. Prints one `CS3-UI {json}` line each, then `CS3-UI-END {json}`. Keep the lines: they're
/// Android's reference trees for the desktop and iOS stand-ins (the spec's part 2). A `CS3-UI-ROUND`
/// line, with the time, says when each extension's round starts, so a slow or stalled one shows where.
/// On the desktops and iOS, compare a run's lines with Android's: packages/cs3_engine/tool/compare_trees.dart.
///
/// ```
/// flutter test integration_test/cloudstream/settings_corpus_test.dart -d DEVICE \
///   --dart-define=CS3_E2E=true [--dart-define=CORPUS_ONLY=CNC Verse,StreamPlay] --dart-define-from-file=DEFINES
/// ```
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/cloudstream/extension_ui/ui_tree.dart';

import 'support.dart';
import 'test_extension.dart' show findNode;

const _only = String.fromEnvironment('CORPUS_ONLY');

/// (repository, internal name), from MegaRepo's index on 2026-10-05.
/// FStream left on 2026-10-08: its repository (git.disroot.org) now answers every app with a login page.
const settingsExtensions = <(String, String)>[
  ('https://gitlab.com/tearrs/cloudstream-vietnamese/-/raw/main/repo.json', 'FshareProvider'),
  ('https://gitlab.com/tearrs/cloudstream-vietnamese/-/raw/main/repo.json', 'IPTVProvider'),
  ('https://gitlab.com/tearrs/cloudstream-vietnamese/-/raw/main/repo.json', 'MonPlayerProvider'),
  ('https://gitlab.com/tearrs/cloudstream-vietnamese/-/raw/main/repo.json', 'StremioProvider'),
  ('https://gitlab.com/tearrs/cloudstream-vietnamese/-/raw/main/repo.json', 'SyncProvider'),
  ('https://gitlab.com/tearrs/cloudstream-vietnamese/-/raw/main/repo.json', 'XtreamIPTVProvider'),
  ('https://raw.githubusercontent.com/Abodabodd/re-3arabi/refs/heads/main/repo', 'Replaymatch'),
  ('https://raw.githubusercontent.com/Abodabodd/re-3arabi/refs/heads/main/repo', 'Youtube'),
  ('https://raw.githubusercontent.com/Abodabodd/re-3arabi/refs/heads/main/repo', 'cinemana'),
  ('https://raw.githubusercontent.com/CakesTwix/cloudstream-extensions-uk/master/repo.json', 'SyncPlugin'),
  ('https://raw.githubusercontent.com/CranberrySoup/AniyomiCompatExtension/master/repo.json', 'AniyomiProvider'),
  ('https://raw.githubusercontent.com/DieGon7771/ItaliaInStreaming/builds/repo.json', 'AltaDefinizione'),
  ('https://raw.githubusercontent.com/DieGon7771/ItaliaInStreaming/builds/repo.json', 'AnimeWorld'),
  ('https://raw.githubusercontent.com/DieGon7771/ItaliaInStreaming/builds/repo.json', 'Arte'),
  ('https://raw.githubusercontent.com/DieGon7771/ItaliaInStreaming/builds/repo.json', 'Huhu'),
  ('https://raw.githubusercontent.com/DieGon7771/ItaliaInStreaming/builds/repo.json', 'SectionOrganizer'),
  ('https://raw.githubusercontent.com/DieGon7771/ItaliaInStreaming/builds/repo.json', 'StreamingCommunity'),
  ('https://raw.githubusercontent.com/DieGon7771/ItaliaInStreaming/builds/repo.json', 'Stremio'),
  ('https://raw.githubusercontent.com/DieGon7771/ItaliaInStreaming/builds/repo.json', 'SyncStream'),
  ('https://raw.githubusercontent.com/DieGon7771/ItaliaInStreaming/builds/repo.json', 'TV'),
  ('https://raw.githubusercontent.com/DieGon7771/ItaliaInStreaming/builds/repo.json', 'Torrentio'),
  ('https://raw.githubusercontent.com/DieGon7771/ItaliaInStreaming/builds/repo.json', 'WatchParty'),
  ('https://raw.githubusercontent.com/Faisal0786/Desi/main/repo.json', 'StreamHubOne'),
  ('https://raw.githubusercontent.com/Faisal0786/Desi/main/repo.json', 'vegamovies'),
  ('https://raw.githubusercontent.com/FlummoxGamer/FLUMMOX-Repo/builds/repo.json', 'BingeCloud'),
  ('https://raw.githubusercontent.com/FlummoxGamer/FLUMMOX-Repo/builds/repo.json', 'Otakutsu'),
  ('https://raw.githubusercontent.com/KSHITIJ8473/raghav/builds/repo.json', 'AnimeWorldIndia'),
  ('https://raw.githubusercontent.com/KSHITIJ8473/raghav/builds/repo.json', 'JustPlay'),
  ('https://raw.githubusercontent.com/KSHITIJ8473/raghav/builds/repo.json', 'LIVETVProvider'),
  ('https://raw.githubusercontent.com/KSHITIJ8473/raghav/builds/repo.json', 'Multimovies'),
  ('https://raw.githubusercontent.com/KSHITIJ8473/raghav/builds/repo.json', 'NetNaija'),
  ('https://raw.githubusercontent.com/KSHITIJ8473/raghav/builds/repo.json', 'NetNaija-box'),
  ('https://raw.githubusercontent.com/KSHITIJ8473/raghav/builds/repo.json', 'RaghavAnime'),
  ('https://raw.githubusercontent.com/KSHITIJ8473/raghav/builds/repo.json', 'RaghavAnimeKitsu'),
  ('https://raw.githubusercontent.com/KSHITIJ8473/raghav/builds/repo.json', 'RareAnimesIndia'),
  ('https://raw.githubusercontent.com/KSHITIJ8473/raghav/builds/repo.json', 'TorrentsV1'),
  ('https://raw.githubusercontent.com/Kraptor123/cs-Karma/refs/heads/master/repo.json', 'Footballia'),
  ('https://raw.githubusercontent.com/Kraptor123/cs-Karma/refs/heads/master/repo.json', 'Movix'),
  (
    'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json',
    'CNC Verse',
  ),
  (
    'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json',
    'CNC Verse Mobile',
  ),
  (
    'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json',
    'CricifyProvider',
  ),
  (
    'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json',
    'LivXowProvider',
  ),
  (
    'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json',
    'M3UPlaylistPlayerProvider',
  ),
  (
    'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json',
    'PlayFyProvider',
  ),
  (
    'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json',
    'PlayZTVProvider',
  ),
  (
    'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json',
    'SKTechProvider',
  ),
  (
    'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json',
    'SportzxProvider',
  ),
  (
    'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json',
    'SubscriptionManager',
  ),
  ('https://raw.githubusercontent.com/SaurabhKaperwan/CSX/builds/CS.json', 'CineStream'),
  ('https://raw.githubusercontent.com/doGior/doGiorsHadEnough/refs/heads/builds/repo.json', 'AnimeUnity'),
  ('https://raw.githubusercontent.com/doGior/doGiorsHadEnough/refs/heads/builds/repo.json', 'AnimeWorld'),
  ('https://raw.githubusercontent.com/doGior/doGiorsHadEnough/refs/heads/builds/repo.json', 'Arte'),
  ('https://raw.githubusercontent.com/doGior/doGiorsHadEnough/refs/heads/builds/repo.json', 'IPTV'),
  ('https://raw.githubusercontent.com/doGior/doGiorsHadEnough/refs/heads/builds/repo.json', 'StreamCenter'),
  ('https://raw.githubusercontent.com/doGior/doGiorsHadEnough/refs/heads/builds/repo.json', 'StreamingCommunity'),
  ('https://raw.githubusercontent.com/doGior/doGiorsHadEnough/refs/heads/builds/repo.json', 'TV'),
  ('https://raw.githubusercontent.com/doGior/doGiorsHadEnough/refs/heads/builds/repo.json', 'Vavoo'),
  ('https://raw.githubusercontent.com/doGior/doGiorsHadEnough/refs/heads/builds/repo.json', 'YouTube'),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'AniVortex',
  ),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'AnimePahe',
  ),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'Animexin',
  ),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'Aniworld',
  ),
  ('https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json', 'Anizone'),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'Cinemacity',
  ),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'DoraBash',
  ),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'Jellyfin',
  ),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'Kartoons',
  ),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'MovieBoxProvider',
  ),
  ('https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json', 'ShowBox'),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'StreamPlay',
  ),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'StremioAddon',
  ),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'StremioX',
  ),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'SuperStream',
  ),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'TorraStream',
  ),
  ('https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json', 'Ultima'),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'XDMovies',
  ),
  (
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    'Zinkmovies',
  ),
  ('https://raw.githubusercontent.com/redblacker8/storm-ext/refs/heads/builds/repo.json', 'IzziGoProvider'),
];

final _save = RegExp(r'save|apply|^ok$|done|salva|guardar|enregistrer|speichern|simpan|lưu', caseSensitive: false);
final _restart = RegExp(r'restart|riavvi|reinici|redémarr|neu start|mulai ulang|khởi động lại', caseSensitive: false);
final _yes = RegExp(
  r'^(yes|ok|restart|restart now|riavvia|sì|si|sí|reiniciar|oui|ja|ya|có|haan|हाँ)$',
  caseSensitive: false,
);

Iterable<UiNode> _all(UiNode node) sync* {
  yield node;
  for (final child in node.children) {
    yield* _all(child);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'every settings screen opens hidden in SkyStream, and no restart gets through',
    (tester) async {
      await withApp(tester, (container) async {
        final host = container.read(cloudStreamEngineHostProvider);
        final notifier = container.read(cloudStreamRepositoryProvider.notifier);
        final changes = await CloudStreamChanges.note(tester, container);
        final summary = <String, Object?>{
          'opened': 0,
          'notHidden': <String>[],
          'restartsTried': 0,
          'restartsStopped': 0,
        };
        final wanted = _only.isEmpty ? null : _only.split(',').map((s) => s.trim()).toSet();
        var round = 0;
        try {
          for (final (repository, name) in settingsExtensions) {
            if (wanted != null && !wanted.contains(name)) continue;
            print('CS3-UI-ROUND ${++round} $name ${DateTime.now().toIso8601String().substring(11, 19)}');
            final report = <String, Object?>{'extension': name};
            final events = <Map<String, dynamic>>[];
            final listening = host.events.listen(events.add);
            try {
              await _round(tester, container, host, notifier, repository, name, report, events, summary);
            } catch (e) {
              report['error'] = '$e'.split('\n').first;
            } finally {
              await listening.cancel();
            }
            // On the desktops and iOS, what the extension asked the app to show or do (Android shows its own).
            final notices = [
              for (final e in events)
                if (const {'toast', 'copy', 'openUrl'}.contains(e['event'])) '${e['event']}: ${e['text'] ?? e['url']}',
            ];
            if (notices.isNotEmpty) report['notices'] = notices;
            print('CS3-UI ${asciiJson(report)}');
          }
        } finally {
          print('CS3-UI-END ${asciiJson(summary)}');
          await changes.undo(tester, container);
        }
        expect(summary['notHidden'], isEmpty, reason: 'an extension window showed over the app');
        expect(summary['restartsStopped'], summary['restartsTried'], reason: 'a restart got through');
      });
    },
    skip: skipReason != null,
    timeout: const Timeout(Duration(hours: 2)),
  );
}

Future<void> _round(
  WidgetTester tester,
  ProviderContainer container,
  CloudStreamEngineHost host,
  CloudStreamRepository notifier,
  String repository,
  String name,
  Map<String, Object?> report,
  List<Map<String, dynamic>> events,
  Map<String, Object?> summary,
) async {
  String? path;
  String? url;
  await tester.runAsync(() async {
    final repo = await notifier.addRepository(repository);
    final listed = repo.plugins.firstWhere((p) => p.internalName == name);
    final installed = await notifier.install(listed);
    path = installed.filePath;
    url = listed.url;
    report['loadError'] = installed.loadError;
  });
  if (path == null) return;
  final answer = await whilePumping(tester, host.ensureLoaded(path!, pluginUrl: url));
  report['hasSettings'] = answer['hasSettings'];
  if (answer['hasSettings'] != true) return;

  final session = await whilePumping(tester, host.openSettings(path!, pluginUrl: url));
  bool shown() => events.any((e) => e['event'] == 'ui' && e['session'] == session);
  await pumpUntil(tester, shown, what: '$name showing its screen', timeout: const Duration(seconds: 15));
  List<UiWindow> windows() => [
    for (final w in events.lastWhere((e) => e['event'] == 'ui' && e['session'] == session)['windows'] as List)
      UiWindow.fromJson(Map<String, dynamic>.from(w as Map)),
  ];
  final first = windows();
  summary['opened'] = (summary['opened'] as int) + 1;
  report['windows'] = first.length;
  // Android hides its real windows; the desktops' and iOS's stand-ins are never drawn.
  if (Platform.isAndroid) {
    report['hidden'] = first.every((w) => w.hidden == true);
    if (report['hidden'] != true) (summary['notHidden'] as List<String>).add(name);
  }
  report['tree'] = events.lastWhere((e) => e['event'] == 'ui' && e['session'] == session)['windows'];

  // One change, as a person makes it: the first ticked toggle, then the save.
  final toggle = first.map((w) => findNode(w.root, (n) => n.isToggle && n.checked)).nonNulls.firstOrNull;
  if (toggle != null) await whilePumping(tester, host.uiAction(session, toggle.id, 'click'));
  final save = first
      .expand((w) => _all(w.root))
      .where(
        (n) => (n.tappable || n.kind == UiKind.button || n.kind == UiKind.iconButton) && _save.hasMatch(n.words ?? ''),
      )
      .firstOrNull;
  if (save != null) await whilePumping(tester, host.uiAction(session, save.id, 'click'));
  report['changed'] = [toggle?.words, save?.words];
  await pumpFor(tester, const Duration(seconds: 2));

  // A restart alert: its Yes. The app must run on, and the extension reload instead.
  if (!events.any((e) => e['event'] == 'uiClosed' && e['session'] == session)) {
    final now = windows();
    final asks = now.expand((w) => _all(w.root)).any((n) => _restart.hasMatch(n.words ?? ''));
    if (asks) {
      final yes = now.expand((w) => _all(w.root)).where((n) => _yes.hasMatch(n.words ?? '')).lastOrNull;
      if (yes != null) {
        summary['restartsTried'] = (summary['restartsTried'] as int) + 1;
        await whilePumping(tester, host.uiAction(session, yes.id, 'click'));
        await pumpUntil(
          tester,
          () =>
              events.any((e) => e['event'] == 'restartRequested') ||
              events.any((e) => e['event'] == 'uiClosed' && e['reason'] == 'restart'),
          what: '$name restart stopped',
          timeout: const Duration(seconds: 10),
        );
        summary['restartsStopped'] = (summary['restartsStopped'] as int) + 1;
        report['restart'] = 'stopped';
      }
    }
  }
  if (!events.any((e) => e['event'] == 'uiClosed' && e['session'] == session)) {
    await whilePumping(tester, host.closeUi(session, force: true));
    await pumpUntil(
      tester,
      () => events.any((e) => e['event'] == 'uiClosed' && e['session'] == session),
      what: '$name closing',
    );
  }
  final reloaded = await whilePumping(tester, host.reloadAfresh(path!, pluginUrl: url));
  report['providersAfter'] = (reloaded['providers'] as List?)?.length;
  await tester.runAsync(() async {
    final installed = container
        .read(cloudStreamRepositoryProvider)
        .installed
        .where((p) => p.filePath == path)
        .firstOrNull;
    if (installed != null) await notifier.uninstall(installed);
  });
}
