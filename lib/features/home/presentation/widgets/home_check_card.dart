import 'dart:async';

import 'package:flutter/material.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import '../../../../core/extensions/base_provider.dart';
import '../../../../core/network/clearance/clearance.dart';
import '../../../../core/network/clearance/site_checks.dart';
import '../../../../shared/widgets/check_line.dart';

/// Home's one site: while its bot check is tried, or wants a person, or ended
/// badly, the card shows in place of [child] (the wait, or the error). The
/// check Home's plugin met most lately since [since], its fetch's start.
class HomeCheckGate extends StatefulWidget {
  const HomeCheckGate({
    super.key,
    required this.provider,
    required this.since,
    required this.onRetry,
    required this.child,
  });

  final SkyStreamProvider? provider;
  final DateTime? since;
  final VoidCallback onRetry;
  final Widget child;

  @override
  State<HomeCheckGate> createState() => _HomeCheckGateState();
}

class _HomeCheckGateState extends State<HomeCheckGate> {
  StreamSubscription<void>? _changes;
  Timer? _tick;

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

  SiteCheck? _check() {
    final clearance = Clearance.instance;
    final since = widget.since;
    if (!clearance.isReady || since == null) return null;
    final check = clearance.checks.latestFor(
      widget.provider?.checkSource,
      since: since,
    );
    return check == null || check.state == CheckState.cleared ? null : check;
  }

  @override
  Widget build(BuildContext context) {
    final check = _check();
    if (check?.pending ?? false) {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
    if (check == null) return widget.child;
    return Center(
      child: HomeCheckCard(
        check: check,
        plugin: widget.provider?.name ?? '',
        onRetry: widget.onRetry,
      ),
    );
  }
}

/// One site's check on Home: being tried, wanting a person, or why it
/// couldn't be cleared.
class HomeCheckCard extends StatelessWidget {
  const HomeCheckCard({
    super.key,
    required this.check,
    required this.plugin,
    required this.onRetry,
  });

  final SiteCheck check;
  final String plugin;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final seconds = Clearance.instance.checks.now
        .difference(check.since)
        .inSeconds;
    final (title, detail) = switch (check.state) {
      CheckState.checking => (
        l10n.checkLineChecking(check.site, seconds),
        plugin,
      ),
      CheckState.opening => (l10n.checksOpening(check.site), plugin),
      CheckState.needsYou || CheckState.stillNotCleared => (
        l10n.checkLineNeedsYou(check.site),
        plugin,
      ),
      CheckState.unreachable => (check.site, l10n.checkStateUnreachable),
      CheckState.blocked => (check.site, l10n.checkStateBlocked),
      CheckState.sentElsewhere => (
        check.site,
        l10n.checkStateSentElsewhere(check.elsewhere ?? ''),
      ),
      CheckState.cleared => (check.site, l10n.checkStateCleared),
      CheckState.outdated => (
        check.site,
        Clearance.instance.solver.engineUpdatable
            ? l10n.checkStateOutdated
            : l10n.checkStateTooOld,
      ),
      CheckState.ineffective => (check.site, l10n.checkStateIneffective),
      CheckState.keepsAsking => (check.site, l10n.checkStateKeepsAsking),
    };
    return Card(
      margin: const EdgeInsets.all(24),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              if (check.pending)
                const LinearProgressIndicator()
              else if (check.wantsPerson)
                FilledButton(
                  onPressed: () => Clearance.instance.solver.verify(check.site),
                  child: Text(l10n.clearanceVerify),
                )
              else if (check.state == CheckState.outdated &&
                  Clearance.instance.solver.engineUpdatable)
                FilledButton(
                  onPressed: openWebViewUpdate,
                  child: Text(l10n.checkUpdateWebView),
                )
              else
                FilledButton.tonal(onPressed: onRetry, child: Text(l10n.retry)),
            ],
          ),
        ),
      ),
    );
  }
}
