import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_models.dart';
import 'package:skystream/core/cloudstream/cloudstream_provider.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';

/// Which CloudStream extension a bot check belongs to: the engine's requests
/// don't say, so the calls running decide.
void main() {
  final keys = SiteKeys.parse(
    File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
  );
  const a = (provider: 'cs3:k/A', mainUrl: 'https://www.a.com');
  const b = (provider: 'cs3:k/B', mainUrl: 'https://b.org');

  test('the running extension whose own site was checked', () {
    expect(
      cloudStreamCheckSource(Uri.parse('https://cdn.a.com/x'), [a, b], keys),
      'cs3:k/A',
    );
  });

  test('the only one running, when none is on that site', () {
    expect(
      cloudStreamCheckSource(Uri.parse('https://host.net/x'), [b], keys),
      'cs3:k/B',
    );
  });

  test('nobody in particular, when several run elsewhere or none runs', () {
    expect(
      cloudStreamCheckSource(Uri.parse('https://host.net/x'), [a, b], keys),
      'cs3',
    );
    expect(
      cloudStreamCheckSource(Uri.parse('https://host.net/x'), const [], keys),
      'cs3',
    );
  });

  test('a CloudStream provider is known by its id', () {
    final provider = CloudStreamProvider(
      plugin: CsInstalledPlugin(
        info: CsPluginInfo.fromJson({
          'internalName': 'P',
          'name': 'P',
          'url': 'u',
          'version': 1,
        }, 'https://repo/r.json'),
        filePath: '/p.cs3',
      ),
      pluginKey: 'k',
      info: const CsProviderInfo(name: 'A', mainUrl: 'https://www.a.com'),
      host: CloudStreamEngineHost(),
    );
    expect(provider.checkSource, 'cs3:k/A');
  });

  test('an extension whose site moved is still found', () {
    expect(
      cloudStreamCheckSource(
        Uri.parse('https://www.new.org/x'),
        [(provider: 'cs3:k/A', mainUrl: 'https://old.com'), b],
        keys,
        moves: {'www.old.com': Uri.parse('https://www.new.org')},
      ),
      'cs3:k/A',
    );
  });

  test('a move the engine saw is saved by host, and www is no move', () {
    final store = ClearanceStore();
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      solver: ClearanceSolver(store: store, siteKeys: keys),
    );
    recordSiteMoved(Clearance.instance, {
      'event': 'siteMoved',
      'from': 'https://www.old.com/x',
      'to': 'https://www.new.org/x',
    });
    expect(store.movedTo('www.old.com'), Uri.parse('https://www.new.org'));
    recordSiteMoved(Clearance.instance, {
      'event': 'siteMoved',
      'from': 'https://a.com/x',
      'to': 'https://www.a.com/x',
    });
    expect(store.movedTo('a.com'), isNull);
    // Back where the extension asked: the move is gone.
    recordSiteMoved(Clearance.instance, {
      'event': 'siteMoved',
      'from': 'https://www.old.com/x',
      'to': 'https://old.com/x',
    });
    expect(store.movedTo('www.old.com'), isNull);
  });

  test('a site the engine found lets only the browser through is kept so', () {
    final store = ClearanceStore()
      ..recordSolve(
        'a.com',
        cookies: const [],
        agent: 'Browser/1.0',
        url: 'https://www.a.com/',
      );
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      solver: ClearanceSolver(store: store, siteKeys: keys),
    );
    recordSiteBrowserOnly(Clearance.instance, {
      'event': 'siteBrowserOnly',
      'url': 'https://www.a.com/search?q=x',
    });
    expect(store['a.com']!.browserOnly, isTrue);
  });

  test('a move the engine found dead is forgotten', () {
    final store = ClearanceStore()
      ..recordMove('www.old.com', Uri.parse('https://www.new.org'));
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      solver: ClearanceSolver(store: store, siteKeys: keys),
    );
    forgetSiteMove(Clearance.instance, {
      'event': 'siteMoveDropped',
      'from': 'https://www.old.com/x',
    });
    expect(store.movedTo('www.old.com'), isNull);
  });
}
