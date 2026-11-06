/// MegaRepo in SkyStream: added by its shortcode, its plugin installed, CloudStream's community
/// list applied (each repository on it joins the list, unless the user removed it), a removed one
/// staying removed when the plugin runs again, and CloudStream's other ways of naming a
/// repository. Takes the device's setup as it finds it and puts it back afterwards. Prints what
/// happened (`CS3-MEGA`) and saves a PNG of the Repositories tab.
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/models/extension_update_report.dart';
import 'package:skystream/core/network/dio_client_provider.dart';

import 'support.dart';

const _megaRepo = 'https://raw.githubusercontent.com/self-similarity/MegaRepo/builds/repo.json';
const _communityList = 'https://raw.githubusercontent.com/recloudstream/cs-repos/master/repos-db.json';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MegaRepo by shortcode applies CloudStream\'s community list', (tester) async {
    // A phone left in landscape (a video played last) leaves the repository list a sliver of screen.
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    addTearDown(() => SystemChrome.setPreferredOrientations(const []));

    await withApp(tester, (container) async {
      final notifier = container.read(cloudStreamRepositoryProvider.notifier);
      final host = container.read(cloudStreamEngineHostProvider);
      CloudStreamState state() => container.read(cloudStreamRepositoryProvider);
      final changes = await CloudStreamChanges.note(tester, container);
      // Everything plugins offer, from here on.
      final offered = <String>[];
      final events = host.events.listen((event) {
        if (event['event'] == 'repositoryAdded') offered.add(event['url'] as String);
      });
      try {
        // The shortcode resolves through cutt.ly, as in CloudStream.
        final resolved = await tester.runAsync(() => notifier.resolveUrl('megarepo'));
        expect(resolved, _megaRepo, reason: 'megarepo did not resolve to MegaRepo');

        // Add Repository with the shortcode, unless the device has MegaRepo already.
        go(tester, '/settings/cloudstream');
        await waitFor(tester, find.text('Add Repository'));
        if (!changes.hadRepository(_megaRepo)) {
          await tester.tap(find.text('Add Repository').first);
          await waitFor(tester, find.byType(TextField));
          await typeInto(tester, find.byType(TextField).last, 'megarepo');
          await tester.tap(find.text('Add').last);
          await waitFor(tester, find.textContaining('Added Mega repository'), timeout: const Duration(minutes: 1));
          print('CS3-MEGA shortcode: ${snackBarText(tester)}');
        }

        // Install its plugin: done once it loads; the repositories it adds arrive one by one
        // after. Already installed, it runs again as at a launch.
        ExtensionUpdateReport? news;
        final newsListener = notifier.watchNews().listen((report) => news = report);
        final started = DateTime.now();
        final install = find.byKey(const ValueKey('cs3_install_MegaProvider'));
        if (state().installed.any((p) => p.info.internalName == 'MegaProvider')) {
          await tester.runAsync(notifier.autoUpdate);
          print('CS3-MEGA MegaProvider was installed; ran it again');
        } else {
          await pumpFor(tester, const Duration(seconds: 2));
          await tester.tap(find.text('Repositories'));
          await pumpFor(tester, const Duration(seconds: 1));
          // MegaRepo's card is the last one; the list builds only what is on screen.
          for (var i = 0; i < 40 && install.evaluate().isEmpty; i++) {
            await tester.dragFrom(tester.getCenter(find.byType(TabBarView)), const Offset(0, -300));
            await tester.pump(const Duration(milliseconds: 300));
          }
          await waitFor(tester, install);
          // Built can still be off screen (the list builds ahead). The list jumps there, and the
          // tap needs the frame that lays the jump out.
          await tester.ensureVisible(install.first);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(install.first);
          await waitFor(tester, find.textContaining('Installed MegaProvider'), timeout: const Duration(minutes: 2));
          print('CS3-MEGA install done after ${DateTime.now().difference(started).inMilliseconds} ms');
        }

        // Until the plugin has gone quiet and the repositories it offered have been announced.
        var quietSince = DateTime.now();
        var seen = 0;
        while (DateTime.now().difference(quietSince) < const Duration(seconds: 8)) {
          await tester.pump(const Duration(milliseconds: 250));
          if (offered.length != seen) {
            seen = offered.length;
            quietSince = DateTime.now();
          }
        }
        // Announced only if anything was new: a device that has every repository already gets none.
        final announced = DateTime.now().add(const Duration(seconds: 15));
        while (news == null && DateTime.now().isBefore(announced)) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        await newsListener.cancel();
        print('CS3-MEGA offered ${offered.length}, announced '
            '${news?.newRepositories.map((plugin, names) => MapEntry(plugin, names.length))}, '
            '${DateTime.now().difference(started).inMilliseconds} ms after the start');

        // The whole community list is applied: each repository on it is in the list or removed.
        final listed = await tester.runAsync(() async {
          final response = await container.read(dioClientProvider).get<String>(_communityList);
          return [
            for (final entry in jsonDecode(response.data!) as List)
              if (entry is String)
                entry
              else if (entry is Map && entry['url'] is String)
                entry['url'] as String,
          ];
        });
        final removed = {...?(await SharedPreferences.getInstance()).getStringList(CloudStreamRepository.removedReposKey)};
        final present = {for (final r in state().repositories) r.url};
        final missing = [
          for (final url in listed!)
            if (!present.contains(url) && !removed.contains(url)) url,
        ];
        print('CS3-MEGA community list: ${listed.length} repositories; not in the list: $missing');
        // A repository whose manifest is down is left for the next launch; a few can be.
        expect(missing.length, lessThanOrEqualTo(3), reason: 'MegaRepo\'s list was not applied');
        await pumpFor(tester, const Duration(seconds: 1));
        print('CS3-MEGA screenshot ${await screenshot(tester, 'cs3-mega-repositories')}');

        // A repository the user removes stays removed when the plugin offers it again. Not MegaRepo
        // itself: removing it uninstalls the plugin.
        final victim = state().repositories
            .where((r) => r.url != _megaRepo && !changes.hadRepository(r.url) && listed.contains(r.url))
            .firstOrNull;
        if (victim == null) {
          print('CS3-MEGA every repository was on the device before; skipped "stays removed"');
        } else {
          await tester.runAsync(() => notifier.removeRepository(victim.url));
          final before = offered.length;
          await tester.runAsync(notifier.autoUpdate);
          await pumpUntil(
            tester,
            () => offered.skip(before).contains(victim.url),
            what: 'MegaProvider to offer ${victim.name} again',
            timeout: const Duration(minutes: 1),
          );
          await pumpFor(tester, const Duration(seconds: 3));
          final back = state().repositories.any((r) => r.url == victim.url);
          print('CS3-MEGA removed "${victim.name}"; offered again: yes; back in the list: $back');
          expect(back, isFalse, reason: 'a repository the user removed came back');
        }

        // CloudStream's other ways of naming a repository.
        final forms = await tester.runAsync(() async {
          String? noSuchCode;
          try {
            await notifier.resolveUrl('no-such-code-3a8f1c');
          } catch (error) {
            noSuchCode = CloudStreamRepository.errorMessage(error);
          }
          return {
            'cspr': await notifier.resolveUrl('cspr'),
            'cloudstreamrepo://': await notifier.resolveUrl('cloudstreamrepo://raw.githubusercontent.com/a/b/repo.json'),
            'https://cs.repo/': await notifier.resolveUrl('https://cs.repo/?raw.githubusercontent.com/a/b/repo.json'),
            'unknown code': noSuchCode,
          };
        });
        forms!.forEach((form, url) => print('CS3-MEGA $form -> $url'));
        expect(forms['cspr'], englishRepository);
        expect(forms['cloudstreamrepo://'], 'https://raw.githubusercontent.com/a/b/repo.json');
        expect(forms['https://cs.repo/'], 'https://raw.githubusercontent.com/a/b/repo.json');
        expect(forms['unknown code'], contains("doesn't exist"));
      } finally {
        await events.cancel();
        await changes.undo(tester, container);
      }
    });
  }, skip: skipReason != null, timeout: const Timeout(Duration(minutes: 12)));
}
