import 'dart:async';

import 'package:flutter/foundation.dart';

/// Where a site's bot check stands, as screens show it.
enum CheckState {
  /// An automatic try is running in a hidden page.
  checking,

  /// The automatic try wants a person.
  needsYou,

  /// Verify is getting the check's page.
  opening,

  /// Cleared: by the automatic try, by the person, or already held.
  cleared,

  /// The page didn't load, or the check didn't settle in time.
  unreachable,

  /// A block page, which no check clears.
  blocked,

  /// After its check, the browser was sent to another site.
  sentElsewhere,

  /// The person pressed Done, but SkyStream found no clearance.
  stillNotCleared,

  /// Android System WebView is too old to pass the check: nothing is tried
  /// until it's updated, but Verify still shows the page.
  outdated,

  /// The check passed, but the site refuses SkyStream all the same: no new
  /// try for a while.
  ineffective,

  /// The check came back after every clearance, even after a fresh start.
  keepsAsking,
}

/// One site's check, this app run.
@immutable
class SiteCheck {
  const SiteCheck({
    required this.site,
    required this.state,
    required this.since,
    required this.metAt,
    this.sources = const {},
    this.movedFrom,
    this.elsewhere,
  });

  /// The site checked: the new domain's, when it moved.
  final String site;
  final CheckState state;

  /// When [state] began.
  final DateTime since;

  /// The last time a request met this site's check.
  final DateTime metAt;

  /// The extensions whose requests met it (`SkyStreamProvider.checkSource`):
  /// `js:<namespace>`, `cs3:<provider id>`, or `cs3` when the engine couldn't
  /// say which CloudStream extension.
  final Set<String> sources;

  /// The site it moved from, when it did.
  final String? movedFrom;

  /// Where the browser was sent ([CheckState.sentElsewhere]).
  final String? elsewhere;

  /// Whether a person can clear it: Verify.
  bool get wantsPerson =>
      state == CheckState.needsYou ||
      state == CheckState.stillNotCleared ||
      state == CheckState.keepsAsking;

  /// Whether it's still under way.
  bool get pending =>
      state == CheckState.checking || state == CheckState.opening;

  /// Whether the extension tagged [source] met it: its own tag, or any
  /// CloudStream extension's for a check filed under them all (`cs3`), when
  /// the engine couldn't say which.
  bool metBy(String? source) =>
      source != null &&
      (sources.contains(source) ||
          source.startsWith('cs3:') && sources.contains('cs3'));

  SiteCheck _copy({
    CheckState? state,
    DateTime? since,
    DateTime? metAt,
    Set<String>? sources,
    String? movedFrom,
    String? elsewhere,
  }) => SiteCheck(
    site: site,
    state: state ?? this.state,
    since: since ?? this.since,
    metAt: metAt ?? this.metAt,
    sources: sources ?? this.sources,
    movedFrom: movedFrom ?? this.movedFrom,
    elsewhere: elsewhere ?? this.elsewhere,
  );
}

/// The bot checks this app run has met, one per site, for the screens that
/// wait on them. Not saved: after a restart, a site's next check is a new
/// automatic try.
class SiteChecks {
  SiteChecks({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, SiteCheck> _checks = {};
  final _changes = StreamController<void>.broadcast();

  /// Fires after any change.
  Stream<void> get changes => _changes.stream;

  DateTime get now => _clock();

  SiteCheck? operator [](String site) => _checks[site];

  /// A request from [source] met [site]'s check. A site met for the first
  /// time is being checked; the solver says what happens next.
  void met(String site, {String? source, String? movedFrom}) {
    final time = now;
    final check = _checks[site];
    _checks[site] = check == null
        ? SiteCheck(
            site: site,
            state: CheckState.checking,
            since: time,
            metAt: time,
            sources: {?source},
            movedFrom: movedFrom,
          )
        : check._copy(
            metAt: time,
            sources: {...check.sources, ?source},
            movedFrom: movedFrom,
          );
    _changes.add(null);
  }

  /// [site]'s check is now in [state].
  void update(String site, CheckState state, {String? elsewhere}) {
    final time = now;
    final check = _checks[site];
    _checks[site] = check == null
        ? SiteCheck(
            site: site,
            state: state,
            since: time,
            metAt: time,
            elsewhere: elsewhere,
          )
        : check._copy(state: state, since: time, elsewhere: elsewhere);
    _changes.add(null);
  }

  /// The checks met since [since], in the order they were first met; only
  /// those met by one of [sources], when given.
  List<SiteCheck> since(DateTime since, {Set<String>? sources}) => [
    for (final check in _checks.values)
      if (!check.metAt.isBefore(since) &&
          (sources == null || check.sources.any(sources.contains)))
        check,
  ];

  /// The check [source] met most lately, since [since].
  SiteCheck? latestFor(String? source, {required DateTime since}) {
    if (source == null) return null;
    SiteCheck? latest;
    for (final check in this.since(since, sources: {source})) {
      if (latest == null || check.metAt.isAfter(latest.metAt)) latest = check;
    }
    return latest;
  }
}
