import 'package:flutter/material.dart';

import '../../../core/cloudstream/cloudstream_provider.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Marks a provider that comes from a CloudStream extension.
class CloudStreamBadge extends StatelessWidget {
  const CloudStreamBadge({super.key});

  /// Whether a provider id (as stored on items) is a CloudStream one.
  static bool isCloudStream(String? providerId) => CloudStreamProvider.isCloudStreamId(providerId);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_rounded, size: 11, color: cs.onTertiaryContainer),
          const SizedBox(width: 3),
          Text(
            AppLocalizations.of(context)!.cloudStream,
            style: TextStyle(fontSize: 10, color: cs.onTertiaryContainer, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
