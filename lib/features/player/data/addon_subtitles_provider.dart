import 'package:dio/dio.dart';

import '../../../core/addons/data/addon_subtitle_service.dart';
import '../../../core/addons/models/addon_manifest.dart';
import '../domain/entity/subtitle_model.dart';
import '../domain/track_language.dart';

/// A Stremio add-on that answers subtitles, as a source of the player's
/// subtitle search: the ones the viewer installed, and OpenSubtitles' keyless
/// one (see [AddonSubtitleService.sources]).
///
/// Stremio names a film by its IMDb id and an episode by its show's with the
/// season and episode (`tt0903747:2:5`), and nothing broader: a title alone,
/// or a season without its episode, is no request an add-on can answer.
class AddonSubtitlesProvider extends SubtitleProvider {
  AddonSubtitlesProvider(this._service, this.addon, {String? name})
    : _name = name ?? addon.displayName;

  final AddonSubtitleService _service;
  final ManagedAddon addon;
  final String _name;

  @override
  String get name => _name;

  @override
  String get idPrefix => 'addon';

  @override
  Future<List<OnlineSubtitle>> search({
    required String query,
    String? imdbId,
    int? tmdbId,
    int? season,
    int? episode,
    String? language,
    CancelToken? cancelToken,
  }) async {
    final digits = imdbId?.replaceAll('tt', '').trim();
    if (digits == null || digits.isEmpty) return const [];
    final series = season != null && season > 0;
    if (series && (episode == null || episode <= 0)) return const [];
    final tracks = await _service.ask(
      addon,
      type: series ? 'series' : 'movie',
      id: series ? 'tt$digits:$season:$episode' : 'tt$digits',
      cancelToken: cancelToken,
    );
    // An add-on answers in every language it has, coded its own way
    // (`eng`, `pob`, `zht`): [languageCodeOf] reads both sides alike.
    final wanted = language == null ? null : languageCodeOf(language);
    return [
      for (final track in tracks)
        if (wanted == null || languageCodeOf(track.lang) == wanted)
          OnlineSubtitle(
            // An add-on's ids are its own: another may use the same ones.
            id: '${addon.manifestUrl}#${track.id}',
            name: track.release ?? track.label,
            // Labelled with the language asked for, as the other sources'.
            language: language ?? track.lang,
            source: name,
            downloadUrl: track.url,
            metadata: const {'mode': 'addon'},
          ),
    ];
  }

  @override
  Future<String?> getDownloadUrl(OnlineSubtitle subtitle) async =>
      subtitle.downloadUrl;

  /// A subtitle add-on serves its files as they are, to any client.
  @override
  Map<String, String> getDownloadHeaders(OnlineSubtitle subtitle) => const {};
}
