/// What a launch tells the user about their extensions, and how.
///
/// Each extension system reports on its own - SkyStream plugins, Nuvio
/// scrapers, Stremio add-ons - and the launch merges the reports into at most
/// three toasts: what was updated, which repositories a collection brought
/// in, and which plugins appeared in a repository. Three, whatever happened:
/// the toast stack holds four, and a fifth pushes the oldest off before
/// anyone has read it.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/models/extension_update_report.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('toastNames', () {
    test('up to four are all named', () {
      expect(toastNames(<String>['A']), 'A');
      expect(toastNames(<String>['A', 'B', 'C', 'D']), 'A, B, C, D');
    });

    test('past four, three are named and the rest counted', () {
      expect(toastNames(<String>['A', 'B', 'C', 'D', 'E']), 'A, B, C +2');
      expect(
        toastNames(List<String>.generate(13, (i) => 'P$i')),
        'P0, P1, P2 +10',
      );
    });
  });

  group('merge', () {
    test('keeps every system\'s findings, in the order given', () {
      final merged = ExtensionUpdateReport.merge(<ExtensionUpdateReport>[
        const ExtensionUpdateReport(
          updated: <String>['SuperStream'],
          newPlugins: <String, List<String>>{
            'Stars': <String>['Alpha'],
          },
        ),
        const ExtensionUpdateReport(
          updated: <String>['Scraper One'],
          newPlugins: <String, List<String>>{
            'Stars': <String>['Bravo'],
            'Hindmovie': <String>['Charlie'],
          },
        ),
        const ExtensionUpdateReport(
          newRepositories: <String, List<String>>{
            'Universe': <String>['TJ Plugins'],
          },
        ),
      ]);

      expect(merged.updated, <String>['SuperStream', 'Scraper One']);
      expect(merged.newPlugins, <String, List<String>>{
        'Stars': <String>['Alpha', 'Bravo'],
        'Hindmovie': <String>['Charlie'],
      });
      expect(merged.newRepositories, <String, List<String>>{
        'Universe': <String>['TJ Plugins'],
      });
      expect(merged.isEmpty, isFalse);
    });

    test('nothing from anyone is nothing to say', () {
      final merged = ExtensionUpdateReport.merge(<ExtensionUpdateReport>[
        const ExtensionUpdateReport(),
        const ExtensionUpdateReport(),
      ]);

      expect(merged.isEmpty, isTrue);
      expect(merged.toasts(l10n), isEmpty);
    });
  });

  group('toasts', () {
    test('an update alone is one toast, as before', () {
      const report = ExtensionUpdateReport(
        updated: <String>['SuperStream', 'Scraper One'],
      );

      expect(report.toasts(l10n), <({String title, String message})>[
        (title: 'Updated 2 extensions', message: 'SuperStream, Scraper One'),
      ]);
    });

    test('says which collection the new repositories came from', () {
      const report = ExtensionUpdateReport(
        newRepositories: <String, List<String>>{
          'SkyStream Universe': <String>['CNCVerse', 'Rouge Plugins'],
        },
      );

      expect(report.toasts(l10n), <({String title, String message})>[
        (
          title: '2 new repositories in SkyStream Universe',
          message: 'CNCVerse, Rouge Plugins',
        ),
      ]);
    });

    test('says which repository the new plugins are in', () {
      const report = ExtensionUpdateReport(
        newPlugins: <String, List<String>>{
          'Stars': <String>['Alpha'],
        },
      );

      expect(report.toasts(l10n), <({String title, String message})>[
        (title: 'New plugin in Stars', message: 'Alpha'),
      ]);
    });

    test('every language names where the news came from, at any count', () {
      // Plural rules differ by language - Russian "21" takes the singular,
      // Arabic has a form for two - and each translation spells out its own
      // branches. A branch that dropped the placeholder would show a toast
      // that never says which repository.
      for (final locale in AppLocalizations.supportedLocales) {
        final strings = lookupAppLocalizations(locale);
        for (final count in <int>[1, 2, 3, 5, 11, 21, 22, 101]) {
          expect(
            strings.extensionsNewPlugins(count, 'Stars'),
            contains('Stars'),
            reason: '$locale, $count plugins',
          );
          expect(
            strings.extensionsNewRepositories(count, 'Universe'),
            contains('Universe'),
            reason: '$locale, $count repositories',
          );
        }
      }
    });

    test('everything at once is still three toasts, in a fixed order', () {
      const report = ExtensionUpdateReport(
        updated: <String>['SuperStream'],
        newRepositories: <String, List<String>>{
          'Universe': <String>['TJ Plugins'],
          'Mini': <String>['Rouge Plugins'],
        },
        newPlugins: <String, List<String>>{
          'Stars': <String>['Alpha', 'Bravo'],
          'Hindmovie': <String>['Charlie'],
          'TJ Plugins': <String>['Delta'],
          'MiraiExt': <String>['Echo'],
          'CNCVerse': <String>['Foxtrot'],
        },
      );

      expect(report.toasts(l10n), <({String title, String message})>[
        (title: 'Updated 1 extension', message: 'SuperStream'),
        (
          title: '2 new repositories in Universe, Mini',
          message: 'TJ Plugins, Rouge Plugins',
        ),
        (
          title: '6 new plugins in Stars, Hindmovie, TJ Plugins +2',
          message: 'Alpha, Bravo, Charlie +3',
        ),
      ]);
    });
  });
}
