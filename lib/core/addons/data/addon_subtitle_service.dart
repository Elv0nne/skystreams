import 'dart:async';

import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/addon_manifest.dart';
import '../models/addon_stream_source.dart';
import 'addon_client.dart';

part 'addon_subtitle_service.g.dart';

@Riverpod(keepAlive: true)
AddonSubtitleService addonSubtitleService(Ref ref) =>
    AddonSubtitleService(ref.watch(addonClientProvider));

/// Subtitles from add-ons implementing the `subtitles` resource, for the
/// player's subtitle search.
///
/// Like ARVIO, the public keyless OpenSubtitles v3 add-on is asked beside the
/// ones installed, so subtitles are there out of the box, with no key and no
/// account. Still 100% add-on protocol — no plugin involved.
class AddonSubtitleService {
  AddonSubtitleService(this._client);

  final AddonClient _client;

  static const Duration _timeout = Duration(seconds: 12);

  /// OpenSubtitles' Stremio add-on, named as it names itself - which keeps
  /// it apart from the OpenSubtitles provider beside it in the search.
  static final ManagedAddon _openSubtitles = ManagedAddon(
    manifestUrl: 'https://opensubtitles-v3.strem.io/manifest.json',
    addedAt: DateTime.fromMillisecondsSinceEpoch(0),
    manifest: const AddonManifest(
      id: 'org.stremio.opensubtitlesv3',
      name: 'OpenSubtitles v3',
      version: '1.0.0',
      types: ['movie', 'series'],
      idPrefixes: ['tt'],
      resources: [AddonResource(name: 'subtitles')],
    ),
  );

  /// The add-ons a subtitle search asks, in [installed]'s order: the ones
  /// that answer subtitles, then OpenSubtitles v3 unless it is one of them.
  List<ManagedAddon> sources(List<ManagedAddon> installed) {
    final sources = [
      for (final addon in installed)
        if (addon.manifest?.hasResource('subtitles') ?? false) addon,
    ];
    final hasOpenSubtitles = sources.any(
      (a) =>
          a.manifestUrl == _openSubtitles.manifestUrl ||
          a.manifest?.id == _openSubtitles.manifest!.id,
    );
    return [...sources, if (!hasOpenSubtitles) _openSubtitles];
  }

  /// [addon]'s subtitles for [id] - `tt0133093`, or `tt0903747:2:5` for an
  /// episode - asked by each type the add-on takes [type] by until one
  /// answers. Nothing for an id the add-on doesn't take, or when it fails.
  Future<List<AddonSubtitleTrack>> ask(
    ManagedAddon addon, {
    required String type,
    required String id,
    CancelToken? cancelToken,
  }) async {
    final manifest = addon.manifest;
    if (manifest == null || !manifest.supportsId('subtitles', id)) {
      return const [];
    }
    for (final requestType in manifest.requestTypesFor('subtitles', type)) {
      try {
        final subs = await _client
            .subtitles(
              addon,
              type: requestType,
              id: id,
              cancelToken: cancelToken,
            )
            .timeout(_timeout);
        if (subs.isNotEmpty) return subs;
      } catch (_) {
        // The next type, if there is one.
      }
    }
    return const [];
  }
}
