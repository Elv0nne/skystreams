/// A title's tracker ids with a lookup's added: the title's own win. A
/// source's MAL and AniList ids name the season it is, where a lookup by IMDb
/// or TMDB id (Simkl's) names the series, so its ids only fill the gaps.
Map<String, String> withLookedUpIds(
  Map<String, String>? own,
  Map<String, String> lookedUp,
) => {...lookedUp, ...?own};
