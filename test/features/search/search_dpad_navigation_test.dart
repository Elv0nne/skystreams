import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/features/explore/presentation/delegates/explore_search_delegate.dart';
import 'package:skystream/features/home/presentation/delegates/home_search_delegate.dart';
import 'package:skystream/features/search/data/search_history_store.dart';
import 'package:skystream/features/search/presentation/search_history_provider.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';
import 'package:skystream/features/search/presentation/search_screen.dart';
import 'package:skystream/features/search/presentation/widgets/search_suggestion_row.dart';
import 'package:skystream/features/settings/presentation/general_settings_provider.dart';
import 'package:skystream/shared/widgets/cards_wrapper.dart';
import 'package:skystream/shared/widgets/multimedia_card.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

class _FakeStore implements SearchHistoryStore {
  List<String> queries;

  _FakeStore(this.queries);

  @override
  List<String> read() => queries;

  @override
  Future<void> write(List<String> next) async {
    queries = List<String>.from(next);
  }
}

/// A plugin whose requests are tagged `js:a` when they meet a bot check.
class _Plugin extends SkyStreamProvider {
  @override
  String get name => 'A';
  @override
  String get packageName => 'p.a';
  @override
  String? get checkSource => 'js:a';
  @override
  String get mainUrl => '';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['en'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.movie};
  @override
  Future<List<MultimediaItem>> search(String q, {CancelToken? cancelToken}) =>
      throw UnimplementedError();
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

class _Manager extends ExtensionManager {
  _Manager(this.plugins);

  final List<SkyStreamProvider> plugins;

  @override
  List<SkyStreamProvider> build() => plugins;
}

/// Suggestions that stay on their way until [deliver] brings them.
class _SlowSuggestions extends SearchSuggestionController {
  @override
  void onQueryChanged(String query) {
    state = state.copyWith(query: query, isLoading: true);
  }

  void deliver(List<String> suggestions) {
    state = state.copyWith(suggestions: suggestions, isLoading: false);
  }
}

void main() {
  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  /// The text of the row that currently holds focus, or null.
  String? focusedRowText(WidgetTester tester) {
    final focused = tester
        .widgetList<SearchSuggestionRow>(find.byType(SearchSuggestionRow))
        .where((row) => row.focusNode?.hasFocus ?? false);
    return focused.isEmpty ? null : focused.first.text;
  }

  bool fieldHasFocus(WidgetTester tester) {
    return tester
        .widgetList<EditableText>(find.byType(EditableText))
        .any((field) => field.focusNode.hasFocus);
  }

  group('search tab', () {
    /// The bot checks the app has met, which the screen's check section reads.
    SiteChecks useChecks({DateTime Function()? clock}) {
      final keys = SiteKeys.parse(
        File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
      );
      final checks = SiteChecks(clock: clock);
      final store = ClearanceStore();
      Clearance.instance.debugUse(
        store: store,
        siteKeys: keys,
        checks: checks,
        solver: ClearanceSolver(store: store, siteKeys: keys, checks: checks),
      );
      return checks;
    }

    Future<void> pumpSearch(
      WidgetTester tester, {
      required List<String> history,
      required Size size,
      Stream<SearchAggregateState>? results,
      List<SkyStreamProvider>? plugins,
      SearchSuggestionController Function()? suggestions,
      bool settle = true,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            searchHistoryStoreProvider.overrideWithValue(
              _FakeStore(List<String>.from(history)),
            ),
            searchResultsProvider.overrideWith(
              (ref) => results ?? Stream.value(const SearchAggregateState()),
            ),
            if (plugins != null)
              extensionManagerProvider.overrideWith(() => _Manager(plugins)),
            if (suggestions != null)
              searchSuggestionControllerProvider.overrideWith(suggestions),
            generalSettingsProvider.overrideWithValue(const GeneralSettings()),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark(),
            home: const SearchScreen(),
          ),
        ),
      );
      // Result cards show a looping placeholder while their posters load,
      // so a screen with results never settles.
      Future<void> pump() => settle
          ? tester.pumpAndSettle()
          : tester.pump(const Duration(seconds: 1));
      await pump();
      await tester.tap(find.byType(TextField));
      await pump();
    }

    testWidgets('TV: D-pad Down stays with the visible keyboard', (
      tester,
    ) async {
      await pumpSearch(tester, history: ['Dune'], size: const Size(1920, 1080));
      tester.view.viewInsets = const FakeViewPadding(bottom: 540);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(
        fieldHasFocus(tester),
        isTrue,
        reason: 'the TV IME must own arrows while its keyboard is visible',
      );
      expect(focusedRowText(tester), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    // Flutter reports the shortcuts bar an iPad shows over a hardware
    // keyboard as a keyboard docked at the bottom. Only Android's keyboards
    // use the arrows, so only there are they left to one.
    testWidgets('iPad: down leaves the field over the shortcuts bar', (
      tester,
    ) async {
      await pumpSearch(tester, history: ['Dune'], size: const Size(1366, 1024));
      tester.view.viewInsets = const FakeViewPadding(bottom: 69);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(focusedRowText(tester), 'Dune');
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('TV: controller A reopens the dismissed search keyboard', (
      tester,
    ) async {
      await pumpSearch(tester, history: const [], size: const Size(1920, 1080));
      tester.testTextInput.hide();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(fieldHasFocus(tester), isTrue);

      await press(tester, LogicalKeyboardKey.gameButtonA);

      expect(tester.testTextInput.isVisible, isTrue);
      expect(fieldHasFocus(tester), isTrue);
    });

    // The bar used to be a column, so down from the field meant "into the
    // scope pill". The pill stands beside the field now and the panel is what
    // is underneath, so down has to reach the list.
    for (final (name, size) in [
      ('desktop', const Size(1440, 900)),
      ('phone', const Size(400, 800)),
    ]) {
      testWidgets('$name: down from the field enters the list', (tester) async {
        await pumpSearch(tester, history: ['Dune', 'Arrival'], size: size);

        await press(tester, LogicalKeyboardKey.arrowDown);

        expect(focusedRowText(tester), 'Dune');
      });

      testWidgets('$name: up from the first row returns to the field', (
        tester,
      ) async {
        await pumpSearch(tester, history: ['Dune'], size: size);

        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focusedRowText(tester), 'Dune');

        await press(tester, LogicalKeyboardKey.arrowUp);

        expect(fieldHasFocus(tester), isTrue);
      });

      // A node out of the tree takes a request for the focus as one to keep,
      // and grants it whenever it is put in one. While the suggestions are on
      // their way the panel has no row yet, and down must wait for one: an
      // armed request would take the focus out of the field, mid-word, the
      // moment the first suggestion arrived.
      testWidgets('$name: down waits for suggestions on their way', (
        tester,
      ) async {
        await pumpSearch(
          tester,
          history: const [],
          size: size,
          suggestions: _SlowSuggestions.new,
        );
        // The panel's spinner turns until the suggestions come.
        await tester.enterText(find.byType(TextField), 'du');
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(SearchSuggestionRow), findsNothing);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 500));
        expect(fieldHasFocus(tester), isTrue);

        final suggestions = ProviderScope.containerOf(
          tester.element(find.byType(EditableText)),
        ).read(searchSuggestionControllerProvider.notifier) as _SlowSuggestions;
        suggestions.deliver(['Dune']);
        await tester.pumpAndSettle();
        expect(find.byType(SearchSuggestionRow), findsOneWidget);
        expect(fieldHasFocus(tester), isTrue, reason: 'focus jumped to a row');

        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focusedRowText(tester), 'Dune');
      });

      // The same for the first result, out of the tree while its row is
      // scrolled away from it.
      testWidgets('$name: down waits for a first result scrolled away', (
        tester,
      ) async {
        await pumpSearch(
          tester,
          history: const [],
          size: size,
          settle: false,
          plugins: const [],
          results: Stream.value(
            SearchAggregateState(
              results: [
                ProviderSearchResult(
                  providerId: 'p.a',
                  providerName: 'A',
                  results: [
                    for (var i = 0; i < 20; i++)
                      MultimediaItem(
                        title: 'Film $i',
                        url: 'u/$i',
                        posterUrl: '',
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
        final firstResult = tester
            .widget<MultimediaCard>(find.byType(MultimediaCard).first)
            .focusNode!;
        final row = tester
            .widget<ListView>(
              find.byWidgetPredicate(
                (w) => w is ListView && w.scrollDirection == Axis.horizontal,
              ),
            )
            .controller!;
        row.jumpTo(row.position.maxScrollExtent);
        await tester.pump(const Duration(seconds: 1));
        expect(firstResult.parent, isNull);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(seconds: 1));
        row.jumpTo(0);
        await tester.pump(const Duration(seconds: 1));
        expect(fieldHasFocus(tester), isTrue, reason: 'focus jumped to it');

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(seconds: 1));
        expect(firstResult.hasPrimaryFocus, isTrue);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('$name: right off a row reaches its remove button', (
        tester,
      ) async {
        await pumpSearch(tester, history: ['Dune'], size: size);

        await press(tester, LogicalKeyboardKey.arrowDown);
        await press(tester, LogicalKeyboardKey.arrowRight);

        // The body node gave the button its focus, so neither the row body
        // nor the field holds it now.
        expect(focusedRowText(tester), isNull);
        expect(fieldHasFocus(tester), isFalse);

        // And select on it drops the recent.
        await press(tester, LogicalKeyboardKey.enter);
        expect(find.text('Dune'), findsNothing);
      });

      // On a television the checks the search met sit between the field and
      // the results, so the D-pad has to stop there on its way down.
      testWidgets('$name: down from the field reaches the checks', (
        tester,
      ) async {
        final checks = useChecks();
        final began = checks.now;
        // A site that needs the person: nothing spins, so the screen settles.
        checks
          ..met('a.com', source: 'js:a')
          ..update('a.com', CheckState.needsYou);
        await pumpSearch(
          tester,
          history: const [],
          size: size,
          results: Stream.value(SearchAggregateState(startedAt: began)),
          plugins: [_Plugin()],
        );

        await press(tester, LogicalKeyboardKey.arrowDown);

        final showSites = tester.widget<IconButton>(
          find.ancestor(
            of: find.byTooltip('Show the sites'),
            matching: find.byType(IconButton),
          ),
        );
        expect(showSites.focusNode?.hasFocus, isTrue);
      });

      // A focus node keeps its last context after it leaves the tree. A
      // section that has gone mustn't catch Down: the press would be lost,
      // and the section's button would take the focus when it came back.
      testWidgets('$name: checks that have gone do not catch down', (
        tester,
      ) async {
        var time = DateTime(2026, 10, 3, 12);
        final checks = useChecks(clock: () => time);
        final searches = StreamController<SearchAggregateState>();
        addTearDown(searches.close);
        checks
          ..met('a.com', source: 'js:a')
          ..update('a.com', CheckState.needsYou);
        searches.add(SearchAggregateState(startedAt: time));
        await pumpSearch(
          tester,
          history: const [],
          size: size,
          results: searches.stream,
          plugins: [_Plugin()],
        );
        expect(find.byTooltip('Show the sites'), findsOneWidget);

        // A new search, which has met no check.
        time = time.add(const Duration(minutes: 1));
        searches.add(SearchAggregateState(startedAt: time));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Show the sites'), findsNothing);
        await press(tester, LogicalKeyboardKey.arrowDown);

        // Then it meets one.
        time = time.add(const Duration(seconds: 1));
        checks
          ..met('b.com', source: 'js:a')
          ..update('b.com', CheckState.needsYou);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Show the sites'), findsOneWidget);
        expect(fieldHasFocus(tester), isTrue);
      });

      // A result card and the scope pill hand their nodes to a CardsWrapper,
      // whose own key handler replaced the screen's on those nodes: on a
      // television, down from the pill and up from the first result went
      // past the checks.
      for (final (from, key) in [
        // A phone's bar has no labelled pill to stand on.
        if (name == 'desktop') ('the scope pill', LogicalKeyboardKey.arrowDown),
        ('the first result', LogicalKeyboardKey.arrowUp),
      ]) {
        testWidgets('$name: $from reaches the checks', (tester) async {
          final checks = useChecks();
          final began = checks.now;
          checks
            ..met('a.com', source: 'js:a')
            ..update('a.com', CheckState.needsYou);
          await pumpSearch(
            tester,
            history: const [],
            size: size,
            settle: false,
            results: Stream.value(
              SearchAggregateState(
                startedAt: began,
                results: [
                  ProviderSearchResult(
                    providerId: 'p.a',
                    providerName: 'A',
                    results: [
                      for (var i = 0; i < 12; i++)
                        MultimediaItem(
                          title: 'Film $i',
                          url: 'u/$i',
                          posterUrl: '',
                        ),
                    ],
                  ),
                ],
              ),
            ),
            plugins: [_Plugin()],
          );
          final node = from == 'the scope pill'
              ? tester
                    .widget<CardsWrapper>(
                      find.ancestor(
                        of: find.text('Movies & Shows'),
                        matching: find.byType(CardsWrapper),
                      ),
                    )
                    .focusNode!
              : tester
                    .widget<MultimediaCard>(find.byType(MultimediaCard).first)
                    .focusNode!;
          node.requestFocus();
          await tester.pump();
          expect(node.hasPrimaryFocus, isTrue);

          await tester.sendKeyEvent(key);
          await tester.pump();

          final showSites = tester.widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Show the sites'),
              matching: find.byType(IconButton),
            ),
          );
          expect(showSites.focusNode?.hasFocus, isTrue);
          await tester.pumpWidget(const SizedBox());
        });
      }

      testWidgets('$name: select on a row runs that search', (tester) async {
        await pumpSearch(tester, history: ['Dune'], size: size);

        await press(tester, LogicalKeyboardKey.arrowDown);
        await press(tester, LogicalKeyboardKey.enter);

        // The panel is down and the query is committed to the field. It used
        // to reopen a frame later: tearing down the focused row bounced focus
        // back to the field, which the screen reads as "show the panel".
        expect(find.byType(SearchSuggestionRow), findsNothing);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          'Dune',
        );
      });
    }

    // On a desktop the panel hangs over the results, which stay built under
    // it. While it is open its rows are what is below the bar, so down waits
    // for them rather than reaching past the panel to a result beneath.
    testWidgets('desktop: down waits for the panel, not a result under it', (
      tester,
    ) async {
      await pumpSearch(
        tester,
        history: const [],
        size: const Size(1440, 900),
        settle: false,
        plugins: const [],
        suggestions: _SlowSuggestions.new,
        results: Stream.value(
          SearchAggregateState(
            results: [
              ProviderSearchResult(
                providerId: 'p.a',
                providerName: 'A',
                results: [
                  for (var i = 0; i < 4; i++)
                    MultimediaItem(
                      title: 'Film $i',
                      url: 'u/$i',
                      posterUrl: '',
                    ),
                ],
              ),
            ],
          ),
        ),
      );
      final firstResult = tester
          .widget<MultimediaCard>(find.byType(MultimediaCard).first)
          .focusNode!;
      await tester.enterText(find.byType(TextField), 'du');
      await tester.pump(const Duration(milliseconds: 500));
      expect(firstResult.parent, isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 500));

      expect(fieldHasFocus(tester), isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('delegates', () {
    Future<void> openSearch(
      WidgetTester tester,
      SearchDelegate<void> Function() delegate, {
      required List<String> history,
    }) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            searchHistoryStoreProvider.overrideWithValue(
              _FakeStore(List<String>.from(history)),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => showSearch<void>(
                      context: context,
                      delegate: delegate(),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    // The delegates' fields are reached by a global handler, which must
    // follow the same rules as every other field on a television: while a
    // keyboard is up its arrows are its own, and Select - OK on a remote -
    // brings back a keyboard put away with Back.
    for (final (name, delegate) in <(String, SearchDelegate<void> Function())>[
      ('home', HomeSearchDelegate.new),
      ('explore', ExploreSearchDelegate.new),
    ]) {
      testWidgets('$name: down stays with a visible keyboard', (tester) async {
        await openSearch(tester, delegate, history: ['Dune']);
        tester.view.viewInsets = const FakeViewPadding(bottom: 540);
        addTearDown(tester.view.resetViewInsets);
        await tester.pump();

        await press(tester, LogicalKeyboardKey.arrowDown);

        expect(fieldHasFocus(tester), isTrue);
        expect(focusedRowText(tester), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));

      // An iPad's shortcuts bar reads as a docked keyboard; only Android's
      // keyboards use the arrows.
      testWidgets('$name: iPad: down leaves the field over the shortcuts bar', (
        tester,
      ) async {
        await openSearch(tester, delegate, history: ['Dune']);
        tester.view.viewInsets = const FakeViewPadding(bottom: 69);
        addTearDown(tester.view.resetViewInsets);
        await tester.pump();

        await press(tester, LogicalKeyboardKey.arrowDown);

        expect(focusedRowText(tester), 'Dune');
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

      testWidgets('$name: select stays with a visible keyboard', (
        tester,
      ) async {
        await openSearch(tester, delegate, history: ['Dune']);
        tester.view.viewInsets = const FakeViewPadding(bottom: 540);
        addTearDown(tester.view.resetViewInsets);
        await tester.pump();

        final handled = await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();

        expect(handled, isFalse, reason: 'the keyboard picks its key with OK');
        expect(fieldHasFocus(tester), isTrue);
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));

      testWidgets('$name: select reopens a keyboard put away with back', (
        tester,
      ) async {
        await openSearch(tester, delegate, history: ['Dune']);
        tester.testTextInput.hide();
        expect(tester.testTextInput.isVisible, isFalse);

        await press(tester, LogicalKeyboardKey.select);

        expect(tester.testTextInput.isVisible, isTrue);
        expect(fieldHasFocus(tester), isTrue);
      });

      // A node out of the tree takes a request for the focus as one to keep,
      // and grants it whenever it is put in one. Down with nothing under the
      // field must not arm that: the focus would leave the field mid-word
      // when the first suggestion arrives.
      testWidgets('$name: down with nothing below leaves the focus be', (
        tester,
      ) async {
        await openSearch(tester, delegate, history: const []);
        expect(find.byType(SearchSuggestionRow), findsNothing);

        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(fieldHasFocus(tester), isTrue);

        // A row arrives later, as the network's suggestions do while typing.
        final container = ProviderScope.containerOf(
          tester.element(find.byType(EditableText)),
        );
        await container.read(searchHistoryProvider.notifier).add('Dune');
        await tester.pumpAndSettle();

        expect(find.byType(SearchSuggestionRow), findsOneWidget);
        expect(
          fieldHasFocus(tester),
          isTrue,
          reason: 'focus jumped to the row',
        );
      });
    }

    // An EditableText swallows arrow keys for its own caret, so without the
    // global handler a remote could never leave the search field.
    testWidgets('home: down from the field enters the list', (tester) async {
      await openSearch(
        tester,
        HomeSearchDelegate.new,
        history: ['Dune', 'Arrival'],
      );
      expect(fieldHasFocus(tester), isTrue);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(focusedRowText(tester), 'Dune');
    });

    testWidgets('home: right off a row reaches its remove button', (
      tester,
    ) async {
      await openSearch(tester, HomeSearchDelegate.new, history: ['Dune']);

      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.enter);

      expect(find.text('Dune'), findsNothing);
    });

    testWidgets('explore: down from the field enters the list', (tester) async {
      await openSearch(
        tester,
        ExploreSearchDelegate.new,
        history: ['Dune', 'Arrival'],
      );
      expect(fieldHasFocus(tester), isTrue);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(focusedRowText(tester), 'Dune');
    });

    testWidgets('explore: select on a row runs that search', (tester) async {
      await openSearch(tester, ExploreSearchDelegate.new, history: ['Dune']);

      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);

      // showResults swapped the suggestions out for the results grid.
      expect(find.byType(SearchSuggestionRow), findsNothing);
    });

    // The delegates watch the keys app-wide, so they must stop with their
    // search and keep to their own field while it is open.
    group('opened as the screens open them', () {
      late FocusNode screenField;

      /// Opens a search over a page with a plain field of its own - one with
      /// no remote keys, so Select there is nobody's.
      Future<void> openOverScreen(
        WidgetTester tester,
        Future<void> Function(BuildContext) show,
      ) async {
        screenField = FocusNode();
        addTearDown(screenField.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              searchHistoryStoreProvider.overrideWithValue(
                _FakeStore(['Dune']),
              ),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: ThemeData.dark(),
              home: Builder(
                builder: (context) => Scaffold(
                  body: Column(
                    children: [
                      TextField(focusNode: screenField),
                      ElevatedButton(
                        onPressed: () => unawaited(show(context)),
                        child: const Text('open'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }

      final searches = <(String, Future<void> Function(BuildContext))>[
        ('home', showHomeSearch),
        ('explore', showExploreSearch),
      ];
      for (final (name, show) in searches) {
        testWidgets('$name: closing the search disposes its delegate', (
          tester,
        ) async {
          await openOverScreen(tester, show);
          // The delegate's own node, on its first row.
          final row = tester
              .widget<SearchSuggestionRow>(find.byType(SearchSuggestionRow))
              .focusNode!;

          await tester.tap(find.byIcon(Icons.arrow_back_rounded));
          await tester.pumpAndSettle();

          expect(find.byType(SearchSuggestionRow), findsNothing);
          expect(
            () => ChangeNotifier.debugAssertNotDisposed(row),
            throwsFlutterError,
          );
        });

        testWidgets('$name: a closed search leaves the screen\'s field alone', (
          tester,
        ) async {
          await openOverScreen(tester, show);
          await tester.tap(find.byIcon(Icons.arrow_back_rounded));
          await tester.pumpAndSettle();

          screenField.requestFocus();
          await tester.pump();
          tester.testTextInput.hide();
          await press(tester, LogicalKeyboardKey.select);

          expect(screenField.hasFocus, isTrue);
          expect(tester.testTextInput.isVisible, isFalse);
        });

        // A title's page goes over the search, which stays built beneath it.
        testWidgets('$name: a field on a page over the search is its own', (
          tester,
        ) async {
          await openOverScreen(tester, show);
          final pageField = FocusNode();
          addTearDown(pageField.dispose);
          unawaited(
            tester
                .state<NavigatorState>(find.byType(Navigator))
                .push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      body: TextField(focusNode: pageField, autofocus: true),
                    ),
                  ),
                ),
          );
          await tester.pumpAndSettle();
          expect(pageField.hasFocus, isTrue);
          tester.testTextInput.hide();

          await press(tester, LogicalKeyboardKey.select);
          expect(tester.testTextInput.isVisible, isFalse);

          await press(tester, LogicalKeyboardKey.arrowDown);
          expect(pageField.hasFocus, isTrue);
        });

        // A page pushed without taking the focus leaves it in the search
        // field beneath - which is not the field on screen any more.
        testWidgets('$name: a covered search leaves even its own field be', (
          tester,
        ) async {
          await openOverScreen(tester, show);
          final searchField = FocusManager.instance.primaryFocus!;
          unawaited(
            tester
                .state<NavigatorState>(find.byType(Navigator))
                .push(
                  MaterialPageRoute<void>(
                    requestFocus: false,
                    builder: (_) => const Scaffold(body: Text('a title')),
                  ),
                ),
          );
          await tester.pumpAndSettle();
          expect(searchField.hasPrimaryFocus, isTrue);
          tester.testTextInput.hide();

          await press(tester, LogicalKeyboardKey.select);
          expect(tester.testTextInput.isVisible, isFalse);

          await press(tester, LogicalKeyboardKey.arrowDown);
          expect(searchField.hasPrimaryFocus, isTrue);
        });

        // The search opens on the nearest navigator, and stays on top of it
        // while the focus goes to a field outside it - another tab's, kept
        // alive beside it.
        testWidgets('$name: a field outside its navigator is not its', (
          tester,
        ) async {
          final beside = FocusNode();
          addTearDown(beside.dispose);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                searchHistoryStoreProvider.overrideWithValue(
                  _FakeStore(['Dune']),
                ),
              ],
              child: MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: Column(
                    children: [
                      TextField(focusNode: beside),
                      Expanded(
                        child: Navigator(
                          onGenerateRoute: (_) => MaterialPageRoute<void>(
                            builder: (context) => ElevatedButton(
                              onPressed: () => unawaited(show(context)),
                              child: const Text('open'),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          beside.requestFocus();
          await tester.pump();
          tester.testTextInput.hide();

          await press(tester, LogicalKeyboardKey.select);
          expect(tester.testTextInput.isVisible, isFalse);

          await press(tester, LogicalKeyboardKey.arrowDown);
          expect(beside.hasFocus, isTrue);
        });
      }
    });
  });
}
