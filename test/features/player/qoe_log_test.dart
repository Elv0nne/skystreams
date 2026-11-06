import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/qoe_log.dart';

void main() {
  late int now;
  late List<String> lines;
  late QoeLog log;

  setUp(() {
    now = 0;
    lines = <String>[];
    QoeLog.writeToAppLog = false;
    log = QoeLog(nowMs: () => now, sink: lines.add);
  });
  tearDown(() => QoeLog.writeToAppLog = false);

  test(
    'events are kept in order, stamped with the time since the screen opened',
    () {
      now = 5;
      log.open(
        sourceIndex: 0,
        kind: 'file',
        url: 'https://cdn.test/a.mp4',
        startAtMs: 0,
        reason: 'first',
      );
      now = 40;
      log.engine();

      expect(log.events.map((e) => e.kind), [
        QoeEventKind.open,
        QoeEventKind.engine,
      ]);
      expect(log.events.map((e) => e.atMs), [5, 40]);
    },
  );

  test('an address is reduced to its host, so no token reaches a log', () {
    log.open(
      sourceIndex: 2,
      kind: 'hls',
      url: 'https://cdn.test/secret/path/master.m3u8?token=abc123&sig=xyz',
      startAtMs: 90000,
      reason: 'retry',
    );

    final json = jsonEncode(log.events.single.toJson());
    expect(json, contains('"host":"cdn.test"'));
    expect(json, isNot(contains('abc123')));
    expect(json, isNot(contains('secret')));
    expect(QoeLog.hostOf('not a url'), '');
  });

  test('the first frame is split into the app part and the engine part', () {
    now = 30;
    log.engine();
    now = 1030;
    log.firstFrame();

    final fields = log.events.last.fields;
    expect(fields['appMs'], 30);
    expect(fields['engineMs'], 1000);
  });

  test('a stall and a seek carry how long they lasted', () {
    now = 100;
    log.stall(5000);
    now = 1600;
    log.stallEnd();
    now = 2000;
    log.seek(fromMs: 6000, toMs: 66000);
    now = 2750;
    log.seekDone();

    expect(log.events[1].fields['ms'], 1500);
    expect(log.events[2].fields, {'fromMs': 6000, 'toMs': 66000});
    expect(log.events[3].fields['ms'], 750);
  });

  test('the first frame says how long the surface held playback back', () {
    now = 10;
    log.engine();
    now = 1010;
    log.firstFrame(surfaceWaitMs: 640);
    expect(log.events.last.fields['surfaceWaitMs'], 640);
  });

  test('a stall carries libVLC\'s prebuffer when the engine reports one', () {
    now = 100;
    log.stall(5000, prebuffer: 0.37);
    now = 900;
    log.stallEnd();
    now = 1000;
    log.stall(7000);

    expect(log.events[0].fields, {'positionMs': 5000, 'prebufferPct': 37});
    expect(log.events[2].fields, {'positionMs': 7000});
  });

  test('the end sums the session: time played, stalls and their total', () {
    now = 10;
    log.engine();
    now = 1010;
    log.firstFrame();
    now = 2000;
    log.stall(1000);
    now = 2500;
    log.stallEnd();
    now = 3000;
    log.stall(2000);
    now = 3200;
    log.stallEnd();
    now = 11010;
    log.end('left');

    expect(log.events.last.fields, {
      'why': 'left',
      'playedMs': 10000,
      'stalls': 2,
      'stalledMs': 700,
    });
  });

  test('a stall still open at the end counts to the end', () {
    now = 0;
    log.firstFrame();
    now = 1000;
    log.stall(1000);
    now = 4000;
    log.end('failed');

    expect(log.events.last.fields['stalls'], 1);
    expect(log.events.last.fields['stalledMs'], 3000);
  });

  test('a reopen that keeps the picture says so, and one that does not says '
      'nothing', () {
    log
      ..open(
        sourceIndex: 0,
        kind: 'hls',
        url: 'https://cdn.test/master.m3u8',
        startAtMs: 61000,
        reason: 'retry',
        keptPicture: true,
      )
      ..reopen(reason: 'retry', positionMs: 61000, keptPicture: true)
      ..open(
        sourceIndex: 1,
        kind: 'file',
        url: 'https://other.test/film.mp4',
        startAtMs: 61000,
        reason: 'failover',
      );

    expect(log.events[0].fields['keptPicture'], isTrue);
    expect(log.events[1].fields['keptPicture'], isTrue);
    expect(log.events[2].fields.containsKey('keptPicture'), isFalse);
  });

  test('a wait carries its label and position, and its end how long it '
      'lasted', () {
    now = 1000;
    log.wait(label: 'reconnecting', positionMs: 42000);
    now = 21500;
    log.waitEnd();
    // A second end with no wait open records nothing.
    log.waitEnd();

    expect(log.events.map((e) => e.kind), [
      QoeEventKind.wait,
      QoeEventKind.waitEnd,
    ]);
    expect(log.events.first.fields, {
      'label': 'reconnecting',
      'positionMs': 42000,
    });
    expect(log.events.last.fields, {'ms': 20500});
  });

  test('a check carries its class, its status or fault, and its time', () {
    log
      ..check(sourceIndex: 0, kind: 'network', fault: 'refused', ms: 2)
      ..check(sourceIndex: 1, kind: 'gone', status: 403, ms: 85);

    expect(log.events.first.fields, {
      'sourceIndex': 0,
      'kind': 'network',
      'fault': 'refused',
      'ms': 2,
    });
    expect(log.events.last.fields, {
      'sourceIndex': 1,
      'kind': 'gone',
      'status': 403,
      'ms': 85,
    });
  });

  test(
    'an error carries the sign that noticed it, and a give-up its cause',
    () {
      log
        ..error('playback error', sign: 'engineError')
        ..error('no native player')
        ..gaveUp(cause: 'sessionCap');

      expect(log.events[0].fields, {
        'detail': 'playback error',
        'sign': 'engineError',
      });
      expect(log.events[1].fields, {'detail': 'no native player'});
      expect(log.events[2].kind, QoeEventKind.gaveUp);
      expect(log.events[2].fields, {'cause': 'sessionCap'});
    },
  );

  test('the end sums the waits, a wait still open counted to the end', () {
    now = 0;
    log.wait(label: 'reconnecting', positionMs: 1000);
    now = 3000;
    log.waitEnd();
    now = 10000;
    log.wait(label: 'waitingForNetwork', positionMs: 1000);
    now = 15000;
    log.end('left');

    expect(log.events.last.fields['waits'], 2);
    expect(log.events.last.fields['waitedMs'], 8000);
  });

  test('only the last 200 events are kept', () {
    for (var i = 0; i < 250; i++) {
      now = i;
      log.memory(i);
    }

    expect(log.events, hasLength(QoeLog.capacity));
    expect(log.events.first.fields['residentMb'], 50);
  });

  test('lines reach the app log only while the developer option is on', () {
    log.engine();
    expect(lines, isEmpty);

    QoeLog.writeToAppLog = true;
    now = 7;
    log.error('the network dropped');

    expect(lines, hasLength(1));
    expect(lines.single, startsWith('QOE {'));
    expect(jsonDecode(lines.single.substring(4)), {
      'event': 'error',
      'atMs': 7,
      'detail': 'the network dropped',
    });
  });

  test('the newest log is the one the device suite reads', () {
    final second = QoeLog(nowMs: () => 0);

    expect(QoeLog.latest, same(second));
  });

  test("a torrent's start: what it did to the settings, or that the server "
      'was up', () {
    log.torrent(<String, Object?>{
      'settings': 'applied',
      'wantMb': 256,
      'wantAhead': 75,
      'hadMb': 64,
      'hadAhead': 95,
      'setMs': 2200,
      'readBackOk': true,
    });
    log.torrent(null);
    final events = log.events.where((e) => e.kind == QoeEventKind.torrent);
    expect(events.map((e) => e.fields['settings']), ['applied', 'serverUp']);
    expect(events.first.fields['setMs'], 2200);
    // No address and no token: the event names neither.
    expect(
      jsonEncode([for (final e in log.events) e.toJson()]),
      isNot(contains('127.0.0.1')),
    );
  });

  test("a failing torrent's error carries its peers and what it loaded", () {
    log.error(
      'first frame',
      sign: 'neverStarted',
      torrent: <String, Object?>{'peers': 0, 'totalPeers': 4, 'loadedMb': 0},
    );
    final error = log.events.singleWhere((e) => e.kind == QoeEventKind.error);
    expect(error.fields['torrent'], <String, Object?>{
      'peers': 0,
      'totalPeers': 4,
      'loadedMb': 0,
    });
  });
}
