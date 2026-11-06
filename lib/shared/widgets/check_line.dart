import 'dart:async';

import 'package:flutter/material.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/clearance/clearance.dart';
import '../../core/network/clearance/site_checks.dart';

/// One site's check, as a line under a spinner: the check [source] met most
/// lately since [since], while it's tried or wants a person; null otherwise.
String? checkLineText(
  SiteChecks checks,
  String? source,
  DateTime since,
  AppLocalizations l10n,
) {
  final check = checks.latestFor(source, since: since);
  if (check == null) return null;
  return checkText(checks, check, l10n);
}

/// [check] as a line: while it's tried (with its seconds), opening, or
/// wanting a person; null otherwise.
String? checkText(SiteChecks checks, SiteCheck check, AppLocalizations l10n) {
  final seconds = checks.now.difference(check.since).inSeconds;
  return switch (check.state) {
    CheckState.checking => l10n.checkLineChecking(check.site, seconds),
    CheckState.opening => l10n.checksOpening(check.site),
    CheckState.needsYou ||
    CheckState.stillNotCleared => l10n.checkLineNeedsYou(check.site),
    // What the person waiting can't fix by waiting: why it fails.
    CheckState.outdated =>
      !Clearance.instance.isReady || Clearance.instance.solver.engineUpdatable
          ? l10n.checkStateOutdated
          : l10n.checkStateTooOld,
    CheckState.ineffective => l10n.checkStateIneffective,
    CheckState.keepsAsking => l10n.checkStateKeepsAsking,
    _ => null,
  };
}

/// [checkLineText] for [source], counting the seconds while the check is
/// tried. Where the check sheet doesn't open by itself ([offerVerify]), it
/// has Verify; [onCleared] runs when a check it showed clears.
class CheckLine extends StatefulWidget {
  const CheckLine({
    super.key,
    required this.source,
    this.since,
    this.offerVerify = false,
    this.onCleared,
  });

  final String? source;

  /// Checks met since then are the wait it stands under. By default, a
  /// little before the line appeared: the request went out first.
  final DateTime? since;
  final bool offerVerify;
  final VoidCallback? onCleared;

  @override
  State<CheckLine> createState() => _CheckLineState();
}

class _CheckLineState extends State<CheckLine> {
  late final DateTime _appeared;
  StreamSubscription<void>? _changes;
  Timer? _tick;
  String? _shown;

  @override
  void initState() {
    super.initState();
    final clearance = Clearance.instance;
    // On the checks' clock, as their times are.
    final now = clearance.isReady ? clearance.checks.now : DateTime.now();
    _appeared = now.subtract(const Duration(seconds: 5));
    if (!clearance.isReady) return;
    _changes = clearance.checks.changes.listen((_) => _changed());
  }

  void _changed() {
    if (!mounted) return;
    final shown = _shown;
    if (shown != null &&
        Clearance.instance.checks[shown]?.state == CheckState.cleared) {
      _shown = null;
      widget.onCleared?.call();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _changes?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  DateTime get _since => widget.since ?? _appeared;

  @override
  Widget build(BuildContext context) {
    final clearance = Clearance.instance;
    if (!clearance.isReady) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final check = clearance.checks.latestFor(widget.source, since: _since);
    final text = checkLineText(clearance.checks, widget.source, _since, l10n);
    if (check?.pending ?? false) {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
    if (check == null || text == null) return const SizedBox.shrink();
    _shown = check.site;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        children: [
          Text(text, textAlign: TextAlign.center),
          if (widget.offerVerify && check.wantsPerson)
            FilledButton.tonal(
              onPressed: () => clearance.solver.verify(check.site),
              child: Text(l10n.clearanceVerify),
            ),
        ],
      ),
    );
  }
}

/// A line for every site [sources] met a check on since [since], while it's
/// tried or wants a person, each with Verify when it does: the checks of a
/// wait several extensions share (Nuvio's scrapers in the sources dialog, the
/// add-ons a sources sheet asked). [onCleared] gets each check it showed once
/// that clears.
class CheckLines extends StatefulWidget {
  const CheckLines({
    super.key,
    required this.sources,
    required this.since,
    this.onCleared,
  });

  final Set<String> sources;
  final DateTime since;
  final void Function(SiteCheck check)? onCleared;

  @override
  State<CheckLines> createState() => _CheckLinesState();
}

class _CheckLinesState extends State<CheckLines> {
  StreamSubscription<void>? _changes;
  Timer? _tick;

  /// Sites shown, whose clearing is told once.
  final Set<String> _shown = {};

  @override
  void initState() {
    super.initState();
    final clearance = Clearance.instance;
    if (!clearance.isReady) return;
    _changes = clearance.checks.changes.listen((_) => _changed());
  }

  void _changed() {
    if (!mounted) return;
    final checks = Clearance.instance.checks;
    for (final site in _shown.toList()) {
      final check = checks[site];
      if (check?.state == CheckState.cleared) {
        _shown.remove(site);
        widget.onCleared?.call(check!);
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _changes?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clearance = Clearance.instance;
    if (!clearance.isReady || widget.sources.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final checks = clearance.checks;
    final lines = [
      for (final check in checks.since(widget.since, sources: widget.sources))
        if (checkText(checks, check, l10n) case final text?) (check, text),
    ];
    if (lines.any((line) => line.$1.pending)) {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
    if (lines.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (check, text) in lines)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Builder(
              builder: (context) {
                _shown.add(check.site);
                return Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  children: [
                    Text(text, textAlign: TextAlign.center),
                    if (check.wantsPerson)
                      FilledButton.tonal(
                        onPressed: () => clearance.solver.verify(check.site),
                        child: Text(l10n.clearanceVerify),
                      ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}

/// Opens Android System WebView in the Play Store, or on its web page when
/// the store isn't there.
Future<void> openWebViewUpdate() async {
  const id = 'com.google.android.webview';
  try {
    if (await launchUrl(Uri.parse('market://details?id=$id'))) return;
  } catch (_) {
    // No store to handle it: the web page instead.
  }
  await launchUrl(
    Uri.parse('https://play.google.com/store/apps/details?id=$id'),
    mode: LaunchMode.externalApplication,
  );
}
