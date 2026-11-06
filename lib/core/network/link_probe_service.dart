import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../utils/file_size_formatter.dart';
import 'dio_client_provider.dart';
import 'probe_answer.dart';

part 'link_probe_service.g.dart';

@Riverpod(keepAlive: true)
LinkProbeService linkProbeService(Ref ref) =>
    LinkProbeService(ref.watch(dioClientProvider));

/// One rendition advertised inside an HLS master playlist.
class HlsVariant {
  final int? height;
  final int? bandwidth;
  const HlsVariant({this.height, this.bandwidth});
}

final RegExp _resolutionRe = RegExp(r'RESOLUTION=(\d+)x(\d+)');
final RegExp _bandwidthRe = RegExp(r'(?<![-A-Z])BANDWIDTH=(\d+)');

/// The variants an HLS master playlist lists, in its order: one per
/// `#EXT-X-STREAM-INF` line. An I-frame playlist
/// (`#EXT-X-I-FRAME-STREAM-INF`) is trick play, not something to watch, and
/// a media playlist lists none.
List<HlsVariant> hlsVariantsOf(String playlist) {
  final variants = <HlsVariant>[];
  for (final line in playlist.split('\n')) {
    if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
    final res = _resolutionRe.firstMatch(line);
    final bandwidth = _bandwidthRe.firstMatch(line);
    variants.add(
      HlsVariant(
        height: res == null ? null : int.tryParse(res.group(2)!),
        bandwidth: bandwidth == null ? null : int.tryParse(bandwidth.group(1)!),
      ),
    );
  }
  return variants;
}

/// How a height reads in the source lists and the player's Quality tab:
/// `4K`, `2K`, else `1080p`.
String resolutionLabelFor(int height) {
  if (height >= 2160) return '4K';
  if (height >= 1440) return '2K';
  return '${height}p';
}

/// Outcome of testing whether a link is actually usable.
class LinkProbeResult {
  final bool reachable;
  final int? statusCode;
  final int? contentLength;
  final String? contentType;
  final bool supportsRanges;
  final List<HlsVariant> variants;
  final String? failureReason;

  const LinkProbeResult({
    required this.reachable,
    this.statusCode,
    this.contentLength,
    this.contentType,
    this.supportsRanges = false,
    this.variants = const [],
    this.failureReason,
  });

  String? get sizeLabel {
    final length = contentLength;
    if (length == null || length <= 0) return null;
    return formatFileSize(length, fractionDigits: 1);
  }

  /// Real resolution, read from an HLS master playlist when there is one.
  String? get resolutionLabel {
    final heights = variants
        .map((v) => v.height ?? 0)
        .where((h) => h > 0)
        .toList();
    if (heights.isEmpty) return null;
    heights.sort();
    return resolutionLabelFor(heights.last);
  }
}

/// Verifies a link before the user commits to it: alive/dead, real byte size,
/// and the true resolution for HLS playlists.
class LinkProbeService {
  LinkProbeService(this._dio);

  final Dio _dio;
  final Map<String, LinkProbeResult> _cache = {};
  final Map<String, Future<LinkProbeResult>> _inFlight = {};

  static const Duration _timeout = Duration(seconds: 8);

  Future<LinkProbeResult> probe(
    String url, {
    Map<String, String>? headers,
  }) async {
    final cached = _cache[url];
    if (cached != null) return cached;

    final pending = _inFlight[url];
    if (pending != null) return pending;

    final future = _probe(url, headers);
    _inFlight[url] = future;
    try {
      final result = await future;
      _cache[url] = result;
      return result;
    } finally {
      _inFlight.remove(url)?.ignore();
    }
  }

  Future<LinkProbeResult> _probe(
    String url,
    Map<String, String>? headers,
  ) async {
    if (url.startsWith('magnet:') || url.startsWith('/')) {
      // Torrents can't be HEAD-checked; treat them as usable.
      return const LinkProbeResult(reachable: true, supportsRanges: true);
    }

    try {
      final response = await _dio.head<void>(
        url,
        options: Options(
          headers: headers,
          followRedirects: true,
          receiveTimeout: _timeout,
          sendTimeout: _timeout,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final result = _fromHeaders(response.statusCode, response.headers.map);
      if (result.reachable) {
        // A HEAD has no body to tell a web page by, so a type that leaves
        // room for one is worth the start of the page.
        if (mayBeWebPage(result.contentType)) {
          final (_, head) = await _rangedStart(url, headers);
          if (_isPage(url, result.contentType, head)) return _notVideo(result);
        }
        return await _withHlsVariants(url, headers, result);
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[LinkProbe] HEAD failed: $error');
    }

    // Many CDNs reject HEAD — a ranged GET is cheap and also proves range
    // support.
    try {
      final (response, head) = await _rangedStart(url, headers);
      final result = _fromHeaders(
        response.statusCode,
        response.headers.map,
        rangedGet: true,
      );
      if (!result.reachable) return result;
      if (_isPage(url, result.contentType, head)) return _notVideo(result);
      return await _withHlsVariants(url, headers, result);
    } catch (error) {
      return LinkProbeResult(
        reachable: false,
        failureReason: error is DioException
            ? (error.message ?? error.type.name)
            : error.toString(),
      );
    }
  }

  /// A ranged GET for the start of [url], read only as far as
  /// [kProbeSniffBytes].
  ///
  /// Streamed rather than buffered: a server that ignores the range answers
  /// with the whole file, and read as bytes that was the whole file - 18 GB
  /// on the film this was found on - held in memory.
  Future<(Response<ResponseBody>, List<int>)> _rangedStart(
    String url,
    Map<String, String>? headers,
  ) async {
    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        headers: {...?headers, 'Range': 'bytes=0-${kProbeSniffBytes - 1}'},
        responseType: ResponseType.stream,
        followRedirects: true,
        receiveTimeout: _timeout,
        sendTimeout: _timeout,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    final head = <int>[];
    final body = response.data?.stream;
    if (body != null) {
      // Leaving the loop cancels the subscription, which hangs up the rest.
      await for (final chunk in body) {
        final room = kProbeSniffBytes - head.length;
        head.addAll(chunk.length > room ? chunk.sublist(0, room) : chunk);
        if (head.length >= kProbeSniffBytes) break;
      }
    }
    return (response, head);
  }

  /// Whether the start of [url]'s answer is a web page - and not a playlist
  /// some script serves with a web page's type.
  static bool _isPage(String url, String? contentType, List<int> head) {
    final uri = Uri.tryParse(url);
    if (uri != null && isPlaylist(uri, contentType, head)) return false;
    return isWebPage(contentType, head);
  }

  /// A link that answered with a web page - HubCloud's link generator, a
  /// login, a missing-file page served with a 200 - rather than a video.
  static LinkProbeResult _notVideo(LinkProbeResult answered) => LinkProbeResult(
    reachable: false,
    statusCode: answered.statusCode,
    contentType: answered.contentType,
    failureReason: 'Not a video',
  );

  LinkProbeResult _fromHeaders(
    int? statusCode,
    Map<String, List<String>> headers, {
    bool rangedGet = false,
  }) {
    String? headerValue(String name) {
      final values = headers[name] ?? headers[name.toLowerCase()];
      if (values == null || values.isEmpty) return null;
      return values.first;
    }

    final ok = statusCode != null && statusCode >= 200 && statusCode < 400;
    int? length = int.tryParse(headerValue('content-length') ?? '');
    final contentRange = headerValue('content-range');
    if (rangedGet && contentRange != null) {
      length = int.tryParse(contentRange.split('/').last) ?? length;
    }

    return LinkProbeResult(
      reachable: ok,
      statusCode: statusCode,
      contentLength: length,
      contentType: headerValue('content-type'),
      supportsRanges:
          (headerValue('accept-ranges')?.contains('bytes') ?? false) ||
          statusCode == 206,
      failureReason: ok ? null : 'HTTP $statusCode',
    );
  }

  Future<LinkProbeResult> _withHlsVariants(
    String url,
    Map<String, String>? headers,
    LinkProbeResult base,
  ) async {
    final looksHls =
        url.toLowerCase().contains('.m3u8') ||
        (base.contentType?.toLowerCase().contains('mpegurl') ?? false);
    if (!looksHls) return base;

    try {
      final response = await _dio.get<String>(
        url,
        options: Options(
          headers: headers,
          responseType: ResponseType.plain,
          receiveTimeout: _timeout,
          sendTimeout: _timeout,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final variants = hlsVariantsOf(response.data ?? '');
      if (variants.isEmpty) return base;
      return LinkProbeResult(
        reachable: base.reachable,
        statusCode: base.statusCode,
        contentLength: base.contentLength,
        contentType: base.contentType,
        supportsRanges: base.supportsRanges,
        variants: variants,
      );
    } catch (_) {
      return base;
    }
  }

  void clear() => _cache.clear();
}
