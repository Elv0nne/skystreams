import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_torrent_server/flutter_torrent_server.dart';
import 'package:http/http.dart' as http;
import 'package:skystream/core/services/torrent_service.dart';

import 'fake_torr_server.dart';

const _sintelHash = '08ada5a7a6183aae1e09d831df6748d566095a10';
const _sintel = 'magnet:?xt=urn:btih:$_sintelHash&dn=Sintel';
const _bbb =
    'magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=BBB';

/// 256 MB, as the service writes it.
const _bytes256 = 256 * 1048576;

TorrentService _service(FakeTorrServer fake, {bool sized = true}) {
  final service = TorrentService.forTesting(fake);
  if (sized) service.bufferForNextStart(cacheMb: 256, readAheadPercent: 75);
  return service;
}

/// Runs [body] with the service's HTTP going to [fake].
Future<T> _on<T>(FakeTorrServer fake, Future<T> Function() body) =>
    http.runWithClient(body, () => fake.client);

int _count(FakeTorrServer fake, String entry) =>
    fake.log.where((e) => e == entry).length;

void main() {
  test('every settings request carries the per-launch token', () async {
    final fake = FakeTorrServer();
    final service = _service(fake);
    await _on(fake, service.start);
    expect(fake.settingsRequests, hasLength(3), reason: 'get, set, get');
    for (final request in fake.settingsRequests) {
      expect(
        request.headers[FlutterTorrentServer.authTokenHeader],
        fake.authToken,
      );
    }

    // A server holding another token refuses, and the torrent still plays.
    final other = FakeTorrServer(acceptToken: 'not this one');
    final refused = _service(other);
    expect(await _on(other, () => refused.getStreamUrl(_sintel)), isNotNull);
    final settings = refused.takeStartSettings()!;
    expect(settings.outcome, TorrentSettingsOutcome.failed);
    expect(settings.error, 'read');
    expect(_count(other, 'set'), 0);
  });

  test('a start reads the settings, changes only the cache and its split, '
      'and writes them back', () async {
    final held = <String, Object?>{
      'RetrackersMode': 3,
      'PreloadCache': 30,
      'EnableIPv6': true,
      'TorrentsSavePath': '/x',
      'UseDisk': true,
      'Foo': 7,
    };
    final fake = FakeTorrServer(settings: held);
    final before = Map<String, Object?>.of(fake.settings);
    final service = _service(fake);
    await _on(fake, service.start);

    expect(fake.log, <String>['start', 'get', 'set', 'get']);
    expect(fake.lastSet, <String, Object?>{
      ...before,
      'CacheSize': _bytes256,
      'ReaderReadAHead': 75,
    });
    // Nothing else moved: a partial write would have zeroed these.
    expect(fake.settings['RetrackersMode'], 3);
    expect(fake.settings['PreloadCache'], 30);
    expect(fake.settings['EnableIPv6'], isTrue);
    final settings = service.takeStartSettings()!;
    expect(settings.outcome, TorrentSettingsOutcome.applied);
    expect(settings.readBackOk, isTrue);
    expect(settings.hadMb, 64);
    expect(settings.hadAhead, 95);
  });

  test(
    'a torrent added after the start is never followed by a write',
    () async {
      final fake = FakeTorrServer();
      final service = _service(fake);
      await _on(fake, () async {
        await service.getStreamUrl(_sintel);
        service.bufferForNextStart(cacheMb: 512, readAheadPercent: 88);
        await service.getStreamUrl(_bbb);
      });
      expect(_count(fake, 'set'), 1);
      final firstAdd = fake.log.indexWhere((e) => e.startsWith('add:'));
      expect(fake.log.indexOf('set'), lessThan(firstAdd));
      expect(
        fake.log.sublist(firstAdd).where((e) => e == 'get' || e == 'set'),
        isEmpty,
        reason: 'a write after an add drops the torrent it took',
      );
      expect(fake.loaded, hasLength(2));
    },
  );

  test('a server that already holds the sizes is not written', () async {
    final fake = FakeTorrServer(
      settings: <String, Object?>{
        'CacheSize': _bytes256,
        'ReaderReadAHead': 75,
      },
    );
    final service = _service(fake);
    await _on(fake, service.start);
    expect(fake.log, <String>['start', 'get']);
    expect(
      service.takeStartSettings()!.outcome,
      TorrentSettingsOutcome.unchanged,
    );
  });

  test('handing sizes over never posts', () async {
    final fake = FakeTorrServer();
    final service = TorrentService.forTesting(fake);
    await _on(fake, () async {
      service.bufferForNextStart(cacheMb: 256, readAheadPercent: 75);
      await Future<void>.delayed(Duration.zero);
      expect(fake.log, isEmpty);
      await service.start();
      final requests = fake.settingsRequests.length;
      service.bufferForNextStart(cacheMb: 512, readAheadPercent: 88);
      await Future<void>.delayed(Duration.zero);
      expect(fake.settingsRequests, hasLength(requests));
    });
  });

  test('two opens at once share one start', () async {
    final fake = FakeTorrServer()..holdSet = Completer<void>();
    final service = _service(fake);
    await _on(fake, () async {
      final first = service.getStreamUrl(_sintel);
      final second = service.getStreamUrl(_bbb);
      await fake.reached('set');
      expect(
        fake.log.where((e) => e == 'adding'),
        isEmpty,
        reason: 'no add before the write has answered',
      );
      fake.holdSet!.complete();
      expect(await first, isNotNull);
      expect(await second, isNotNull);
    });
    expect(_count(fake, 'start'), 1);
    expect(_count(fake, 'set'), 1);
    final setAt = fake.log.indexOf('set');
    for (final add in fake.log.where((e) => e == 'adding')) {
      expect(fake.log.indexOf(add), greaterThan(setAt));
    }
    expect(fake.loaded, hasLength(2), reason: 'both survive: none was dropped');
  });

  test('a stop during the settings write leaves the service stopped', () async {
    final fake = FakeTorrServer()..holdSet = Completer<void>();
    final service = _service(fake);
    await _on(fake, () async {
      final url = service.getStreamUrl(_sintel);
      await fake.reached('set');
      await service.stop();
      fake.holdSet!.complete();
      expect(await url, isNull);
      expect(await service.getCurrentStatus(), isNull);
      expect(fake.log.where((e) => e == 'adding'), isEmpty);

      fake.holdSet = null;
      expect(await service.getStreamUrl(_sintel), isNotNull);
    });
    expect(_count(fake, 'start'), 2, reason: 'the next open starts again');
  });

  for (final status in <int>[401, 400, 500]) {
    test("a write answered $status doesn't stop the torrent", () async {
      final fake = FakeTorrServer()..setStatus = status;
      final service = _service(fake);
      final url = await _on(fake, () => service.getStreamUrl(_sintel));
      expect(url, isNotNull);
      final settings = service.takeStartSettings()!;
      expect(settings.outcome, TorrentSettingsOutcome.failed);
      expect(settings.error, 'set $status');
      expect(settings.readBackOk, isFalse);
      expect(fake.log.where((e) => e == 'get'), hasLength(2));
    });
  }

  testWidgets("a write that doesn't answer in 20 s doesn't stop the torrent", (
    tester,
  ) async {
    final fake = FakeTorrServer()..holdSet = Completer<void>();
    final service = _service(fake);
    String? url;
    var done = false;
    unawaited(
      _on(fake, () => service.getStreamUrl(_sintel)).then((value) {
        url = value;
        done = true;
      }),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 19));
    expect(done, isFalse, reason: 'TorrServer can take a while to rebuild');
    await tester.pump(const Duration(seconds: 2));
    for (var i = 0; i < 10 && !done; i++) {
      await tester.pump();
    }
    expect(url, isNotNull);
    final settings = service.takeStartSettings()!;
    expect(settings.outcome, TorrentSettingsOutcome.failed);
    expect(settings.error, 'set TimeoutException');
    expect(settings.setMs, greaterThanOrEqualTo(20000));
  });

  test(
    "an answer the service doesn't understand is never written over",
    () async {
      final fake = FakeTorrServer()..settings.remove('CacheSize');
      final service = _service(fake);
      await _on(fake, service.start);
      expect(_count(fake, 'set'), 0);
      final settings = service.takeStartSettings()!;
      expect(settings.outcome, TorrentSettingsOutcome.failed);
      expect(settings.error, 'unknown answer');
    },
  );

  test('the read-back says whether the server took the sizes', () async {
    final fake = FakeTorrServer()..ignoreSet = true;
    final service = _service(fake);
    await _on(fake, service.start);
    final settings = service.takeStartSettings()!;
    expect(settings.outcome, TorrentSettingsOutcome.failed);
    expect(settings.readBackOk, isFalse);
    expect(settings.error, 'not taken');
  });

  test('a start after a stop compares again', () async {
    final fake = FakeTorrServer();
    final service = _service(fake);
    await _on(fake, () async {
      await service.start();
      await service.stop();
      await service.start();
    });
    expect(fake.log, <String>[
      'start', 'get', 'set', 'get', 'stop', 'start', 'get', //
    ]);
    expect(
      service.takeStartSettings()!.outcome,
      TorrentSettingsOutcome.unchanged,
    );
  });

  test(
    'with no sizes handed over, a start leaves the settings alone',
    () async {
      final fake = FakeTorrServer();
      final service = _service(fake, sized: false);
      await _on(fake, service.start);
      expect(fake.log, <String>['start']);
      expect(
        service.takeStartSettings()!.outcome,
        TorrentSettingsOutcome.notAsked,
      );
    },
  );

  test('the outcome is handed to one open only', () async {
    final fake = FakeTorrServer();
    final service = _service(fake);
    await _on(fake, () async {
      await service.getStreamUrl(_sintel);
      expect(service.takeStartSettings(), isNotNull);
      await service.getStreamUrl(_bbb);
    });
    expect(service.takeStartSettings(), isNull, reason: 'the server was up');
  });

  group("a torrent's hash", () {
    test('is read from a magnet, hex or base32', () {
      expect(infoHashOf(_sintel), _sintelHash);
      expect(
        infoHashOf('magnet:?xt=urn:btih:${_sintelHash.toUpperCase()}&dn=S'),
        _sintelHash,
      );
      expect(
        infoHashOf('magnet:?xt=urn:btih:BCW2LJ5GDA5K4HQJ3AY56Z2I2VTASWQQ'),
        _sintelHash,
      );
      expect(infoHashOf('magnet:?dn=Sintel'), isNull);
      expect(infoHashOf('magnet:?xt=urn:btmh:1220abcd'), isNull);
      expect(
        infoHashOf('https://webtorrent.io/torrents/sintel.torrent'),
        isNull,
      );
    });

    test('is known before its add returns', () async {
      final fake = FakeTorrServer()..holdAdd = Completer<void>();
      final service = _service(fake);
      await _on(fake, () async {
        final url = service.getStreamUrl(_sintel);
        await fake.reached('adding');
        // The add waits for the metadata, and the poll asks for this hash.
        expect(await service.getCurrentStatus(), isNull);
        expect(fake.log.last, 'status:$_sintelHash');
        fake.holdAdd!.complete();
        await url;
      });
      final status = await _on(fake, service.getCurrentStatus);
      expect(status!.totalPeers, 80);
    });
  });

  testWidgets('the metadata poll looks before it waits', (tester) async {
    final fake = FakeTorrServer();
    final service = _service(fake);
    var done = false;
    unawaited(
      _on(fake, () => service.getStreamUrl(_sintel)).then((_) => done = true),
    );
    for (var i = 0; i < 20 && !done; i++) {
      await tester.pump();
    }
    expect(done, isTrue, reason: 'the add already waited for the metadata');
  });

  test("the stream URL is the server's /stream address, with no playlist "
      'request', () async {
    final fake = FakeTorrServer();
    final service = _service(fake);
    final url = await _on(fake, () => service.getStreamUrl(_sintel));
    // The first video file: id 1, after the poster's 0.
    expect(url, 'http://127.0.0.1:8090/stream?link=$_sintelHash&index=1&play');
    expect(fake.log, isNot(contains('playlist')));
  });

  test(
    "an open given up on doesn't take over the torrent that plays",
    () async {
      // Source A waits for its metadata (TorrServer gives it up to 5 minutes;
      // iOS's add now waits 300 s) after the screen has failed over to B. A's
      // late answer moved the status poll, the peer line and the Files tab onto
      // A, and a file picked there played A's.
      final fake = FakeTorrServer();
      final service = _service(fake);
      final held = fake.holdAdd = Completer<void>();
      final abandoned = _on(fake, () => service.getStreamUrl(_sintel));
      await fake.reached('adding');
      fake.holdAdd = null;
      expect(await _on(fake, () => service.getStreamUrl(_bbb)), isNotNull);

      held.complete();
      await abandoned;
      await _on(fake, service.getCurrentStatus);
      expect(fake.log.last, 'status:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c');
    },
  );

  test('a server that stopped answering is started again', () async {
    final fake = FakeTorrServer();
    final service = _service(fake);
    await _on(fake, () async {
      await service.getStreamUrl(_sintel);
      fake.echoes = false;
      expect(await service.getStreamUrl(_bbb), isNotNull);
    });
    expect(_count(fake, 'stop'), 1);
    expect(_count(fake, 'start'), 2);
  });

  group('the file a magnet selects', () {
    test('is its so= index', () {
      expect(selectedFileOf('$_sintel&so=2'), 2);
      expect(selectedFileOf('$_sintel&so=0,3-5'), 0);
      expect(selectedFileOf(_sintel), isNull);
    });

    test('plays, so a season pack plays the episode picked', () async {
      final fake = FakeTorrServer();
      final service = _service(fake);
      final url = await _on(fake, () => service.getStreamUrl('$_sintel&so=2'));
      expect(url, endsWith('&index=2&play'));
    });

    test('one the torrent lacks falls back to the first video', () async {
      final fake = FakeTorrServer();
      final service = _service(fake);
      final url = await _on(fake, () => service.getStreamUrl('$_sintel&so=9'));
      expect(url, endsWith('&index=1&play'));
    });
  });
}
