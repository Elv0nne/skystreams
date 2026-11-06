import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_torrent_server/flutter_torrent_server_desktop.dart';
import 'package:flutter_torrent_server/flutter_torrent_server_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The embedded server answers 401 on /torrents unless the request carries the
/// per-launch token. This fake reproduces that exactly, so a client that
/// forgets the header fails here the same way it would fail on a real device.
class _FakeTorrServer {
  _FakeTorrServer(this.token);

  final String token;
  final List<http.BaseRequest> requests = [];

  http.Client get client => MockClient((request) async {
    requests.add(request);
    final presented =
        request.headers[FlutterTorrentServerPlatform.authTokenHeader] ??
        request.url.queryParameters[FlutterTorrentServerPlatform
            .authTokenQueryParam];
    if (presented != token) {
      return http.Response('', 401);
    }
    return http.Response(
      jsonEncode({'hash': 'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c'}),
      200,
    );
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final token = 'a' * 64;

  late FlutterTorrentServerDesktop desktop;
  late _FakeTorrServer server;

  setUp(() {
    desktop = FlutterTorrentServerDesktop();
    server = _FakeTorrServer(token);
    desktop.httpClient = server.client;
    desktop.debugSetAuthToken(token);
  });

  test('addTorrent presents the per-launch token', () async {
    final hash = await desktop.addTorrent('magnet:?xt=urn:btih:abc');

    expect(hash, 'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c');
    expect(server.requests, hasLength(1));
    expect(
      server.requests.single.headers[FlutterTorrentServerPlatform
          .authTokenHeader],
      token,
      reason:
          'addTorrent must send the per-launch token or the server answers 401',
    );
  });

  test('getTorrentStatus presents the per-launch token', () async {
    final status = await desktop.getTorrentStatus(
      'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c',
    );

    expect(status['hash'], 'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c');
    expect(
      server.requests.single.headers[FlutterTorrentServerPlatform
          .authTokenHeader],
      token,
      reason:
          'getTorrentStatus must send the per-launch token or the server '
          'answers 401',
    );
  });

  test('a client holding the wrong token is rejected, not served', () async {
    desktop.debugSetAuthToken('b' * 64);

    await expectLater(
      desktop.addTorrent('magnet:?xt=urn:btih:abc'),
      throwsA(isA<Exception>()),
    );
  });

  test('authToken is null until a server has been started', () {
    final fresh = FlutterTorrentServerDesktop();
    expect(fresh.authToken, isNull);
  });

  test('stop() forgets the token', () async {
    expect(desktop.authToken, token);
    await desktop.stop();
    expect(desktop.authToken, isNull);
  });

  // Dart collects any child of the app while it waits on one of its own, and
  // libVLC waits forever for a helper it starts before each connection
  // (libproxy's `proxy`) when something else collected it: the Linux player
  // froze (2026-10-03). The server must not be the app's child, and its output
  // and kill() must still work.
  test('on Linux, the server is not the app\'s child', () async {
    final server = await FlutterTorrentServerDesktop.startServerProcess(
      '/bin/sh',
      ['-c', r'echo $$; exec sleep 30'],
    );
    addTearDown(server.kill);
    final serverId = int.parse(
      (await server.stdout.transform(utf8.decoder).first).trim(),
    );
    final parent =
        (Process.runSync('ps', ['-o', 'ppid=', '-p', '$serverId']).stdout
                as String)
            .trim();
    expect(int.parse(parent), isNot(pid));
    expect(server.kill(), isTrue);
  }, skip: !Platform.isLinux);
}
