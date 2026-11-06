import 'dart:async';

import 'package:flutter/material.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import '../../../../core/extensions/base_provider.dart';
import '../../../../core/network/clearance/clearance.dart';
import '../../../../core/network/clearance/site_checks.dart';
import '../../../../shared/widgets/check_line.dart';

/// The bot checks a search met, above its results: one line that sums them
/// up, and a row per site when opened, with Verify where a person is needed.
/// Search and Explore's extensions rail show it; it hides while the search
/// has met none. A search never opens the check sheet by itself.
class CheckSection extends StatefulWidget {
  const CheckSection({
    super.key,
    required this.since,
    required this.providers,
    this.rerunning = const {},
    this.focusNode,
  });

  /// When the search began: checks met before belong to another.
  final DateTime since;

  /// The search's extensions: they pick which checks show, and name them.
  final List<SkyStreamProvider> providers;

  /// Extensions searching again after their site cleared.
  final Set<String> rerunning;

  /// For the section's first control, so a television's D-pad can reach it.
  final FocusNode? focusNode;

  @override
  State<CheckSection> createState() => _CheckSectionState();
}

class _CheckSectionState extends State<CheckSection> {
  StreamSubscription<void>? _changes;
  Timer? _tick;
  bool _open = false;
  bool _walking = false;

  @override
  void initState() {
    super.initState();
    final clearance = Clearance.instance;
    if (!clearance.isReady) return;
    _changes = clearance.checks.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  Set<String> get _sources => {
    for (final p in widget.providers) ?p.checkSource,
    if (widget.providers.any((p) => p.checkSource?.startsWith('cs3:') ?? false))
      'cs3',
  };

  List<SiteCheck> _checks() {
    final clearance = Clearance.instance;
    if (!clearance.isReady) return const [];
    return clearance.checks.since(widget.since, sources: _sources);
  }

  /// Seconds tick on screen while anything is under way.
  void _keepTicking(List<SiteCheck> checks) {
    final pending = checks.any((c) => c.pending);
    if (pending && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!pending) {
      _tick?.cancel();
      _tick = null;
    }
  }

  Future<void> _verify(String site) => Clearance.instance.solver.verify(site);

  /// Whether [site]'s check doesn't open the sheet by itself (the person's
  /// choice in the sheet).
  bool _quiet(String site) => Clearance.instance.store.isQuiet(site);

  /// Every site that needs a person, one after another. A closed sheet moves
  /// on to the next.
  Future<void> _verifyAll(List<SiteCheck> checks) async {
    setState(() => _walking = true);
    try {
      for (final check in checks.where((c) => c.wantsPerson)) {
        if (!mounted) return;
        try {
          await _verify(check.site);
        } catch (_) {
          // That site's check couldn't be shown: on to the next.
        }
      }
    } finally {
      if (mounted) setState(() => _walking = false);
    }
  }

  String _names(SiteCheck check, AppLocalizations l10n) => {
    for (final p in widget.providers)
      if (check.sources.contains(p.checkSource)) p.name,
    if (check.sources.contains('cs3')) l10n.checkCloudStreamExtension,
  }.join(', ');

  bool _searchingAgain(SiteCheck check) => widget.providers.any(
    (p) =>
        widget.rerunning.contains(p.packageName) && check.metBy(p.checkSource),
  );

  String _summary(List<SiteCheck> checks, AppLocalizations l10n) {
    final opening = checks
        .where((c) => c.state == CheckState.opening)
        .firstOrNull;
    if (opening != null) return l10n.checksOpening(opening.site);
    final checking = checks.where((c) => c.state == CheckState.checking).length;
    if (checking == checks.length) return l10n.checksCheckingAll(checking);
    final wanting = checks.where((c) => c.wantsPerson).length;
    final cleared = checks.where((c) => c.state == CheckState.cleared).length;
    final failed = checks.length - checking - wanting - cleared;
    return [
      if (wanting > 0) l10n.checksNeedYou(wanting),
      if (cleared > 0) l10n.checksCleared(cleared),
      if (checking > 0) l10n.checksChecking(checking),
      if (failed > 0) l10n.checksFailed(failed),
    ].join(' · ');
  }

  String _state(SiteCheck check, AppLocalizations l10n, DateTime now) {
    if (check.state == CheckState.cleared && _searchingAgain(check)) {
      return l10n.checkStateSearchingAgain;
    }
    final seconds = now.difference(check.since).inSeconds;
    return switch (check.state) {
      CheckState.checking => l10n.checkStateChecking(seconds),
      CheckState.needsYou => l10n.checkStateNeedsYou,
      CheckState.opening => l10n.checkStateOpening(seconds),
      CheckState.cleared => l10n.checkStateCleared,
      CheckState.unreachable => l10n.checkStateUnreachable,
      CheckState.blocked => l10n.checkStateBlocked,
      CheckState.sentElsewhere => l10n.checkStateSentElsewhere(
        check.elsewhere ?? '',
      ),
      CheckState.stillNotCleared => l10n.checkStateStillNotCleared,
      CheckState.outdated =>
        Clearance.instance.solver.engineUpdatable
            ? l10n.checkStateOutdated
            : l10n.checkStateTooOld,
      CheckState.ineffective => l10n.checkStateIneffective,
      CheckState.keepsAsking => l10n.checkStateKeepsAsking,
    };
  }

  @override
  Widget build(BuildContext context) {
    final checks = _checks();
    _keepTicking(checks);
    if (checks.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final now = Clearance.instance.checks.now;
    final wanting = checks.where((c) => c.wantsPerson).length;
    final text = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSecondaryContainer,
    );
    final small = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSecondaryContainer,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
              child: Row(
                children: [
                  if (checks.any((c) => c.pending))
                    const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      Icons.verified_user_outlined,
                      color: colors.onSecondaryContainer,
                    ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_summary(checks, l10n), style: text)),
                  if (wanting > 0)
                    FilledButton.tonal(
                      onPressed: _walking ? null : () => _verifyAll(checks),
                      child: Text(
                        wanting == 1
                            ? l10n.clearanceVerify
                            : l10n.checksVerifyAll,
                      ),
                    ),
                  IconButton(
                    focusNode: widget.focusNode,
                    tooltip: _open ? l10n.checksHide : l10n.checksShow,
                    onPressed: () => setState(() => _open = !_open),
                    icon: Icon(_open ? Icons.expand_less : Icons.expand_more),
                  ),
                ],
              ),
            ),
            // The rows scroll in at most part of the screen, so a search that
            // met many checks keeps room for its results.
            if (_open)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.4,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final check in checks)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      check.movedFrom == null
                                          ? check.site
                                          : '${check.site} · ${l10n.checkMovedFrom(check.movedFrom!)}',
                                      style: text?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(_names(check, l10n), style: small),
                                    Text(
                                      _state(check, l10n, now),
                                      style: small,
                                    ),
                                    if (_quiet(check.site))
                                      Text(l10n.checkQuietNote, style: small),
                                  ],
                                ),
                              ),
                              if (check.state == CheckState.outdated &&
                                  Clearance.instance.solver.engineUpdatable)
                                TextButton(
                                  onPressed: openWebViewUpdate,
                                  child: Text(l10n.checkUpdateWebView),
                                ),
                              if (_quiet(check.site))
                                TextButton(
                                  onPressed: () => setState(
                                    () => Clearance.instance.store.setQuiet(
                                      check.site,
                                      false,
                                    ),
                                  ),
                                  child: Text(l10n.checkAskAgain),
                                ),
                              if (check.wantsPerson)
                                TextButton(
                                  onPressed: _walking
                                      ? null
                                      : () => _verify(check.site),
                                  child: Text(l10n.clearanceVerify),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
