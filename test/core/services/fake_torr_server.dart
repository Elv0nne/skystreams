import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_torrent_server/flutter_torrent_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skystream/core/services/torrent_service.dart';

/// A TorrServer for the torrent service's tests: the plugin's calls on one
/// side, the server's HTTP API on the other ([client]), over one state.
///
/// Its `/settings` does what TorrServer's does (`web/api/settings.go`,
/// `settings/btsets.go`): the token or 401, a known action or 400; `get`
/// answers the whole struct; `set` replaces it, zeroing every field it wasn't
/// sent and applying the four failsafes, then drops every torrent.
class FakeTorrServer implements FlutterTorrentServer {
  FakeTorrServer({Map<String, Object?> settings = const {}, this.acceptToken})
    : settings = <String, Object?>{...defaultSettings, ...settings};

  /// TorrServer's defaults, as a `get` on a fresh database answers them.
  static const Map<String, Object?> defaultSettings = <String, Object?>{
    'CacheSize': 67108864,
    'ReaderReadAHead': 95,
    'PreloadCache': 50,
    'UseDisk': false,
    'TorrentsSavePath': '',
    'RemoveCacheOnDrop': false,
    'ForceEncrypt': false,
    'RetrackersMode': 1,
    'TorrentDisconnectTimeout': 30,
    'EnableDebug': false,
    'EnableDLNA': false,
    'FriendlyName': '',
    'EnableIPv6': false,
    'DisableTCP': false,
    'DisableUTP': false,
    'DisableUPNP': false,
    'DisableDHT': false,
    'DisablePEX': false,
    'DisableUpload': false,
    'DownloadRateLimit': 0,
    'UploadRateLimit': 0,
    'ConnectionsLimit': 25,
    'PeersListenPort': 0,
  };

  /// What a `get` answers now.
  final Map<String, Object?> settings;

  /// The token the server takes, when it isn't the one it handed out.
  final String? acceptToken;

  /// Every call and request, in order: `start`, `stop`, `echo`, `get`, `set`,
  /// `adding`, `add:<hash>`, `status:<hash>`, `playlist`.
  final List<String> log = <String>[];

  /// Every `/settings` request, for its headers.
  final List<http.Request> settingsRequests = <http.Request>[];

  /// The `sets` of the last `set`.
  Map<String, Object?>? lastSet;

  /// The torrents loaded now.
  final Set<String> loaded = <String>{};

  /// When set, each add, or each set, waits for it.
  Completer<void>? holdAdd;
  Completer<void>? holdSet;

  /// When set, every set answers this status and applies nothing.
  int? setStatus;

  /// Every set answers 200 and applies nothing.
  bool ignoreSet = false;

  /// Whether `/echo` answers.
  bool echoes = true;

  String? _token;

  @override
  String? get authToken => _token;

  @override
  Future<int> start() async {
    log.add('start');
    _token = 'token-${log.length}';
    return 8090;
  }

  @override
  Future<void> stop() async {
    log.add('stop');
    _token = null;
  }

  @override
  Future<String?> addTorrent(String link) async {
    log.add('adding');
    await holdAdd?.future;
    final hash = infoHashOf(link) ?? 'f' * 40;
    loaded.add(hash);
    log.add('add:$hash');
    return hash;
  }

  @override
  Future<Map<String, dynamic>?> getTorrentStatus(String hash) async {
    log.add('status:$hash');
    // Desktop's client throws on the 404 an unloaded torrent gets.
    if (!loaded.contains(hash)) throw Exception('404');
    return <String, dynamic>{
      'hash': hash,
      'active_peers': 12,
      'total_peers': 80,
      'file_stats': <dynamic>[
        // File 0 has no id: TorrServer's ids are 0-based and omitempty.
        <String, dynamic>{'path': 'Film/poster.jpg', 'length': 10},
        <String, dynamic>{'id': 1, 'path': 'Film/Film.mp4', 'length': 1000},
        <String, dynamic>{'id': 2, 'path': 'Film/Trailer.mkv', 'length': 900},
      ],
    };
  }

  /// Waits until [entry] is in [log].
  Future<void> reached(String entry) async {
    for (var i = 0; i < 1000 && !log.contains(entry); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    if (!log.contains(entry)) fail('never reached $entry: $log');
  }

  /// The server's HTTP API.
  http.Client get client => MockClient((request) async {
    switch (request.url.path) {
      case '/echo':
        log.add('echo');
        if (!echoes) throw http.ClientException('Connection refused');
        return http.Response('Kuukiyomi torrserver', 200);
      case '/playlist':
        log.add('playlist');
        return http.Response('hash is empty', 400);
      case '/settings':
        settingsRequests.add(request);
        final token = acceptToken ?? _token;
        if (token == null ||
            request.headers[FlutterTorrentServer.authTokenHeader] != token) {
          return http.Response('', 401);
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        switch (body['action']) {
          case 'get':
            log.add('get');
            return http.Response(jsonEncode(settings), 200);
          case 'set':
            log.add('set');
            lastSet = Map<String, Object?>.of(
              body['sets'] as Map<String, dynamic>,
            );
            await holdSet?.future;
            if (setStatus case final status?) return http.Response('', status);
            if (!ignoreSet) _apply(lastSet!);
            loaded.clear();
            return http.Response('', 200);
        }
        return http.Response('action is empty', 400);
    }
    return http.Response('', 404);
  });

  /// `SetBTSets`: the struct replaced, a field it wasn't sent zeroed, then
  /// the failsafes. encoding/json matches keys case-insensitively and drops
  /// what matches no field.
  void _apply(Map<String, Object?> sets) {
    Object? zero(Object? value) => switch (value) {
      int() => 0,
      bool() => false,
      String() => '',
      _ => null,
    };
    final next = <String, Object?>{
      for (final entry in defaultSettings.entries) entry.key: zero(entry.value),
    };
    for (final entry in sets.entries) {
      for (final key in defaultSettings.keys) {
        if (key.toLowerCase() == entry.key.toLowerCase()) {
          next[key] = entry.value;
        }
      }
    }
    if (next['CacheSize'] == 0) next['CacheSize'] = 64 << 20;
    if (next['ConnectionsLimit'] == 0) next['ConnectionsLimit'] = 25;
    if (next['TorrentDisconnectTimeout'] == 0) {
      next['TorrentDisconnectTimeout'] = 30;
    }
    next['ReaderReadAHead'] = (next['ReaderReadAHead']! as int).clamp(5, 100);
    settings
      ..clear()
      ..addAll(next);
  }
}
