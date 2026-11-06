/// How the engine host loads plugins on the engine.
library;

import 'dart:async';

import 'package:cs3_engine/cs3_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_pages.dart';

import 'extension_ui/fake_page_browser.dart';

/// An engine that notes the plugins it is asked to load.
class _Engine implements Cs3Engine {
  final loads = <({String path, String? url})>[];

  @override
  bool get isRunning => true;

  @override
  Future<Map<String, dynamic>> loadPlugin(String path, {String? url}) async {
    loads.add((path: path, url: url));
    return {'providers': <Object>[]};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Host extends CloudStreamEngineHost {
  _Host(this.running);

  final _Engine running;

  @override
  Future<Cs3Engine> engine() async => running;
}

/// An engine whose loads register once [converted] completes, as on the desktops and iOS: the engine converts a
/// plugin's file before it takes its load lock, so an unload that comes meanwhile finds nothing to drop.
class _ConvertingEngine implements Cs3Engine {
  final converted = Completer<void>();

  /// Whether the plugin is loaded on the engine.
  bool registered = false;

  @override
  bool get isRunning => true;

  @override
  Future<Map<String, dynamic>> loadPlugin(String path, {String? url}) async {
    await converted.future;
    registered = true;
    return {'providers': <Object>[], 'hasSettings': true};
  }

  @override
  Future<Map<String, dynamic>> unloadPlugin(String path) async {
    final had = registered;
    registered = false;
    return {'unloaded': had};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ConvertingHost extends CloudStreamEngineHost {
  _ConvertingHost(this.running);

  final _ConvertingEngine running;

  @override
  Future<Cs3Engine> engine() async => running;
}

/// An engine for extension screens: opens screen 7, and notes what it's asked.
class _ScreenEngine implements Cs3Engine {
  final calls = <String>[];

  @override
  bool get isRunning => true;

  @override
  Future<Map<String, dynamic>> loadPlugin(String path, {String? url}) async {
    calls.add('load $path $url');
    return {'providers': <Object>[], 'hasSettings': true};
  }

  @override
  Future<int> openSettings(String path) async {
    calls.add('open $path');
    return 7;
  }

  @override
  Future<Map<String, dynamic>> uiAction(int session, int node, String action, [Object? value]) async {
    calls.add('act $session $node $action $value');
    return {'done': true};
  }

  @override
  Future<void> closeUi(int session, {bool force = false}) async => calls.add('close $session $force');

  @override
  Future<Map<String, dynamic>> reloadPlugin(String path, {String? url}) async {
    calls.add('reload $path $url');
    return {'providers': <Object>[], 'hasSettings': false};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ScreenHost extends CloudStreamEngineHost {
  _ScreenHost(this.running);

  final Cs3Engine running;

  @override
  Future<Cs3Engine> engine() async => running;
}

/// An engine that notes what it's told when it starts.
class _ToldEngine implements Cs3Engine {
  final told = <String>[];

  @override
  Future<Map<String, dynamic>> setRepositories(List<Map<String, Object?>> repositories) async {
    told.add('repositories ${repositories.length}');
    return {};
  }

  @override
  Future<Map<String, dynamic>> setLanguage(String language) async {
    told.add('language $language');
    return {};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // ViStream registers nothing unless it was installed from its own repository.
  test('plugins load with the address they were downloaded from', () async {
    final engine = _Engine();
    final host = _Host(engine);
    await host.ensureLoaded('/p/a.cs3', pluginUrl: 'https://repo.test/a.cs3');
    await host.reload('/p/b.cs3', pluginUrl: 'https://repo.test/b.cs3');
    await host.run('/p/c.cs3', (_) async => null, pluginUrl: 'https://repo.test/c.cs3');
    expect(engine.loads, [
      (path: '/p/a.cs3', url: 'https://repo.test/a.cs3'),
      (path: '/p/b.cs3', url: 'https://repo.test/b.cs3'),
      (path: '/p/c.cs3', url: 'https://repo.test/c.cs3'),
    ]);
  });

  test('a settings screen opens on its plugin, loaded first, and its actions and closing reach the engine', () async {
    final engine = _ScreenEngine();
    final host = _ScreenHost(engine);
    expect(await host.openSettings('/p/a.cs3', pluginUrl: 'https://repo.test/a.cs3'), 7);
    await host.uiAction(7, 3, 'check', true);
    await host.closeUi(7, force: true);
    expect(engine.calls, [
      'load /p/a.cs3 https://repo.test/a.cs3',
      'open /p/a.cs3',
      'act 7 3 check true',
      'close 7 true',
    ]);
  });

  test("loading afresh runs the plugin's load again, and every load's answer is heard once", () async {
    final engine = _ScreenEngine();
    final host = _ScreenHost(engine);
    final heard = <Object?>[];
    final listening = host.loads.listen((load) => heard.add(load.answer['hasSettings']));
    await host.ensureLoaded('/p/a.cs3');
    await host.ensureLoaded('/p/a.cs3');
    final answer = await host.reloadAfresh('/p/a.cs3', pluginUrl: 'https://repo.test/a.cs3');
    await Future<void>.delayed(Duration.zero);
    expect(answer['hasSettings'], false);
    expect(heard, [true, false]);
    expect(engine.calls.where((c) => c.startsWith('reload')), ['reload /p/a.cs3 https://repo.test/a.cs3']);
    await listening.cancel();
  });

  test('a starting engine is told the repositories and the language, the latest of each', () async {
    final engine = _ToldEngine();
    final host = CloudStreamEngineHost();
    await host.setRepositories([
      {'url': 'https://repo.test/repo.json', 'name': 'Repo'},
    ]);
    await host.setLanguage('hi');
    await host.setLanguage('kn');
    await host.tell(engine);
    expect(engine.told, ['repositories 1', 'language kn']);
  });

  test('while CloudStream is switched off nothing loads, a screen still holding a provider included', () async {
    final engine = _ScreenEngine();
    final host = _ScreenHost(engine);
    host.setSwitchedOff(true);
    final refused = throwsA(isA<CloudStreamSwitchedOff>());
    await expectLater(host.ensureLoaded('/p/a.cs3'), refused);
    await expectLater(host.reload('/p/a.cs3'), refused);
    await expectLater(host.reloadAfresh('/p/a.cs3'), refused);
    await expectLater(host.openSettings('/p/a.cs3'), refused);
    await expectLater(host.run('/p/a.cs3', (_) async => null), refused);
    expect(engine.calls, isEmpty);
    host.setSwitchedOff(false);
    await host.ensureLoaded('/p/a.cs3');
    expect(engine.calls, ['load /p/a.cs3 null']);
  });

  test('a load under way as CloudStream is switched off is unloaded as it ends', () async {
    final engine = _ConvertingEngine();
    final host = _ConvertingHost(engine);
    final loading = host.ensureLoaded('/p/a.cs3');
    await Future<void>.delayed(Duration.zero);
    host.setSwitchedOff(true);
    // The switch's own unload comes while the file converts: nothing is registered yet.
    await host.unload('/p/a.cs3', uninstalling: false);
    engine.converted.complete();
    await loading;
    expect(engine.registered, isFalse);
  });

  test('a load under way as CloudStream is switched off and on again stays loaded', () async {
    final engine = _ConvertingEngine();
    final host = _ConvertingHost(engine);
    final loading = host.ensureLoaded('/p/a.cs3');
    await Future<void>.delayed(Duration.zero);
    host.setSwitchedOff(true);
    await host.unload('/p/a.cs3', uninstalling: false);
    host.setSwitchedOff(false);
    engine.converted.complete();
    await loading;
    expect(engine.registered, isTrue);
  });

  test('extension screens show on every platform SkyStream runs on', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      try {
        expect(extensionScreensSupported, platform != TargetPlatform.fuchsia, reason: '$platform');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }
  });

  test('stopping the engine closes the pages its screens showed', () async {
    final browser = FakePageBrowser();
    final pages = ExtensionPages(create: () async => browser);
    final host = CloudStreamEngineHost(pages: pages);
    await pages.open({'rid': 1, 'session': 1, 'node': 2, 'url': 'https://site.test/'}, PageReports().call);
    await host.dispose();
    expect(browser.disposed, isTrue);
    expect(pages.at(1, 2), isNull);
  });
}
