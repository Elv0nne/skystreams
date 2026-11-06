/// The 30 extensions in MegaRepo's repositories that can open a window during a background call (the Phase 7
/// research, 2026-10-05), each installed, its providers' home pages and a search run as Home and search run
/// them, and what came of their windows reported. Nothing may show over the app (`popupEscaped`), and no
/// background call may open a screen (`uiOpened`). Support works: an extension with pop-ups kept has them
/// opened as its row's Support opens them, then closed. On the device the research saw support pop-ups from
/// HDrezka, StreamPlay, AnimeWorldIndia and AniStream, and AnimePahe's own Cloudflare dialog: the report
/// says which were kept, which opened through Support, and which were dropped (live sites decide). Prints
/// `CS3-POPUP {json}` each, then `CS3-POPUP-END {json}`.
///
/// ```
/// flutter test integration_test/cloudstream/popup_corpus_test.dart -d DEVICE --dart-define=CS3_E2E=true \
///   [--dart-define=POPUP_ONLY=StreamPlay,AnimePahe] --dart-define-from-file=DEFINES
/// ```
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_ui_session.dart';

import 'support.dart';

const _only = String.fromEnvironment('POPUP_ONLY');

const _arabic = 'https://raw.githubusercontent.com/Abodabodd/re-3arabi/refs/heads/main/repo';
const _cnc = 'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json';
const _desi = 'https://raw.githubusercontent.com/Faisal0786/Desi/main/repo.json';
const _phisher =
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json';
const _raghav = 'https://raw.githubusercontent.com/KSHITIJ8473/raghav/builds/repo.json';

/// (repository, internal name, search query), from MegaRepo's index (2026-09-29) and the research's list.
const popupExtensions = <(String, String, String)>[
  (_arabic, 'Anime4up', 'naruto'),
  (_arabic, 'Cimalight', 'batman'),
  (_arabic, 'Egydead', 'batman'),
  (_arabic, 'Elif', 'batman'),
  (_arabic, 'Faselhd', 'naruto'),
  (_arabic, 'MyCimaProvider', 'batman'),
  (_arabic, 'Witanime', 'naruto'),
  (_cnc, 'HDrezkaProvider', 'batman'),
  (_cnc, 'MLSBDProvider', 'batman'),
  (_cnc, 'MovieLinkBDProvider', 'batman'),
  (_desi, 'AniStream', 'naruto'),
  (_desi, 'Ctg Stream', 'batman'),
  (_desi, 'OttSource', 'batman'),
  (_desi, 'SDmovies', 'batman'),
  (_desi, 'StreamHubOne', 'batman'),
  (_desi, 'The Movie Flix', 'batman'),
  (_desi, 'vegamovies', 'batman'),
  (_desi, 'MovieBox', 'batman'),
  ('https://raw.githubusercontent.com/FlummoxGamer/FLUMMOX-Repo/builds/repo.json', 'BingeCloud', 'batman'),
  ('https://raw.githubusercontent.com/yorik100/Cloudstream/refs/heads/builds/repo.json', 'Flemmix', 'batman'),
  ('https://raw.githubusercontent.com/SaurabhKaperwan/CSX/builds/CS.json', 'CineStream', 'batman'),
  (_phisher, 'Comix', 'naruto'),
  (_phisher, 'StreamPlay', 'batman'),
  (_phisher, 'AnimePahe', 'naruto'),
  (_phisher, 'Animexin', 'naruto'),
  (_raghav, 'AnimeWorldIndia', 'naruto'),
  (_raghav, 'Multimovies', 'batman'),
  (_raghav, 'RareAnimesIndia', 'naruto'),
  (_raghav, 'Anidap', 'naruto'),
  (_raghav, 'Kdesa', 'batman'),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'no pop-up extension shows a window over the app during Home or search',
    (tester) async {
      await withApp(tester, (container) async {
        final host = container.read(cloudStreamEngineHostProvider);
        final notifier = container.read(cloudStreamRepositoryProvider.notifier);
        final changes = await CloudStreamChanges.note(tester, container);
        final events = <Map<String, dynamic>>[];
        final listening = host.events.listen(events.add);
        final summary = <String, Object?>{
          'extensions': 0,
          'escaped': 0,
          'opened': 0,
          'withSupport': <String>[],
          'supportWorks': <String>[],
          'supportAgain': <String>[],
          'supportGone': <String>[],
          'dropped': <String>[],
        };
        final wanted = _only.isEmpty ? null : _only.split(',').map((s) => s.trim()).toSet();
        try {
          for (final (repository, name, query) in popupExtensions) {
            if (wanted != null && !wanted.contains(name)) continue;
            final report = <String, Object?>{'extension': name};
            final from = events.length;
            try {
              await _round(tester, container, host, notifier, repository, name, query, report, events);
            } catch (e) {
              report['error'] = '$e'.split('\n').first;
            }
            final mine = events.sublist(from);
            final path = report['path'] as String?;
            bool its(Map<String, dynamic> e) =>
                path != null && CloudStreamRepository.pathKey('${e['plugin']}') == CloudStreamRepository.pathKey(path);
            final kept = [for (final e in mine.where((e) => e['event'] == 'popupKept' && its(e))) '${e['title']}'];
            final dropped = [
              for (final e in mine.where((e) => e['event'] == 'popupDropped' && its(e))) '${e['reason']}',
            ];
            final escaped = mine.where((e) => e['event'] == 'popupEscaped').length;
            final opened = mine.where((e) => e['event'] == 'uiOpened').length;
            report.addAll({'kept': kept, 'dropped': dropped, 'escaped': escaped, 'opened': opened});
            summary['extensions'] = (summary['extensions'] as int) + 1;
            summary['escaped'] = (summary['escaped'] as int) + escaped;
            summary['opened'] = (summary['opened'] as int) + opened;
            if (kept.isNotEmpty) (summary['withSupport'] as List<String>).add(name);
            if (((report['supportWindows'] as int?) ?? 0) > 0) (summary['supportWorks'] as List<String>).add(name);
            final again = report['supportAgain'];
            if (again is int && again > 0) (summary['supportAgain'] as List<String>).add(name);
            if (again is String) (summary['supportGone'] as List<String>).add(name);
            if (dropped.isNotEmpty) (summary['dropped'] as List<String>).add(name);
            report.remove('path');
            print('CS3-POPUP ${asciiJson(report)}');
          }
        } finally {
          print('CS3-POPUP-END ${asciiJson(summary)}');
          await listening.cancel();
          await changes.undo(tester, container);
        }
        expect(summary['escaped'], 0, reason: 'a window showed over the app');
        expect(summary['opened'], 0, reason: 'a background call opened a screen');
        expect(
          [...summary['supportAgain'] as List<String>, ...summary['supportGone'] as List<String>]..sort(),
          [...summary['supportWorks'] as List<String>]..sort(),
          reason: "Support didn't open its pop-ups again",
        );
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
  String query,
  Map<String, Object?> report,
  List<Map<String, dynamic>> events,
) async {
  String? path;
  String? url;
  var providers = <String>[];
  // runAsync reports what its body throws as the test's failure: an extension's error goes in its row instead.
  await tester.runAsync(() async {
    try {
      final repo = await notifier.addRepository(repository);
      final listed = repo.plugins.where((p) => p.internalName == name).firstOrNull;
      if (listed == null) {
        report['error'] = 'not in its repository';
        return;
      }
      final installed = await notifier.install(listed);
      path = installed.filePath;
      url = listed.url;
      providers = [for (final p in installed.providers) p.name];
      report['loadError'] = installed.loadError;
    } catch (e) {
      report['error'] = '$e'.split('\n').first;
    }
  });
  report['path'] = path;
  report['providers'] = providers.length;
  if (path == null || providers.isEmpty) return;
  Future<Object?> bounded(Future<Object?> call) =>
      call.timeout(const Duration(minutes: 2)).then<Object?>((value) => value, onError: (Object e) => e);
  for (final provider in providers) {
    await whilePumping(
      tester,
      bounded(
        host.run(
          path!,
          (e) => e.mainPage(provider, plugin: path),
          kind: 'mainPage',
          pluginUrl: url,
        ),
      ),
    );
    await whilePumping(
      tester,
      bounded(
        host.run(
          path!,
          (e) => e.search(provider, query, plugin: path),
          kind: 'search',
          pluginUrl: url,
        ),
      ),
    );
  }
  // A window posted to the main thread as a call returns is sorted a moment later; a page 5 s after it shows (the
  // engine's PAGE_SORT_MS, part 5): the row is read once both are done (part 6 found rows read before page sorts).
  await pumpFor(tester, const Duration(seconds: 7));
  // Support works: what was kept opens live, as the row's Support opens it, and closes.
  final kept = container.read(cloudStreamRepositoryProvider).popups[CloudStreamRepository.pathKey(path!)] ?? const [];
  if (kept.isNotEmpty) {
    try {
      final session = await whilePumping(tester, ExtensionUiSession.openPopups(HostUiApi(host), path!));
      // The engine answers once the windows are published; their ui event can reach the app just after the answer.
      await pumpUntil(
        tester,
        () => session.windows.isNotEmpty,
        what: "$name's pop-ups shown",
        timeout: const Duration(seconds: 10),
      );
      report['supportWindows'] = session.windows.length;
      // A pop-up may close itself (raghav's counts 9 s down, then dismisses itself): gone, as the spec says.
      final from = events.length;
      await whilePumping(tester, session.close(force: true));
      await pumpUntil(
        tester,
        () => session.closed,
        what: "$name's pop-ups closed",
        timeout: const Duration(seconds: 10),
      );
      session.dispose();
      // Closing put them back (the owner, 2026-10-08): Support opens them again (the spec's Exit).
      bool back() =>
          (container.read(cloudStreamRepositoryProvider).popups[CloudStreamRepository.pathKey(path!)] ?? const [])
              .isNotEmpty;
      try {
        await pumpUntil(
          tester,
          back,
          what: "$name's pop-ups back behind Support",
          timeout: const Duration(seconds: 10),
        );
      } catch (_) {
        // Put back, then closed by its extension (its own countdown) meanwhile; or gone before the close reached it,
        // the host then having nothing to put back and saying nothing. Told, with nothing kept: not put back.
        final told = [
          for (final e in events.skip(from))
            if (e['event'] == 'popups' &&
                CloudStreamRepository.pathKey('${e['plugin']}') == CloudStreamRepository.pathKey(path!))
              e,
        ];
        final putBack = told.any((e) => (e['titles'] as List?)?.isNotEmpty == true);
        if (told.isNotEmpty && !putBack) rethrow;
        report['supportAgain'] = putBack ? 'closed itself after it was put back' : 'closed itself while shown';
        return;
      }
      final again = await whilePumping(tester, ExtensionUiSession.openPopups(HostUiApi(host), path!));
      try {
        await pumpUntil(
          tester,
          () => again.windows.isNotEmpty,
          what: "$name's pop-ups shown again",
          timeout: const Duration(seconds: 10),
        );
      } catch (_) {
        // Put back, then closed by its extension's own countdown before Support showed it again (raghav's donation
        // dialog, 9 s): nothing kept any more, as after a close it made itself.
        if (back()) rethrow;
        report['supportAgain'] = 'closed itself after it was put back';
        await whilePumping(tester, again.close(force: true));
        return;
      }
      report['supportAgain'] = again.windows.length;
      await whilePumping(tester, again.close(force: true));
      await pumpUntil(
        tester,
        () => again.closed,
        what: "$name's pop-ups closed again",
        timeout: const Duration(seconds: 10),
      );
      again.dispose();
    } catch (e) {
      report['supportError'] = '$e'.split('\n').first;
    }
  }
  await tester.runAsync(() async {
    try {
      final installed = container
          .read(cloudStreamRepositoryProvider)
          .installed
          .where((p) => p.filePath == path)
          .firstOrNull;
      if (installed != null) await notifier.uninstall(installed);
    } catch (e) {
      report['uninstallError'] = '$e'.split('\n').first;
    }
  });
}
