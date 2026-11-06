import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
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
import 'package:skystream/features/home/presentation/delegates/home_search_delegate.dart';
import 'package:skystream/features/search/data/search_history_store.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// Home's search: the check its plugin met, under the spinner and in place
/// of its results, and searching again once that check clears.
class _Plugin extends SkyStreamProvider {
  _Plugin(this.answers);

  final List<Future<List<MultimediaItem>> Function()> answers;
  int searches = 0;

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
      answers[(searches++).clamp(0, answers.length - 1)]();
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

class _FakeActiveProvider extends ActiveProvider {
  _FakeActiveProvider(this._initial);

  final SkyStreamProvider? _initial;

  @override
  SkyStreamProvider? build() => _initial;

  @override
  Future<void> set(SkyStreamProvider? provider) async {
    state = provider;
  }
}

class _FakeStore implements SearchHistoryStore {
  List<String> queries = [];

  @override
  List<String> read() => queries;

  @override
  Future<void> write(List<String> next) async {
    queries = List<String>.from(next);
  }
}

/// No suggestions, and no request for them.
class _NoSuggestions extends SearchSuggestionController {
  @override
  void onQueryChanged(String query) {}
}

void main() {
  // Built inside the test body: futures made in setUp belong to the real
  // zone, and pumping never runs their callbacks.
  void useClearance(SiteChecks checks) {
    final keys = SiteKeys.parse(
      File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
    );
    final store = ClearanceStore();
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      checks: checks,
      solver: ClearanceSolver(store: store, siteKeys: keys, checks: checks),
    );
  }

  /// Opens Home's search for "dune" and runs it.
  Future<void> search(WidgetTester tester, _Plugin plugin) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeProviderProvider.overrideWith(
            () => _FakeActiveProvider(plugin),
          ),
          searchHistoryStoreProvider.overrideWithValue(_FakeStore()),
          searchSuggestionControllerProvider.overrideWith(_NoSuggestions.new),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showSearch<void>(
                    context: context,
                    delegate: HomeSearchDelegate(),
                    query: 'dune',
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
    await tester.showKeyboard(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();
  }

  // Home's search doesn't wait for a person: once the automatic try wants
  // one, the search ends empty. The check it met, 20 s before, stays on
  // screen with Verify.
  testWidgets('a search that gave up on a check keeps it on screen, with '
      'Verify, and searches again once it clears', (tester) async {
    var now = DateTime(2020);
    final checks = SiteChecks(clock: () => now);
    useClearance(checks);
    final a = _Plugin([
      () async {
        checks.met('a.com', source: 'js:a');
        now = now.add(const Duration(seconds: 20));
        checks.update('a.com', CheckState.needsYou);
        throw Exception('challenge');
      },
      () async => const <MultimediaItem>[],
    ]);
    await search(tester, a);
    expect(find.text('a.com needs a quick check'), findsOneWidget);
    expect(find.text('Verify'), findsOneWidget);

    checks.update('a.com', CheckState.cleared);
    await tester.pump();
    await tester.pump();
    expect(a.searches, 2);
  });

  // A check that clears during the search lets the request waiting on it
  // carry on: searching again would only send the search twice.
  testWidgets('a check that clears while Home searches does not send a '
      'second search', (tester) async {
    final checks = SiteChecks();
    useClearance(checks);
    final gate = Completer<void>();
    final a = _Plugin([
      () async {
        checks.met('a.com', source: 'js:a');
        await gate.future;
        return const <MultimediaItem>[];
      },
    ]);
    await search(tester, a);
    expect(find.textContaining('Checking a.com automatically'), findsOneWidget);

    checks.update('a.com', CheckState.cleared);
    await tester.pump();
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(a.searches, 1);
  });
}
