import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/device_info_provider.dart';
import '../../router/app_router.dart';
import 'clearance.dart';
import 'clearance_solver.dart';
import 'sheet_strings.dart';

/// Lets the clearance solver show a bot check to a person, in the check sheet
/// over whatever screen is open: a bottom sheet on phones, a dialog on
/// tablets and desktops, the whole screen on a TV.
class ClearanceBridge extends ConsumerStatefulWidget {
  const ClearanceBridge({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ClearanceBridge> createState() => _ClearanceBridgeState();
}

class _ClearanceBridgeState extends ConsumerState<ClearanceBridge> {
  @override
  void initState() {
    super.initState();
    final clearance = Clearance.instance;
    if (!clearance.isReady) return;
    clearance.solver.presenter = _present;
    ref.read(deviceProfileProvider.future).then(clearance.fitTo).ignore();
  }

  @override
  void dispose() {
    final clearance = Clearance.instance;
    if (clearance.isReady && clearance.solver.presenter == _present) {
      clearance.solver.presenter = null;
    }
    super.dispose();
  }

  Future<ChallengeSheetResult> _present({
    required CheckPage page,
    required String site,
    required Future<void> cleared,
  }) async {
    final browser = page.browser;
    final context = rootNavigatorKey.currentContext;
    if (browser == null || context == null || !context.mounted) {
      return ChallengeSheetResult.closed;
    }
    final tv = ref.read(deviceProfileProvider).value?.isTv ?? false;
    return showChallengeSheet(
      context,
      browser: browser,
      tv: tv,
      cleared: cleared,
      strings: checkSheetStrings(site),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
