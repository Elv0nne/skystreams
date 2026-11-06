/// Carrying an audio or subtitle choice across a reopen.
///
/// A failover, a recovery and a rendition step-down all re-open media under a
/// viewer who did nothing. The reopen restores the position and, until this
/// existed, nothing else - so the audio and subtitles went back to whatever the
/// engine picks for itself, which is what a viewer watching a dubbed film or
/// reading subtitles notices immediately.
///
/// Ids alone cannot carry the choice. A recovery of the same file keeps them,
/// but a failover moves to a different provider's file where id 3 means
/// something else entirely, and a rendition step-down can renumber. So a
/// remembered pick keeps the language and the name too, and the id is only the
/// first thing tried.
library;

import 'package:vlc_player/vlc_player.dart';

import 'track_language.dart';

/// A track the viewer was listening to or reading before a reopen.
class RememberedTrack {
  /// Creates a remembered pick.
  const RememberedTrack({required this.id, this.language, this.name});

  /// Snapshots [description], or null when there is nothing selected.
  static RememberedTrack? of(VlcTrackDescription? description) =>
      description == null
      ? null
      : RememberedTrack(
          id: description.id,
          language: description.language,
          name: description.name,
        );

  /// The engine id at the time it was chosen.
  final int id;

  /// The track's language: its own tag, or for a track snapshotted from
  /// [withTrackLanguages] the language its media info or its name gives.
  final String? language;

  /// The track's display name: what tells it from the other tracks in its
  /// language, and all there is to go on when it has none.
  final String? name;

  /// Whether the pick says what language it is in. One that does not can be
  /// found again only by its name or its number, which mean nothing on
  /// another copy of the film.
  bool get hasLanguage => _primarySubtag(language) != null;
}

/// Lowercased primary subtag, or null when the tag says nothing.
///
/// `und` is what sources emit for "unknown", so it matches nothing rather than
/// matching every other unknown track.
String? _primarySubtag(String? tag) {
  if (tag == null) return null;
  final primary = tag.trim().toLowerCase().split(RegExp('[-_]')).first;
  if (primary.isEmpty || primary == 'und') return null;
  // The same language may be tagged `tur` by one source and `tr` by the
  // next. Canonicalize recognized ISO codes before comparing them, while
  // preserving the old exact-tag behaviour for unknown languages.
  return languageCodeOf(primary) ?? primary;
}

/// The track in [available] that best answers [remembered], or null when
/// nothing does.
///
/// Tried in order of how much each signal proves:
///
///  1. The same language and the same name: the track itself, on the same
///     file or on another copy that labels it alike.
///  2. The same language and the same id, so long as it is the same kind of
///     track - a commentary for a commentary, the film for the film
///     ([isCommentaryOrDescription]). A recovery of the same file, where the
///     id genuinely still means what it meant.
///  3. The same language: the first track in it that is the film rather than
///     a commentary over it. A failover to another provider's copy of the
///     same film, where ids are meaningless but "the French track" still is.
///     The source's own order decides between two, and a language the copy
///     has only commentaries in is gone from it.
///  4. The same name, for a source that declares no language at all - common
///     on scraped releases where the only label is "AAC 5.1".
///  5. The same id, when the remembered pick had neither language nor name.
///
/// Deliberately no positional fallback. "Whatever is second in the list" is a
/// guess, and a wrong audio track is worse than the engine's own default -
/// which is what returning null leaves in place.
VlcTrackDescription? matchRememberedTrack(
  List<VlcTrackDescription> available,
  RememberedTrack? remembered,
) {
  if (remembered == null || available.isEmpty) return null;

  final wanted = _primarySubtag(remembered.language);

  if (wanted != null) {
    final inLanguage = <VlcTrackDescription>[
      for (final track in available)
        if (_primarySubtag(track.language) == wanted) track,
    ];
    final name = remembered.name?.trim();
    if (name != null && name.isNotEmpty) {
      for (final track in inLanguage) {
        if (track.name.trim() == name) return track;
      }
    }
    final commentary = _notTheFilm.hasMatch(remembered.name ?? '');
    for (final track in inLanguage) {
      if (track.id == remembered.id &&
          isCommentaryOrDescription(track) == commentary) {
        return track;
      }
    }
    // A language gone from this source returns null here. Falling back to the
    // id would hand over an unrelated track that merely shares a number.
    return inLanguage
        .where((track) => !isCommentaryOrDescription(track))
        .firstOrNull;
  }

  final name = remembered.name?.trim();
  if (name != null && name.isNotEmpty) {
    for (final track in available) {
      if (track.name.trim() == name) return track;
    }
  }

  for (final track in available) {
    if (track.id == remembered.id) return track;
  }
  return null;
}

/// [track] with the language it is in written into its
/// [VlcTrackDescription.language], read from whichever says it first: the
/// track's own tag, libVLC's brackets in its name ([languageCodeOfBrackets]),
/// `getMediaInfo`'s entry for it ([info]), or the rest of its name - see
/// [languageCodeOfTrackName]. A track none of them places is left as it was.
///
/// The brackets come before [info] because they are libVLC's word on this
/// very track, while [info] is matched to it by position - which a deleted
/// stream, or a second program in a TS, puts out of step.
///
/// Written into the description rather than carried beside it so that
/// everything downstream - [RememberedTrack.of], [matchRememberedTrack],
/// [findPreferredAudioTrack] - reads one field, the one every native leaves
/// null.
VlcTrackDescription withTrackLanguage(
  VlcTrackDescription track,
  VlcMediaTrackInfo? info,
) {
  final language =
      languageCodeOf(track.language) ??
      languageCodeOfBrackets(track.name) ??
      languageCodeOf(info?.language) ??
      languageCodeOfTrackName(track.name);
  if (language == null) return track;
  return VlcTrackDescription(
    id: track.id,
    name: track.name,
    language: language,
  );
}

/// The engine's [tracks] without libVLC's `Disable`, each
/// [withTrackLanguage].
///
/// [info] is `getMediaInfo`'s list of the same kind of track, and is matched
/// to [tracks] by position - the only correlation libVLC offers, and the one
/// the panel's rows use. A short list leaves the tail to its names.
List<VlcTrackDescription> withTrackLanguages(
  List<VlcTrackDescription> tracks,
  List<VlcMediaTrackInfo> info,
) {
  final listed = tracks.where((track) => track.id >= 0).toList();
  return <VlcTrackDescription>[
    for (final (index, track) in listed.indexed)
      withTrackLanguage(track, index < info.length ? info[index] : null),
  ];
}

/// A commentary or an audio description: in the language, but not the film.
///
/// Whole words only, in the languages releases label them in - `AD` is one
/// in `English (AD)`, and none in `Headphone`.
final RegExp _notTheFilm = RegExp(
  r'(?<![\p{L}\p{M}])(?:commentar(?:y|ies)|kommentare?|comentarios?|'
  r'commentaires?|comment[oi]|descriptions?|descriptive|described|ad|'
  r'audiodeskription|audiodescripci[oó]n|audiodescri[cç][aã]o|'
  r'audiodescription|hörfilm)(?![\p{L}\p{M}])',
  caseSensitive: false,
  unicode: true,
);

/// Whether [track] is a commentary or an audio description - over the film,
/// in its language, but not the film - by what its name says.
bool isCommentaryOrDescription(VlcTrackDescription track) =>
    _notTheFilm.hasMatch(track.name);

/// The track in [tracks] in the [preferred] language, or null when there is
/// none - the engine's default then stands, which is better than a guess.
///
/// [tracks] are read by [withTrackLanguages]; a description passed as the
/// engine sent it is read by its own tag and its name.
///
/// The track [activeId] names is the answer whenever it is in the language: a
/// source that already plays Hindi DD 5.1 is not switched to its Hindi 2.0
/// for being listed first. Otherwise the first in the language that is the
/// film itself rather than a commentary or an audio description over it
/// ([isCommentaryOrDescription]). A language the media has only those in
/// counts as missing - a Japanese film with an English commentary goes on in
/// Japanese - unless one of them is already the one playing. libVLC's
/// `Disable` never is.
VlcTrackDescription? findPreferredAudioTrack(
  List<VlcTrackDescription> tracks,
  String preferred, {
  int? activeId,
}) {
  final wanted = languageCodeOf(preferred);
  if (wanted == null) return null;
  final matches = <VlcTrackDescription>[
    for (final track in tracks)
      if (track.id >= 0 && withTrackLanguage(track, null).language == wanted)
        track,
  ];
  return matches.where((track) => track.id == activeId).firstOrNull ??
      matches.where((track) => !isCommentaryOrDescription(track)).firstOrNull;
}
