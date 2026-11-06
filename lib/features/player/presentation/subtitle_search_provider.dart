import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:path/path.dart' as p;

import '../../../core/addons/data/addon_repository.dart';
import '../../../core/addons/data/addon_subtitle_service.dart';
import '../../../core/addons/models/addon_manifest.dart';
import '../../../core/network/dio_client_provider.dart';
import '../../../core/storage/app_temp_directory.dart';
import '../data/addon_subtitles_provider.dart';
import '../data/subtitle_providers.dart';
import '../domain/entity/subtitle_model.dart';
import '../domain/subtitle_archive.dart';
import '../../settings/presentation/player_settings_provider.dart';

part 'subtitle_search_provider.g.dart';

// Args + worker for the ZIP-extraction `compute()` call below. Kept at file
// scope because compute() requires a top-level / static target.
class _SubtitleZipArgs {
  final Uint8List bytes;
  final String tempDirPath;
  final int? season;
  final int? episode;
  final String? language;
  _SubtitleZipArgs(
    this.bytes,
    this.tempDirPath, {
    this.season,
    this.episode,
    this.language,
  });
}

/// Writes out the file of the archive [pickSubtitleEntry] chooses - the
/// episode being watched from a season pack, and never the uploader's note -
/// or null when none will do.
Future<String?> _extractSubtitleFromZip(_SubtitleZipArgs args) async {
  final archive = ZipDecoder().decodeBytes(args.bytes);
  final files = [
    for (final file in archive)
      if (file.isFile) file,
  ];
  final picked = pickSubtitleEntry(
    [for (final file in files) (name: file.name, size: file.size)],
    season: args.season,
    episode: args.episode,
    language: args.language,
  );
  if (picked == null) return null;
  final file = files.firstWhere((file) => file.name == picked);
  final subFile = File(
    p.join(
      args.tempDirPath,
      "sub_${DateTime.now().millisecondsSinceEpoch}_${p.basename(file.name)}",
    ),
  );
  await subFile.writeAsBytes(file.content as List<int>);
  return subFile.path;
}

List<int> _decompressGzip(Uint8List bytes) {
  return const GZipDecoder().decodeBytes(bytes);
}

/// How the results currently in [SubtitleSearch]'s state were found.
///
/// The notifier walks a chain of passes and stops at the first one that
/// returns anything: exact id match -> title text -> season without episode.
/// A widget that `ref.watch`es the state and `ref.read`s
/// `SubtitleSearch.lastMode` in the same build sees a consistent pair, because
/// the mode is always assigned before the state write of the same pass.
enum SubtitleSearchMode {
  /// IMDb / TMDb id was sent (with season/episode when known).
  byId,

  /// No id was available; the title text was sent.
  byTitle,

  /// The id pass returned nothing; these are title-text matches.
  byTitleAfterIdMiss,

  /// The episode-scoped pass(es) returned nothing; these are for the whole
  /// season. The viewer has to pick the right episode's file by name.
  bySeasonAfterEpisodeMiss,
}

/// The (resolved) arguments of one `search()` call, used to skip a repeat of
/// a search that already completed.
typedef _SearchRequest = ({
  String query,
  String? imdbId,
  int? tmdbId,
  int? season,
  int? episode,
  String language,
});

/// The sources a subtitle search asks, in order: OpenSubtitles, SubDL and
/// SubSource as [settings] key them, then the Stremio add-ons that answer
/// subtitles - [installed]'s, and OpenSubtitles' keyless one (see
/// [AddonSubtitleService.sources]). Each under a name of its own: a
/// download is routed by its result's source.
List<SubtitleProvider> subtitleSources({
  required Dio dio,
  required PlayerSettings settings,
  required AddonSubtitleService addons,
  required List<ManagedAddon> installed,
}) {
  final sources = <SubtitleProvider>[
    OpenSubtitlesProvider(
      dio,
      username: settings.osUsername,
      password: settings.osPassword,
      apiKey: settings.osApiKey,
    ),
    // Key only, unlike OpenSubtitles above: SubDL's search endpoint
    // authenticates with `api_key` and nothing else, and the account pair it
    // also stores exists to mint that key from the settings dialog. Passing
    // the pair here would change nothing.
    SubDLProvider(dio, apiKey: settings.subdlApiKey),
    SubSourceProvider(dio, apiKey: settings.subsourceApiKey),
  ];
  for (final addon in addons.sources(installed)) {
    final taken = {for (final source in sources) source.name};
    var name = addon.displayName;
    if (taken.contains(name)) name = '$name · Stremio';
    // Two add-ons of one name: the first is asked.
    if (taken.contains(name)) continue;
    sources.add(AddonSubtitlesProvider(addons, addon, name: name));
  }
  return sources;
}

@riverpod
class SubtitleSearch extends _$SubtitleSearch {
  /// Test seam: when non-null, used instead of the three real providers.
  ///
  /// A generated notifier cannot take constructor arguments, so this is a
  /// static. Set it in `setUp`, clear it in `tearDown`.
  @visibleForTesting
  static List<SubtitleProvider>? debugProviders;

  // ignore: riverpod_lint/avoid_public_notifier_properties
  /// How the current results were found. Assigned before every `state`
  /// write, so reading it next to a watched state is always consistent.
  ///
  /// riverpod_lint would have this go through `state`. That is the right
  /// default, but it is not free here: the mode is metadata about the search
  /// that produced the current results, not part of them, and folding it into
  /// the state class would rebuild every watcher whenever only the mode
  /// changed. The invariant above is what keeps the pair consistent.
  ///
  /// Hence the ignore above this comment, where the diagnostic starts. An
  /// analyzer plugin's diagnostics are filtered only by an ignore that names
  /// the plugin: `riverpod_lint/avoid_public_notifier_properties`.
  SubtitleSearchMode lastMode = SubtitleSearchMode.byTitle;

  late List<SubtitleProvider> _providers;
  CancelToken? _cancelToken;
  int _activeSearchId = 0;

  /// The request whose passes all ran to completion most recently *and found
  /// something*. Repeating it while the state is data is a no-op: the sheet
  /// auto-searches on open, and OpenSubtitles rate-limits per key.
  ///
  /// An outcome of nothing is deliberately never latched here. Every provider
  /// swallows its own network errors and answers `[]` (subtitle_providers.dart),
  /// so a dead Wi-Fi link, a 429 and a genuine miss all reach this notifier as
  /// the same empty chain. The sheet's search button is the only retry
  /// affordance there is - no pull-to-refresh, and no keyboard on a television
  /// - so latching an empty outcome made that button a no-op for the rest of
  /// the sheet's life, exactly when it was needed. A pass that found nothing
  /// also spent nothing worth protecting a rate-limited key from.
  _SearchRequest? _lastCompleted;

  @override
  FutureOr<List<OnlineSubtitle>?> build() {
    ref.onDispose(() {
      _cancelToken?.cancel();
    });

    // Watch settings to update providers if they change
    ref.listen(playerSettingsProvider, (previous, next) {
      if (next.hasValue) {
        _initializeProviders();
      }
    });
    // And the add-ons, which are sources too: one installed, enabled or
    // loaded from storage after this was built.
    ref.listen(addonRepositoryProvider, (_, _) => _initializeProviders());

    _initializeProviders();
    return null;
  }

  void _initializeProviders() {
    final seam = debugProviders;
    if (seam != null) {
      _providers = List.unmodifiable(seam);
      return;
    }

    _providers = subtitleSources(
      dio: ref.read(dioClientProvider),
      settings:
          ref.read(playerSettingsProvider).asData?.value ??
          const PlayerSettings(),
      addons: ref.read(addonSubtitleServiceProvider),
      installed: ref.read(addonRepositoryProvider).enabled,
    );
  }

  /// Searches every provider and publishes results as they arrive.
  ///
  /// When every provider comes back empty the notifier falls back on its own,
  /// so the caller sends the most specific request it has and reads
  /// [lastMode] to learn what actually matched:
  ///
  /// 1. ids present -> [SubtitleSearchMode.byId]; miss and [query] non-empty
  ///    -> retry without ids as [SubtitleSearchMode.byTitleAfterIdMiss];
  /// 2. still empty with both [season] and [episode] -> retry without the
  ///    episode as [SubtitleSearchMode.bySeasonAfterEpisodeMiss];
  /// 3. still empty -> `AsyncData([])`.
  ///
  /// Never more than three passes. A call that repeats the last request that
  /// found something, while the state is data, is a no-op (see
  /// [_lastCompleted]); a search that came back empty is always retryable.
  Future<void> search({
    required String query,
    String? imdbId,
    int? tmdbId,
    int? season,
    int? episode,
    String? language,
  }) async {
    final String resolvedLanguage =
        language ?? ref.read(subtitleLanguageProvider);
    final _SearchRequest request = (
      query: query,
      imdbId: imdbId,
      tmdbId: tmdbId,
      season: season,
      episode: episode,
      language: resolvedLanguage,
    );
    if (state is AsyncData && request == _lastCompleted) {
      if (kDebugMode) {
        debugPrint(
          "[SubtitleSearch] Skipping repeat of completed search for: $query",
        );
      }
      return;
    }
    _lastCompleted = null;

    final hasId = imdbId != null || tmdbId != null;
    _runPass(
      origin: request,
      pass: 1,
      mode: hasId ? SubtitleSearchMode.byId : SubtitleSearchMode.byTitle,
      query: query,
      imdbId: imdbId,
      tmdbId: tmdbId,
      season: season,
      episode: episode,
      language: resolvedLanguage,
    );
  }

  /// The pass that follows an empty [mode] pass, or null when the chain ends.
  static SubtitleSearchMode? _nextMode({
    required SubtitleSearchMode mode,
    required String query,
    required int? season,
    required int? episode,
  }) {
    if (mode == SubtitleSearchMode.byId && query.trim().isNotEmpty) {
      return SubtitleSearchMode.byTitleAfterIdMiss;
    }
    if (mode != SubtitleSearchMode.bySeasonAfterEpisodeMiss &&
        season != null &&
        episode != null) {
      return SubtitleSearchMode.bySeasonAfterEpisodeMiss;
    }
    return null;
  }

  void _runPass({
    required _SearchRequest origin,
    required int pass,
    required SubtitleSearchMode mode,
    required String query,
    required String? imdbId,
    required int? tmdbId,
    required int? season,
    required int? episode,
    required String language,
  }) {
    // 1. Cancel previous search (or the previous pass of this one)
    _cancelToken?.cancel();
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;

    // 2. Increment search ID to ignore late results from previous calls
    final searchId = ++_activeSearchId;

    if (kDebugMode) {
      debugPrint(
        "[SubtitleSearch] Starting search #$searchId pass $pass ($mode) "
        "for: $query (IMDB: $imdbId, TMDB: $tmdbId, S$season E$episode)",
      );
    }
    // Mode first, state second: a build that watches the state and reads the
    // mode must never see the new state with the previous pass's mode.
    lastMode = mode;
    state = const AsyncLoading();

    final providers = _providers;
    if (providers.isEmpty) {
      // Not latched (see [_lastCompleted]): nothing was searched.
      state = const AsyncData([]);
      return;
    }

    final List<OnlineSubtitle> allResults = [];
    int completedProviders = 0;

    for (final provider in providers) {
      unawaited(
        provider
            .search(
              query: query,
              imdbId: imdbId,
              tmdbId: tmdbId,
              season: season,
              episode: episode,
              language: language,
              cancelToken: cancelToken,
            )
            .then((results) {
              if (!ref.mounted || searchId != _activeSearchId) return;

              if (results.isNotEmpty) {
                allResults.addAll(results);
                state = AsyncData(List.from(allResults));
              }
            })
            .catchError((Object e) {
              if (e is DioException && e.type == DioExceptionType.cancel) {
                return;
              }
              if (kDebugMode) debugPrint("${provider.name} search failed: $e");
            })
            .whenComplete(() {
              if (!ref.mounted || searchId != _activeSearchId) return;

              completedProviders++;
              if (completedProviders != providers.length) return;

              if (allResults.isNotEmpty) {
                _lastCompleted = origin;
                return;
              }

              // Every provider came back empty: widen, or give up.
              final next = _nextMode(
                mode: mode,
                query: query,
                season: season,
                episode: episode,
              );
              if (next == null) {
                // Not latched (see [_lastCompleted]): an empty chain is
                // indistinguishable from a failed one, so the next press of
                // the sheet's search button has to reach the network.
                state = const AsyncData([]);
                return;
              }
              final dropIds = next == SubtitleSearchMode.byTitleAfterIdMiss;
              final dropEpisode =
                  next == SubtitleSearchMode.bySeasonAfterEpisodeMiss;
              _runPass(
                origin: origin,
                pass: pass + 1,
                mode: next,
                query: query,
                imdbId: dropIds ? null : imdbId,
                tmdbId: dropIds ? null : tmdbId,
                season: season,
                episode: dropEpisode ? null : episode,
                language: language,
              );
            }),
      );
    }
  }

  /// Downloads [subtitle] and writes it to a local file, returning its path.
  ///
  /// [season] and [episode] - the episode being watched - choose the file
  /// out of a season pack; see [pickSubtitleEntry].
  Future<String?> downloadAndPrepare(
    OnlineSubtitle subtitle, {
    int? season,
    int? episode,
  }) async {
    _initializeProviders();
    final dio = ref.read(dioClientProvider);
    final provider = _providers.firstWhere((p) => p.name == subtitle.source);

    String? url = subtitle.downloadUrl;
    if (url.isEmpty) {
      if (kDebugMode) {
        print(
          "[SubtitleDownload] No direct URL for '${subtitle.name}' from ${subtitle.source}. Fetching download URL...",
        );
      }
      url = await provider.getDownloadUrl(subtitle) ?? "";
    }

    if (url.isEmpty) {
      if (kDebugMode) {
        print(
          "[SubtitleDownload] ❌ Failed: No download URL could be resolved for '${subtitle.name}' from ${subtitle.source}",
        );
      }
      return null;
    }

    if (kDebugMode) {
      print("[SubtitleDownload] Downloading from ${subtitle.source}: $url");
    }

    try {
      final tempDir = await appTempDirectory();
      final savePath = p.join(
        tempDir.path,
        "temp_sub_${DateTime.now().millisecondsSinceEpoch}",
      );

      // Use provider-specific headers for the download request
      final downloadHeaders = provider.getDownloadHeaders(subtitle);

      final response = await dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: downloadHeaders,
          receiveTimeout: const Duration(seconds: 30),
        ),
      );

      if (response.data == null || response.data!.isEmpty) {
        if (kDebugMode) {
          print(
            "[SubtitleDownload] ❌ Failed: Empty response body from ${subtitle.source} (HTTP ${response.statusCode})",
          );
        }
        return null;
      }

      final List<int> bytes = response.data!;

      if (kDebugMode) {
        print(
          "[SubtitleDownload] Received ${bytes.length} bytes from ${subtitle.source}",
        );
      }

      // Detect archive format by magic bytes
      if (bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
        // ZIP archive (most common for SubDL and SubSource).
        // Decode + extract on a worker isolate so the player UI doesn't
        // freeze while the user is actively watching (audit B12).
        if (kDebugMode) {
          debugPrint("[SubtitleDownload] Detected ZIP archive, extracting...");
        }
        final extractedPath = await compute(
          _extractSubtitleFromZip,
          _SubtitleZipArgs(
            Uint8List.fromList(bytes),
            tempDir.path,
            season: season,
            episode: episode,
            language: subtitle.language,
          ),
        );
        if (extractedPath != null) {
          if (kDebugMode) {
            debugPrint("[SubtitleDownload] ✅ Extracted: $extractedPath");
          }
          return extractedPath;
        }
        if (kDebugMode) {
          debugPrint(
            "[SubtitleDownload] ❌ ZIP had no subtitle file for this episode.",
          );
        }
      } else if (bytes.length > 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
        // GZIP compressed file — also offloaded to worker isolate.
        if (kDebugMode) {
          debugPrint("[SubtitleDownload] Detected GZIP, decompressing...");
        }
        final decompressed = await compute(
          _decompressGzip,
          Uint8List.fromList(bytes),
        );
        final subFile = File("$savePath.srt");
        await subFile.writeAsBytes(decompressed);
        return subFile.path;
      } else if (bytes.length > 4 &&
          bytes[0] == 0x52 &&
          bytes[1] == 0x61 &&
          bytes[2] == 0x72 &&
          bytes[3] == 0x21) {
        // RAR archive - not supported
        if (kDebugMode) {
          print(
            "[SubtitleDownload] ❌ RAR archive detected but not supported. Source: ${subtitle.source}",
          );
        }
        return null;
      } else {
        // Raw subtitle file (typical for OpenSubtitles CDN links)
        final subFile = File("$savePath.srt");
        await subFile.writeAsBytes(bytes);
        if (kDebugMode) print("[SubtitleDownload] ✅ Saved raw subtitle file");
        return subFile.path;
      }
    } on DioException catch (e) {
      if (kDebugMode) {
        print(
          "[SubtitleDownload] ❌ HTTP Error from ${subtitle.source}: "
          "Status=${e.response?.statusCode}, "
          "Message=${e.message}, "
          "URL=$url",
        );
        if (e.response?.data != null) {
          // Try to read error body if it's text
          try {
            final body = e.response?.data is List<int>
                ? String.fromCharCodes(e.response!.data as List<int>)
                : e.response?.data.toString();
            print(
              "[SubtitleDownload] Response body: ${body?.substring(0, (body.length > 200 ? 200 : body.length))}",
            );
          } catch (_) {}
        }
      }
      return null;
    } catch (e, stack) {
      if (kDebugMode) {
        print(
          "[SubtitleDownload] ❌ Unexpected error from ${subtitle.source}: $e",
        );
        print("[SubtitleDownload] Stack: $stack");
      }
      return null;
    }
    return null;
  }
}

@riverpod
class SubtitleLanguage extends _$SubtitleLanguage {
  @override
  String build() => 'en';

  void set(String lang) => state = lang;
}
