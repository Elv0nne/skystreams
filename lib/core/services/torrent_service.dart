import 'dart:async';
import 'dart:convert';
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_torrent_server/flutter_torrent_server.dart';
import '../utils/torrent_file_parser.dart';
import '../utils/app_utils.dart';
import '../models/torrent_status.dart';

/// What a server start did to TorrServer's buffer settings (spec 5).
enum TorrentSettingsOutcome {
  /// The server held the sizes handed over already: nothing was written.
  unchanged,

  /// Written, and the read-back shows both values.
  applied,

  /// A read, the write or the read-back failed, or the server didn't take
  /// the values: it keeps what it has, and the torrent plays on that.
  failed,

  /// No sizes were handed over: the settings were left alone.
  notAsked,
}

/// One server start's settings work, as the QoE log records it.
@immutable
class TorrentSettings {
  const TorrentSettings(
    this.outcome, {
    this.wantMb,
    this.wantAhead,
    this.hadMb,
    this.hadAhead,
    this.setMs,
    this.readBackOk,
    this.error,
  });

  final TorrentSettingsOutcome outcome;

  /// The cache handed over, in MB, and the share of it held ahead.
  final int? wantMb;
  final int? wantAhead;

  /// What the server held when the start read it.
  final int? hadMb;
  final int? hadAhead;

  /// How long the write took to answer, when there was one.
  final int? setMs;

  /// Whether the read after the write shows both values.
  final bool? readBackOk;

  /// What went wrong, for a failure.
  final String? error;

  Map<String, Object?> toJson() => <String, Object?>{
    'settings': outcome.name,
    'wantMb': ?wantMb,
    'wantAhead': ?wantAhead,
    'hadMb': ?hadMb,
    'hadAhead': ?hadAhead,
    'setMs': ?setMs,
    'readBackOk': ?readBackOk,
    'error': ?error,
  };
}

/// The infohash a magnet names, as the lowercase hex TorrServer's
/// `/torrents` wants: 40 hex characters, or 32 of base32. Null when [link]
/// names none (an `https` `.torrent` has none until it is added).
String? infoHashOf(String link) {
  final match = RegExp(r'[?&]xt=urn:btih:([0-9A-Za-z]+)(?=&|$)')
      .firstMatch(link);
  final id = match?.group(1);
  if (id == null) return null;
  if (id.length == 40 && RegExp(r'^[0-9A-Fa-f]+$').hasMatch(id)) {
    return id.toLowerCase();
  }
  if (id.length != 32) return null;
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final hex = StringBuffer();
  var bits = 0;
  var value = 0;
  for (final char in id.toUpperCase().split('')) {
    final digit = alphabet.indexOf(char);
    if (digit < 0) return null;
    value = (value << 5) | digit;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      hex.write(((value >> bits) & 0xff).toRadixString(16).padLeft(2, '0'));
      value &= (1 << bits) - 1;
    }
  }
  return hex.toString();
}

/// The file a magnet selects with BEP 53's `so=` (select only): its first
/// index. Stremio's `fileIdx` rides here, so a season pack plays the episode
/// that was picked. Null when the link selects none.
int? selectedFileOf(String link) {
  final match = RegExp(r'[?&]so=(\d+)').firstMatch(link);
  return match == null ? null : int.tryParse(match.group(1)!);
}

const int _mib = 1 << 20;

/// TorrServer answers a read at once; three seconds is the probe's figure.
const Duration _readTimeout = Duration(seconds: 3);

/// A write answers only once TorrServer has dropped every torrent and built
/// its client again: two one-second sleeps and a public-IP lookup with no
/// deadline of its own (`torr/apihelper.go`).
const Duration _writeTimeout = Duration(seconds: 20);

/// A server that doesn't answer its `/echo` in this long is taken for dead.
const Duration _echoTimeout = Duration(seconds: 1);

class TorrentService {
  static final TorrentService _instance = TorrentService._internal();
  factory TorrentService() => _instance;
  TorrentService._internal() : _server = FlutterTorrentServer();

  /// A service over [server], for tests; its HTTP goes through the zone's
  /// client (`http.runWithClient`).
  @visibleForTesting
  TorrentService.forTesting(this._server);

  final FlutterTorrentServer _server;
  String? _serverUrl;
  bool _isStarted = false;
  String? _activeTorrentHash;

  /// The sizes the next start writes; see [bufferForNextStart].
  ({int cacheMb, int readAheadPercent})? _nextBuffer;

  /// The start under way, which every caller waits on.
  Future<void>? _starting;

  /// Moved on by every [stop]: a start that ends after one commits nothing.
  int _life = 0;

  /// Counts the opens, so only the newest names the torrent that plays: one
  /// given up on can still be waiting for its metadata minutes later.
  int _opens = 0;

  /// What the last start did to the settings, until an open takes it.
  TorrentSettings? _startSettings;

  /// Hands over the cache, in MB, and the share of it held ahead of the read
  /// point, for the next start to write (spec 5).
  ///
  /// Never posts. TorrServer's write drops every torrent it holds and takes
  /// over two seconds, so it happens only before the first torrent of a
  /// server's life is added: in [start].
  void bufferForNextStart({
    required int cacheMb,
    required int readAheadPercent,
  }) => _nextBuffer = (cacheMb: cacheMb, readAheadPercent: readAheadPercent);

  /// What the last start did to the server's settings, once: the first open
  /// after a start takes it, and a later open in the same server's life gets
  /// null - the server was already up.
  TorrentSettings? takeStartSettings() {
    final settings = _startSettings;
    _startSettings = null;
    return settings;
  }

  Future<TorrentStatus?> getCurrentStatus() async {
    if (_activeTorrentHash == null || !_isStarted) {
      return null;
    }
    try {
      final statusMap = await _server.getTorrentStatus(_activeTorrentHash!);
      if (statusMap != null) {
        return TorrentStatus.fromMap(statusMap);
      }
    } catch (e) {
      if (kDebugMode) debugPrint("Error fetching status: $e");
    }
    return null;
  }

  /// Starts the server, once for every caller, and lets torrents in only
  /// once the sizes handed over are written (spec 5): every add in a
  /// server's life comes after its one write.
  Future<void> start() {
    if (_isStarted) return Future<void>.value();
    final running = _starting;
    if (running != null) return running;
    late final Future<void> starting;
    starting = _start().whenComplete(() {
      if (identical(_starting, starting)) _starting = null;
    });
    return _starting = starting;
  }

  Future<void> _start() async {
    final life = _life;
    try {
      final port = await _server.start();
      if (life != _life || port <= 0) return;
      final url = "http://127.0.0.1:$port";
      final settings = await _syncSettings(url);
      if (life != _life) return;
      _serverUrl = url;
      _startSettings = settings;
      _isStarted = true;
      if (kDebugMode) debugPrint("Torrent Server started at $_serverUrl");
    } catch (e) {
      if (kDebugMode) debugPrint("Failed to start torrent server: $e");
    }
  }

  /// Writes the sizes handed over to the server at [url] when they differ
  /// from what it holds: read the settings, put the two values into what was
  /// read, write the whole of it back - TorrServer's set replaces every field
  /// and zeroes what it isn't sent - and read again. Never throws.
  Future<TorrentSettings> _syncSettings(String url) async {
    final want = _nextBuffer;
    if (want == null) {
      return const TorrentSettings(TorrentSettingsOutcome.notAsked);
    }
    TorrentSettings failed(String error) => TorrentSettings(
      TorrentSettingsOutcome.failed,
      wantMb: want.cacheMb,
      wantAhead: want.readAheadPercent,
      error: error,
    );
    final token = _server.authToken;
    if (token == null) return failed('no token');
    final current = await _readSettings(url, token);
    if (current == null) return failed('read');
    final hadBytes = current['CacheSize'];
    final hadAhead = current['ReaderReadAHead'];
    // A body that isn't TorrServer's is never written over: a set built from
    // it would zero every field it lacks.
    if (hadBytes is! int || hadAhead is! int) return failed('unknown answer');
    final wantBytes = want.cacheMb * _mib;
    final hadMb = hadBytes ~/ _mib;
    if (hadBytes == wantBytes && hadAhead == want.readAheadPercent) {
      return TorrentSettings(
        TorrentSettingsOutcome.unchanged,
        wantMb: want.cacheMb,
        wantAhead: want.readAheadPercent,
        hadMb: hadMb,
        hadAhead: hadAhead,
      );
    }
    final watch = clock.stopwatch()..start();
    String? error;
    try {
      final response = await http
          .post(
            Uri.parse("$url/settings"),
            headers: _headers(token),
            body: jsonEncode(<String, Object?>{
              'action': 'set',
              'sets': <String, Object?>{
                ...current,
                'CacheSize': wantBytes,
                'ReaderReadAHead': want.readAheadPercent,
              },
            }),
          )
          .timeout(_writeTimeout);
      if (response.statusCode != 200) error = 'set ${response.statusCode}';
    } catch (e) {
      error = 'set ${e.runtimeType}';
    }
    final setMs = watch.elapsedMilliseconds;
    // What the server holds now, whatever the write answered.
    final after = await _readSettings(url, token);
    final readBackOk =
        after != null &&
        after['CacheSize'] == wantBytes &&
        after['ReaderReadAHead'] == want.readAheadPercent;
    return TorrentSettings(
      readBackOk
          ? TorrentSettingsOutcome.applied
          : TorrentSettingsOutcome.failed,
      wantMb: want.cacheMb,
      wantAhead: want.readAheadPercent,
      hadMb: hadMb,
      hadAhead: hadAhead,
      setMs: setMs,
      readBackOk: readBackOk,
      error: error ?? (readBackOk ? null : 'not taken'),
    );
  }

  /// The server's settings, TorrServer's whole struct; null on any failure.
  Future<Map<String, Object?>?> _readSettings(String url, String token) async {
    try {
      final response = await http
          .post(
            Uri.parse("$url/settings"),
            headers: _headers(token),
            body: jsonEncode(const <String, Object?>{'action': 'get'}),
          )
          .timeout(_readTimeout);
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body);
      return body is Map<String, Object?> ? body : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, String> _headers(String token) => <String, String>{
    'Content-Type': 'application/json',
    FlutterTorrentServer.authTokenHeader: token,
  };

  Future<void> stop() async {
    // First, so a start still under way finds it has outlived its server.
    _life += 1;
    _starting = null;
    _isStarted = false;
    _serverUrl = null;
    _activeTorrentHash = null;
    _startSettings = null;
    try {
      await _server.stop();
    } catch (e) {
      if (kDebugMode) debugPrint("Error stopping torrent server: $e");
    }
  }

  Future<String?> getStreamUrl(String magnetLink) async {
    // A desktop server can die under a running app, and the flag alone would
    // send every later torrent to a dead port.
    final life = _life;
    if (_isStarted && !await _answers(_serverUrl) && life == _life) {
      await stop();
    }
    await start();
    // An open given up on still finishes its add, but no longer names the
    // torrent the status poll and the Files tab follow.
    final open = ++_opens;
    final opened = _life;
    bool newest() => open == _opens && opened == _life;
    final serverUrl = _serverUrl;
    if (serverUrl == null) {
      return null;
    }

    try {
      final String linkToAdd = await _prepareMagnetLink(magnetLink);
      // Known before the add returns, which waits for the torrent's
      // metadata, so the status poll can show its peers through that wait.
      if (newest()) _activeTorrentHash = infoHashOf(linkToAdd);

      // Add Torrent
      final hash = await _server.addTorrent(linkToAdd);
      if (hash == null) {
        throw Exception("Failed to add torrent");
      }
      if (newest()) _activeTorrentHash = hash;

      // Poll for Status to get Filename and File Index
      final fileInfo = await _pollForMetadata(
        hash,
        selected: selectedFileOf(magnetLink),
      );
      if (fileInfo == null) {
        throw Exception("Timed out waiting for torrent metadata");
      }

      final int fileIndex = fileInfo['index'] as int;

      return "$serverUrl/stream?link=$hash&index=$fileIndex&play";
    } catch (e) {
      if (kDebugMode) debugPrint("Error generating stream URL: $e");
      return null;
    }
  }

  /// Whether the server at [url] answers its `/echo`.
  Future<bool> _answers(String? url) async {
    if (url == null) return false;
    try {
      final response = await http
          .get(Uri.parse("$url/echo"))
          .timeout(_echoTimeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<String> _prepareMagnetLink(String link) async {
    if (!link.startsWith("magnet:") &&
        !link.startsWith("http") &&
        (AppUtils.isLocalFile(link) || link.contains(RegExp(r'\.torrent$')))) {
      try {
        return await TorrentFileParser.getMagnetLink(link);
      } catch (e) {
        throw Exception("Failed to parse torrent file: $e");
      }
    }
    return link;
  }

  Future<Map<String, dynamic>?> _pollForMetadata(
    String hash, {
    int? selected,
  }) async {
    int attempts = 0;
    while (attempts < 120) {
      // The add itself waited for the metadata, so the first look is at once.
      if (attempts > 0) await Future<void>.delayed(const Duration(seconds: 1));
      final status = await _server.getTorrentStatus(hash);

      if (status != null && status['file_stats'] is List) {
        final fileStats = status['file_stats'] as List;
        if (fileStats.isNotEmpty) {
          return _findSequentialVideoFile(fileStats, selected: selected);
        }
      }
      attempts++;
    }
    return null;
  }

  Map<String, dynamic> _findSequentialVideoFile(
    List<dynamic> fileStats, {
    int? selected,
  }) {
    // The file the link selected, when the torrent has it. TorrServer's ids
    // are 0-based and omitempty: file 0 comes without one.
    if (selected != null) {
      for (final f in fileStats) {
        if (f is Map &&
            ((f['id'] as num?)?.toInt() ?? 0) == selected &&
            (f['path']?.toString() ?? '').isNotEmpty) {
          return {'index': selected, 'path': f['path']};
        }
      }
    }
    final videoExtensions = ['.mp4', '.mkv', '.avi', '.mov', '.webm'];
    final videoFiles = <Map<dynamic, dynamic>>[];

    for (final f in fileStats) {
      if (f is Map) {
        final path = f['path']?.toString() ?? "";
        if (path.isNotEmpty) {
          final lowerPath = path.toLowerCase();
          if (videoExtensions.any((ext) => lowerPath.endsWith(ext))) {
            videoFiles.add(f);
          }
        }
      }
    }

    if (videoFiles.isNotEmpty) {
      // Sort alphabetically to find the "first" file in sequence (e.g. S01E01)
      videoFiles.sort(
        (a, b) => (a['path'] as String).compareTo(b['path'] as String),
      );

      final selectedFile = videoFiles.first;
      int fileIndex = 0;
      if (selectedFile['id'] != null) {
        fileIndex = (selectedFile['id'] as num).toInt();
      }
      if (kDebugMode) {
        debugPrint(
          "Auto-selected first video file: ${selectedFile['path']} (Index: $fileIndex)",
        );
      }
      return {'index': fileIndex, 'path': selectedFile['path']};
    }

    // Fallback to largest file if no video extension matches (e.g. strict naming)
    return _findLargestFile(fileStats);
  }

  Map<String, dynamic> _findLargestFile(List<dynamic> fileStats) {
    Map<dynamic, dynamic>? largestFile;
    int maxLen = -1;
    int largestIndex = 0;

    for (int i = 0; i < fileStats.length; i++) {
      final f = fileStats[i];
      if (f is Map) {
        final path = f['path']?.toString() ?? "";
        if (path.isNotEmpty) {
          final len = (f['length'] as num?)?.toInt() ?? 0;
          if (len > maxLen) {
            maxLen = len;
            largestFile = f;
            largestIndex = i;
          }
        }
      }
    }

    if (largestFile != null) {
      int fileIndex = largestIndex;
      if (largestFile['id'] != null) {
        fileIndex = (largestFile['id'] as num).toInt();
      }
      if (kDebugMode) {
        debugPrint(
          "Fallback to largest file: ${largestFile['path']} (Index: $fileIndex)",
        );
      }
      return {'index': fileIndex, 'path': largestFile['path']};
    }

    return {'index': 0, 'path': 'Unknown'};
  }

  Future<String?> getStreamUrlForFileIndex(int index) async {
    if (_serverUrl == null || _activeTorrentHash == null) {
      return null;
    }

    // Use "Simplified" format for maximum compatibility
    final streamUrl =
        "$_serverUrl/stream?link=$_activeTorrentHash&index=$index&play";
    if (kDebugMode) {
      debugPrint("Generated Stream URL for Index $index: $streamUrl");
    }
    return streamUrl;
  }
}
