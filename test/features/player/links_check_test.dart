import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';

import 'vlc_screen_harness.dart';

/// While the plugin's links wait on a bot check, the startup view says which
/// site is being checked, and for how long.
class _Plugin extends SkyStreamProvider {
  _Plugin(this.links);

  final Future<List<StreamResult>> Function() links;

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
  Future<List<StreamResult>> loadStreams(String url) => links();
  @override
  Future<List<MultimediaItem>> search(String q, {CancelToken? cancelToken}) =>
      throw UnimplementedError();
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
}

class _Manager extends ExtensionManager {
  _Manager(this.plugins);

  final List<SkyStreamProvider> plugins;

  @override
  List<SkyStreamProvider> build() => plugins;
}

void main() {
  setUp(installEngineMocks);
  tearDown(removeEngineMocks);

  // The check line is the startup view's: once a video plays, the checks the
  // app meets elsewhere mustn't redraw the player, or keep a clock running.
  testWidgets(
    'once the video plays, a check met elsewhere doesn\'t redraw the '
    'player',
    variant: texturePlatform,
    (tester) async {
      final keys = SiteKeys.parse(
        File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
      );
      final checks = SiteChecks();
      final store = ClearanceStore();
      Clearance.instance.debugUse(
        store: store,
        siteKeys: keys,
        checks: checks,
        solver: ClearanceSolver(store: store, siteKeys: keys, checks: checks),
      );
      await pumpPlayer(tester);
      await sendFirstFrame(tester);
      for (var i = 0; i < 40 && tester.binding.hasScheduledFrame; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        tester.binding.hasScheduledFrame,
        isFalse,
        reason: 'idle to start',
      );

      checks.met('a.com', source: 'js:a');
      await Future<void>.value();
      await Future<void>.value();

      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('while the links wait on a check, the startup view counts it', (
    tester,
  ) async {
    final keys = SiteKeys.parse(
      File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
    );
    final checks = SiteChecks();
    final store = ClearanceStore();
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      checks: checks,
      solver: ClearanceSolver(store: store, siteKeys: keys, checks: checks),
    );
    final links = Completer<List<StreamResult>>();
    final plugin = _Plugin(() {
      checks.met('a.com', source: 'js:a');
      return links.future;
    });

    await pumpPlayer(
      tester,
      item: MultimediaItem(
        title: 'Film',
        url: 'https://a.com/film/1',
        posterUrl: '',
        provider: 'p.a',
      ),
      videoUrl: 'https://a.com/film/1',
      overrides: [
        extensionManagerProvider.overrideWith(() => _Manager([plugin])),
      ],
    );
    expect(
      find.textContaining('Checking a.com automatically…'),
      findsOneWidget,
    );

    // Once it clears, the view says whose links it's getting again.
    checks.update('a.com', CheckState.cleared);
    await tester.pump();
    expect(find.textContaining('Checking a.com'), findsNothing);

    links.complete(const []);
    await tester.pumpWidget(const SizedBox());
  });
}
