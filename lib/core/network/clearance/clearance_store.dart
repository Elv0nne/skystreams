import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// A cookie as a clearance holds it.
@immutable
class StoredCookie {
  const StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    this.path = '/',
    this.expires,
    this.httpOnly = false,
    this.secure = false,
  });

  factory StoredCookie.fromJson(Map<String, dynamic> json) => StoredCookie(
    name: json['n'] as String,
    value: json['v'] as String,
    domain: json['d'] as String,
    path: json['p'] as String? ?? '/',
    expires: switch (json['e']) {
      final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
      _ => null,
    },
    httpOnly: json['h'] == true,
    secure: json['s'] == true,
  );

  final String name;
  final String value;

  /// As the browser reports it: `.example.com` for the site and its
  /// subdomains, `example.com` for that host only.
  final String domain;
  final String path;

  /// Null for a session cookie.
  final DateTime? expires;
  final bool httpOnly;
  final bool secure;

  /// Whether a request to [host] at [path] gets this cookie.
  bool matches(String host, String requestPath) {
    final h = host.toLowerCase();
    final d = domain.toLowerCase();
    final domainMatches = d.startsWith('.')
        ? h == d.substring(1) || h.endsWith(d)
        : h == d;
    if (!domainMatches) return false;
    final p = requestPath.isEmpty ? '/' : requestPath;
    return p == path ||
        p.startsWith(path.endsWith('/') ? path : '$path/') ||
        path == '/';
  }

  Map<String, dynamic> toJson() => {
    'n': name,
    'v': value,
    'd': domain,
    if (path != '/') 'p': path,
    if (expires != null) 'e': expires!.millisecondsSinceEpoch,
    if (httpOnly) 'h': true,
    if (secure) 's': true,
  };
}

/// What SkyStream knows about one site's bot check.
@immutable
class SiteClearance {
  const SiteClearance({
    required this.site,
    this.cookies = const [],
    this.agent,
    this.solvedAt,
    this.lifetime,
    this.lastAcceptedAt,
    this.browserOnly = false,
    this.lastCheckAt,
    this.checkUrl,
    this.needsPerson = false,
  });

  factory SiteClearance.fromJson(Map<String, dynamic> json) => SiteClearance(
    site: json['site'] as String,
    cookies: [
      for (final c in (json['cookies'] as List<dynamic>? ?? const []))
        StoredCookie.fromJson(c as Map<String, dynamic>),
    ],
    agent: json['agent'] as String?,
    solvedAt: _time(json['solvedAt']),
    lifetime: switch (json['lifetimeMin']) {
      final int min => Duration(minutes: min),
      _ => null,
    },
    lastAcceptedAt: _time(json['acceptedAt']),
    browserOnly: json['browserOnly'] == true,
    lastCheckAt: _time(json['checkAt']),
    checkUrl: json['checkUrl'] as String?,
  );

  static DateTime? _time(Object? ms) =>
      ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;

  /// The registrable domain (see `SiteKeys`).
  final String site;

  /// The cookies the check left: `cf_clearance` and whatever the site set.
  /// Empty when there is no clearance.
  final List<StoredCookie> cookies;

  /// The browser's user agent: the clearance holds only under it.
  final String? agent;
  final DateTime? solvedAt;

  /// How long the site's clearance lasts (its Challenge Passage), learned
  /// from when it first challenged again after a solve.
  final Duration? lifetime;

  /// The last time a request with the clearance got through.
  final DateTime? lastAcceptedAt;

  /// The site refuses requests from outside the browser even with a fresh
  /// clearance: its requests go through a page.
  final bool browserOnly;

  /// The last time a request to the site met a check.
  final DateTime? lastCheckAt;

  /// The page to load to clear the site's check.
  final String? checkUrl;

  /// A hidden solve couldn't clear the check: a person has to. Not saved:
  /// after a restart, a site's next check is a new automatic try.
  final bool needsPerson;

  bool get hasClearance => cookies.isNotEmpty && agent != null;

  SiteClearance copyWith({
    List<StoredCookie>? cookies,
    String? agent,
    DateTime? solvedAt,
    Duration? lifetime,
    DateTime? lastAcceptedAt,
    bool? browserOnly,
    DateTime? lastCheckAt,
    String? checkUrl,
    bool? needsPerson,
  }) => SiteClearance(
    site: site,
    cookies: cookies ?? this.cookies,
    agent: agent ?? this.agent,
    solvedAt: solvedAt ?? this.solvedAt,
    lifetime: lifetime ?? this.lifetime,
    lastAcceptedAt: lastAcceptedAt ?? this.lastAcceptedAt,
    browserOnly: browserOnly ?? this.browserOnly,
    lastCheckAt: lastCheckAt ?? this.lastCheckAt,
    checkUrl: checkUrl ?? this.checkUrl,
    needsPerson: needsPerson ?? this.needsPerson,
  );

  Map<String, dynamic> toJson() => {
    'site': site,
    if (cookies.isNotEmpty) 'cookies': [for (final c in cookies) c.toJson()],
    if (agent != null) 'agent': agent,
    if (solvedAt != null) 'solvedAt': solvedAt!.millisecondsSinceEpoch,
    if (lifetime != null) 'lifetimeMin': lifetime!.inMinutes,
    if (lastAcceptedAt != null)
      'acceptedAt': lastAcceptedAt!.millisecondsSinceEpoch,
    if (browserOnly) 'browserOnly': true,
    if (lastCheckAt != null) 'checkAt': lastCheckAt!.millisecondsSinceEpoch,
    if (checkUrl != null) 'checkUrl': checkUrl,
  };
}

/// Every site's clearance, saved across restarts. One entry per site serves
/// every extension and every client.
class ClearanceStore {
  ClearanceStore({File? file, DateTime Function()? clock})
    : _file = file,
      _clock = clock ?? DateTime.now;

  /// How long a clearance counts as fresh when its site's lifetime isn't
  /// known yet: Cloudflare's default Challenge Passage.
  static const defaultLifetime = Duration(minutes: 30);

  /// Counted off a clearance's lifetime, so a clearance about to lapse isn't
  /// sent.
  static const _margin = Duration(minutes: 2);

  /// How soon after its solve a clearance meeting a check means the site
  /// refuses requests from outside the browser: one that new hasn't lapsed.
  static const justSolved = Duration(seconds: 90);

  final File? _file;
  final DateTime Function() _clock;
  final Map<String, SiteClearance> _sites = {};
  final _changes = StreamController<void>.broadcast();
  Timer? _saveTimer;

  /// Fires after any change.
  Stream<void> get changes => _changes.stream;

  /// Hosts that moved, to the origin they moved to ([recordMove]). Saved.
  /// By host: another host of the same site may live elsewhere.
  final Map<String, Uri> _moves = {};

  /// Sites whose check the person asked not to open by itself.
  final Set<String> _quiet = {};

  /// Whether [site]'s check shouldn't open the sheet by itself: the person
  /// asked so. Verify still opens it.
  bool isQuiet(String site) => _quiet.contains(site);

  void setQuiet(String site, bool quiet) {
    final changed = quiet ? _quiet.add(site) : _quiet.remove(site);
    if (changed) _changed(saveNow: true);
  }

  /// Where [host] moved, when it did.
  Uri? movedTo(String host) => _moves[host];

  /// Every move, for the CloudStream engine.
  Map<String, Uri> get moves => Map.unmodifiable(_moves);

  /// [host] answered from [origin] through permanent redirects: its later
  /// requests go there. A later move replaces it.
  void recordMove(String host, Uri origin) {
    if (_moves[host] == origin) return;
    _moves[host] = origin;
    _changed(saveNow: true);
  }

  /// [host]'s new domain stopped answering, or it moved back: its requests go
  /// to its own address again, which says where it is now.
  void forgetMove(String host) {
    if (_moves.remove(host) == null) return;
    _changed(saveNow: true);
  }

  DateTime get now => _clock();

  SiteClearance? operator [](String site) => _sites[site];

  Iterable<SiteClearance> get all => _sites.values;

  /// Reads the saved entries. A missing or unreadable file means none.
  Future<void> load() async {
    final file = _file;
    if (file == null || !await file.exists()) return;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      for (final entry in json['sites'] as List<dynamic>) {
        final site = SiteClearance.fromJson(entry as Map<String, dynamic>);
        _sites[site.site] = site;
      }
      // Not 'moves': development builds saved some from redirects that were no
      // moves (GitHub's raw host to github.com), which broke its downloads.
      final quiet = json['quietSites'];
      if (quiet is List<dynamic>) _quiet.addAll(quiet.whereType<String>());
      final moves = json['checkedMoves'];
      if (moves is Map<String, dynamic>) {
        for (final e in moves.entries) {
          final origin = Uri.tryParse('${e.value}');
          if (origin != null && origin.hasScheme) _moves[e.key] = origin;
        }
      }
    } catch (_) {
      // A damaged file costs one solve per site.
    }
  }

  /// Whether [site]'s clearance should still hold.
  bool isFresh(String site) {
    final entry = _sites[site];
    final solvedAt = entry?.solvedAt;
    if (entry == null || solvedAt == null) return false;
    // A browser-only site may hold no cookie: the browser saw no check.
    if (!entry.hasClearance && !entry.browserOnly) return false;
    final lifetime = entry.lifetime ?? defaultLifetime;
    return now.isBefore(solvedAt.add(lifetime - _margin));
  }

  /// Whether [site] was solved within [justSolved].
  bool isJustSolved(String site) {
    final solvedAt = _sites[site]?.solvedAt;
    return solvedAt != null && now.difference(solvedAt) < justSolved;
  }

  /// A solve cleared [site]: its cookies and the agent they hold under.
  /// Clearances earned under another agent (the browser was updated) are
  /// dropped: they no longer hold.
  void recordSolve(
    String site, {
    required List<StoredCookie> cookies,
    required String agent,
    required String url,
  }) {
    final time = now;
    for (final other in _sites.values.toList()) {
      if (other.site != site && other.agent != null && other.agent != agent) {
        _sites[other.site] = SiteClearance(
          site: other.site,
          lifetime: other.lifetime,
          browserOnly: other.browserOnly,
          lastCheckAt: other.lastCheckAt,
          checkUrl: other.checkUrl,
        );
      }
    }
    final previous = _sites[site];
    _sites[site] = SiteClearance(
      site: site,
      cookies: cookies,
      agent: agent,
      solvedAt: time,
      lifetime: previous?.lifetime,
      browserOnly: previous?.browserOnly ?? false,
      lastCheckAt: previous?.lastCheckAt ?? time,
      checkUrl: url,
    );
    _changed(saveNow: true);
  }

  /// A request to [site] met a check. If the site had a clearance, it has
  /// lapsed: its lifetime is learned from when, and its cookies dropped.
  void recordCheck(String site, String url) {
    final time = now;
    final previous = _sites[site];
    Duration? lifetime = previous?.lifetime;
    final solvedAt = previous?.solvedAt;
    if (previous != null && previous.hasClearance && solvedAt != null) {
      lifetime = learnLifetime(
        known: previous.lifetime,
        lapsedAfter: time.difference(solvedAt),
        acceptedFor: previous.lastAcceptedAt?.difference(solvedAt),
      );
    }
    _sites[site] = SiteClearance(
      site: site,
      lifetime: lifetime,
      browserOnly: previous?.browserOnly ?? false,
      lastCheckAt: time,
      checkUrl: previous?.checkUrl ?? url,
      needsPerson: previous?.needsPerson ?? false,
    );
    _changed();
  }

  /// A request with [site]'s clearance got through. Saved with the next
  /// change, not on its own: it happens on every request.
  void recordAccepted(String site) {
    final entry = _sites[site];
    if (entry == null || !entry.hasClearance) return;
    _sites[site] = entry.copyWith(lastAcceptedAt: now);
  }

  void markBrowserOnly(String site) {
    final entry = _sites[site];
    if (entry == null || entry.browserOnly) return;
    _sites[site] = entry.copyWith(browserOnly: true);
    _changed(saveNow: true);
  }

  /// Whether a person has to clear [site]'s check.
  void markNeedsPerson(String site, String url, {bool needed = true}) {
    final entry = _sites[site] ?? SiteClearance(site: site, checkUrl: url);
    if (entry.needsPerson == needed) return;
    _sites[site] = entry.copyWith(
      needsPerson: needed,
      checkUrl: entry.checkUrl ?? url,
      lastCheckAt: entry.lastCheckAt ?? now,
    );
    _changed();
  }

  /// Forgets everything (Settings › clear data).
  void clear() {
    _sites.clear();
    _moves.clear();
    _changed(saveNow: true);
  }

  /// Writes pending changes now.
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _write();
  }

  void _changed({bool saveNow = false}) {
    if (!_changes.isClosed) _changes.add(null);
    if (_file == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(
      saveNow ? Duration.zero : const Duration(seconds: 2),
      () => unawaited(_write()),
    );
  }

  Future<void> _write() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode({
          'version': 1,
          'sites': [for (final e in _sites.values) e.toJson()],
          'checkedMoves': {
            for (final e in _moves.entries) e.key: e.value.toString(),
          },
          'quietSites': [..._quiet],
        }),
        flush: true,
      );
      await temp.rename(file.path);
    } catch (_) {
      // Unwritable: clearances last as long as the process.
    }
  }
}

/// A site's clearance lifetime, from a lapse seen [lapsedAfter] its solve.
///
/// The lapse is seen at the first request after it, so one observation can
/// overstate the lifetime; the shortest seen wins. A request accepted
/// [acceptedFor] after the solve proves the lifetime is at least that long.
/// Rounded down to five minutes, since sites set it in round numbers (15, 30,
/// 45, 60 minutes).
@visibleForTesting
Duration learnLifetime({
  required Duration? known,
  required Duration lapsedAfter,
  Duration? acceptedFor,
}) {
  const step = 5;
  final rounded = Duration(
    minutes: math.max(step, lapsedAfter.inMinutes ~/ step * step),
  );
  var lifetime = known == null || rounded < known ? rounded : known;
  if (acceptedFor != null && acceptedFor > lifetime) {
    lifetime = Duration(minutes: acceptedFor.inMinutes);
  }
  return lifetime;
}
