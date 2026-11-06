import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../cloudstream/presentation/cloudstream_badge.dart';
import '../search_sources.dart';

/// Names the system a search section comes from, with the icon its settings
/// page uses. CloudStream's is the badge its providers carry everywhere.
class SearchSourceTag extends StatelessWidget {
  const SearchSourceTag(this.kind, {super.key});

  final SearchSourceKind kind;

  @override
  Widget build(BuildContext context) {
    if (kind == SearchSourceKind.cloudstream) return const CloudStreamBadge();
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final (icon, label, background, foreground) = switch (kind) {
      SearchSourceKind.stremio => (
        Icons.dashboard_customize_rounded,
        l10n.searchTagStremio,
        cs.secondaryContainer,
        cs.onSecondaryContainer,
      ),
      SearchSourceKind.nuvio => (
        Icons.hub_rounded,
        l10n.searchTagNuvio,
        cs.primaryContainer,
        cs.onPrimaryContainer,
      ),
      _ => (
        Icons.extension_rounded,
        l10n.searchTagSkyStream,
        cs.surfaceContainerHighest,
        cs.onSurfaceVariant,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: foreground),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
