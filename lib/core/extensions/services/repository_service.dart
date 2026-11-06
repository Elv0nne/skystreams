import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'; // kDebugMode, visibleForTesting
import 'dart:io';
import 'dart:convert';
import '../models/extension_repository.dart';
import '../models/extension_plugin.dart';
import '../../storage/app_temp_directory.dart';

/// Where a repository's manifest is read from, and the short link the code
/// it was entered as was found at, when it was entered as a code.
typedef _Found = ({String url, String? shortLink});

class RepositoryService {
  final Dio _dio;
  final bool enableGithubProxy;

  RepositoryService(this._dio, {this.enableGithubProxy = false});

  /// Resolves the actual URL from shortcodes, bare hosts or custom schemes.
  ///
  /// Previously this accepted exactly two shapes — a full `https://…` URL, or
  /// a bare alphanumeric code looked up as `cutt.ly/sky-CODE`. Anything else
  /// (`raw.githubusercontent.com/…`, `github.com/user/repo`, a `cutt.ly/xyz`
  /// link that already carries the prefix) was rejected as "Invalid URL
  /// format", and a shortener answering 200 with a meta-refresh instead of a
  /// 302 resolved to nothing.
  ///
  /// A short link is followed one hop (see [_address]).
  Future<String?> parseRepoUrl(String url) async => (await _resolve(url)).url;

  /// [parseRepoUrl], with the short link a code was found at.
  Future<_Found> _resolve(String input) async {
    final fixedUrl = input.trim();
    if (fixedUrl.isEmpty) throw Exception('Enter a repository URL or code');

    // Standard HTTP/HTTPS.
    if (RegExp(r'^https?://').hasMatch(fixedUrl)) {
      return _address(fixedUrl);
    }

    // Custom scheme used by share links: skystream://host/path.
    final scheme = RegExp(
      r'^[a-zA-Z][a-zA-Z0-9+.-]*://(.+)$',
    ).firstMatch(fixedUrl);
    if (scheme != null) {
      return _address('https://${scheme.group(1)}');
    }

    // Anything that looks like a host or a path is a URL missing its scheme.
    if (fixedUrl.contains('/') ||
        RegExp(r'^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+').hasMatch(fixedUrl)) {
      return _address('https://$fixedUrl');
    }

    // Shortcode: the SkyStream namespace first, then the bare code - each as
    // typed, then in lower case. Codes are case-sensitive, and a television
    // keyboard or a phone's may capitalise the first letter; SkyStream's own
    // code in lower case still comes before a bare one, which is anyone's
    // (cutt.ly/Universe is a stranger's form).
    if (RegExp(r'^[a-zA-Z0-9!_-]+$').hasMatch(fixedUrl)) {
      final lower = fixedUrl.toLowerCase();
      return _findShortcode(
        <String>{
          'https://cutt.ly/sky-$fixedUrl',
          'https://cutt.ly/sky-$lower',
          'https://cutt.ly/$fixedUrl',
          'https://cutt.ly/$lower',
        }.toList(),
      );
    }

    throw Exception('Invalid URL format');
  }

  /// The shorteners repositories' codes are looked up at.
  static const Set<String> _shorteners = {'cutt.ly', 'py.md'};

  /// [url], as the address a repository is read from. A short link - one a
  /// repository added by its code is kept as, or one pasted - is followed
  /// one hop, the way a code is: the shortener may answer with a page rather
  /// than a redirect, and where it points goes through the same checks.
  Future<_Found> _address(String url) async {
    final link = Uri.tryParse(url);
    if (link == null || !_shorteners.contains(link.host)) {
      return (url: url, shortLink: null);
    }
    final target = await resolveShortcode([
      link.replace(scheme: 'https').toString(),
    ]);
    return (url: target, shortLink: null);
  }

  /// Looks a shortcode up at each of [shortLinks] in turn, and returns where
  /// the first that exists points. Throws when none does, or when the
  /// shortener could not be reached. CloudStream's codes go through here too,
  /// at their own shorteners.
  Future<String> resolveShortcode(List<String> shortLinks) async =>
      (await _findShortcode(shortLinks)).url;

  /// [resolveShortcode], with the short link that answered.
  Future<_Found> _findShortcode(List<String> shortLinks) async {
    Object? lastError;
    for (final candidate in shortLinks) {
      try {
        final resolved = await resolveShortLink(candidate);
        if (resolved != null) return (url: resolved, shortLink: candidate);
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError is DioException) {
      throw Exception(
        'Could not reach the shortcode service: ${lastError.message}',
      );
    }
    throw Exception("That shortcode doesn't exist");
  }

  /// Follows one short link. Handles a redirect header, and the increasingly
  /// common "200 + meta refresh / window.location" pages.
  @visibleForTesting
  Future<String?> resolveShortLink(String shortUrl) async {
    final response = await _dio.get<dynamic>(
      shortUrl,
      options: Options(
        followRedirects: false,
        responseType: ResponseType.plain,
        validateStatus: (status) => status != null && status < 500,
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        },
      ),
    );

    final status = response.statusCode ?? 0;
    if (status >= 300 && status < 400) {
      final location = response.headers.value('location');
      return location == null ? null : _followable(shortUrl, location);
    }
    if (status == 404 || status == 410) return null;
    if (status >= 400) {
      // Turned away - cutt.ly answers 429 after a burst of lookups - which is
      // not the same as "no such code".
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        message: status == 429
            ? 'too many lookups, try again in a minute'
            : 'it answered $status',
      );
    }

    final body = response.data is String ? response.data as String : '';
    if (body.isEmpty) return null;

    final meta = RegExp(
      r'<meta[^>]+http-equiv=["]?refresh["]?[^>]+content=["][^"]*url=([^">\s]+)',
      caseSensitive: false,
    ).firstMatch(body);
    if (meta != null) {
      final target = _followable(shortUrl, unescapeHtml(meta.group(1)!));
      if (target != null) return target;
    }

    final js = RegExp(
      r'(?:window\.)?location(?:\.href)?\s*=\s*["]([^"]+)["]',
      caseSensitive: false,
    ).firstMatch(body);
    if (js != null) {
      final target = _followable(shortUrl, unescapeHtml(js.group(1)!));
      if (target != null) return target;
    }

    final jsSingle = RegExp(
      r"(?:window\.)?location(?:\.href)?\s*=\s*'([^']+)'",
      caseSensitive: false,
    ).firstMatch(body);
    if (jsSingle != null) {
      final target = _followable(shortUrl, unescapeHtml(jsSingle.group(1)!));
      if (target != null) return target;
    }
    return null;
  }

  /// Where [target], found in [shortUrl]'s answer, leads: read against
  /// [shortUrl] - a shortener may answer with a relative path - and taken over
  /// https, since a repository's address decides which code the app installs
  /// and runs. Null for a dead end, for anything that is not a web address,
  /// and for the short link's own page again - an empty target, or one that
  /// only changes the query or the fragment - which is not where a code
  /// leads, so the next spelling of it is tried.
  String? _followable(String shortUrl, String target) {
    final trimmed = target.trim();
    if (trimmed.isEmpty) return null;
    final Uri link;
    final Uri resolved;
    try {
      link = Uri.parse(shortUrl);
      resolved = link.resolve(trimmed);
    } on FormatException {
      return null;
    }
    if (resolved.scheme != 'https' && resolved.scheme != 'http') return null;
    // `http:foo` has a scheme and nothing else.
    if (resolved.host.isEmpty) return null;
    if (resolved.host == link.host && resolved.path == link.path) return null;
    final address = resolved.replace(scheme: 'https').toString();
    return isDeadEnd(address) ? null : address;
  }

  @visibleForTesting
  bool isDeadEnd(String location) {
    final trimmed = location.replaceAll(RegExp(r'/$'), '').trim();
    return trimmed.startsWith('https://cutt.ly/404') ||
        trimmed == 'https://cutt.ly' ||
        trimmed.startsWith('https://py.md/404') ||
        trimmed == 'https://py.md' ||
        trimmed.isEmpty;
  }

  @visibleForTesting
  String unescapeHtml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .trim();

  /// Fetch and parse a Repository from a URL. One entered as a code carries
  /// the short link the code was found at ([ExtensionRepository.shortLink]).
  Future<ExtensionRepository?> fetchRepository(String url) async {
    try {
      // Resolve Shortcodes / Protocols
      final resolved = await _resolve(url);

      // Handle raw github urls -> jsdelivr if needed
      final normalizedUrl = _normalizeUrl(resolved.url);

      final response = await _dio.request<String>(normalizedUrl);
      if (response.statusCode == 200 && response.data != null) {
        final Map<String, dynamic>? data = response.data is String
            ? _jsonDecodeSafe(response.data!) as Map<String, dynamic>?
            : response.data as Map<String, dynamic>;

        if (data != null) {
          // Validation: A valid repository must have a name, an ID, and either pluginLists or repos
          final hasName = data.containsKey('name');
          final hasId =
              data.containsKey('id') || data.containsKey('packageName');
          // Extract lists safely to check content
          final plugins = (data['pluginLists'] as List?) ?? <dynamic>[];
          final repos = (data['repos'] as List?) ?? <dynamic>[];

          final hasPlugins = plugins.isNotEmpty;
          final hasRepos = repos.isNotEmpty;

          if (!hasName || !hasId || (!hasPlugins && !hasRepos)) {
            throw Exception(
              'Invalid repository format: Missing name, id/packageName, or plugin/repos',
            );
          }

          if (hasPlugins && hasRepos) {
            throw Exception(
              "Repository cannot contain both 'pluginLists' and 'repos'. Please separate them.",
            );
          }

          return ExtensionRepository.fromJson(
            data,
            url,
            shortLink: resolved.shortLink,
          );
        }
      }
    } on DioException catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to fetch repository $url: $e');
      }
    } catch (e) {
      // Rethrow validation exceptions or others
      rethrow;
    }
    return null;
  }

  /// Fetch all plugin listed in a Repository
  Future<List<ExtensionPlugin>> getRepoPlugins(ExtensionRepository repo) async {
    final List<ExtensionPlugin> allPlugins = <ExtensionPlugin>[];

    for (final pluginListUrl in repo.pluginLists) {
      try {
        final normalizedUrl = _normalizeUrl(pluginListUrl);
        final response = await _dio.get<dynamic>(normalizedUrl);

        if (response.statusCode == 200 && response.data != null) {
          final List<dynamic>? list = response.data is String
              ? _jsonDecodeSafe(response.data as String) as List<dynamic>?
              : response.data as List<dynamic>?;

          if (list != null) {
            final plugins = list
                .map(
                  (e) => ExtensionPlugin.fromJson(
                    e as Map<String, dynamic>,
                    repo.packageName,
                  ),
                )
                .toList();
            allPlugins.addAll(plugins);
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Failed to fetch plugin list $pluginListUrl: $e');
        }
      }
    }

    // Each carries where it was listed: an install keeps it, and only this
    // repository's listing may update it later.
    return [
      for (final plugin in allPlugins) plugin.copyWith(repositoryUrl: repo.url),
    ];
  }

  /// Download a plugin file to a temporary location
  Future<File?> downloadPlugin(String url) async {
    try {
      final normalizedUrl = _normalizeUrl(url);
      final tempDir = await appTempDirectory();
      final tempFile = File(
        '${tempDir.path}/temp_${DateTime.now().millisecondsSinceEpoch}.sky',
      );

      await _dio.download(normalizedUrl, tempFile.path);

      if (await tempFile.exists()) {
        return tempFile;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to download plugin $url: $e');
      }
    }
    return null;
  }

  String _normalizeUrl(String url) {
    if (!enableGithubProxy) return url;

    // Convert raw.githubusercontent.com to jsdelivr for caching/performance
    if (url.contains('raw.githubusercontent.com')) {
      final regex = RegExp(
        r'^https://raw\.githubusercontent\.com/([A-Za-z0-9-]+)/([A-Za-z0-9_.-]+)/(.*)$',
      );
      final match = regex.firstMatch(url);
      if (match != null) {
        final user = match.group(1);
        final repo = match.group(2);
        final path = match.group(3);
        return 'https://cdn.jsdelivr.net/gh/$user/$repo@$path';
      }
    }
    return url;
  }

  dynamic _jsonDecodeSafe(String source) {
    try {
      return jsonDecode(source);
    } catch (_) {
      return null;
    }
  }
}
