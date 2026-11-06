import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/cloudstream/cloudstream_repository.dart';
import '../../../../core/cloudstream/extension_ui/extension_ui_session.dart';
import '../../../../core/cloudstream/extension_ui/ui_tree.dart';
import '../../../../l10n/generated/app_localizations.dart';
import 'extension_full_screen.dart';
import 'extension_page_view.dart';
import 'ui_node_view.dart';

/// Shows [session] until the extension's last window closes. Its bottom window is SkyStream's bottom
/// sheet (phones), a dialog (tablets and desktops) or the full screen (TVs); a window above it shows as
/// a dialog on top. Back, a swipe or the close button close the top window.
Future<void> showExtensionSheet(
  BuildContext context, {
  required ExtensionUiSession session,
  required String title,
  required bool tv,
  FullScreenDevice? device,
}) {
  final body = ExtensionSheet(session: session, title: title, device: device);
  if (tv) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog.fullscreen(child: body),
    );
  }
  final size = MediaQuery.sizeOf(context);
  if (size.shortestSide < 600) {
    return showModalBottomSheet<void>(
      context: context,
      // Over the whole app: the shell's own navigator would leave its navigation bar on top of the sheet.
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      // The sheet goes when the engine says the screen has: a drag on its header closes the top window
      // instead (as Back does).
      enableDrag: false,
      constraints: BoxConstraints(maxHeight: size.height * 0.9),
      builder: (_) => body,
    );
  }
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog(
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640), child: body),
    ),
  );
}

/// The sheet's content: the extension's windows as they change, until they're gone.
class ExtensionSheet extends StatefulWidget {
  const ExtensionSheet({super.key, required this.session, required this.title, this.device});

  final ExtensionUiSession session;
  final String title;

  /// What a full-screen window above the sheet's own asks of the device: [SystemFullScreenDevice] unless a test says.
  final FullScreenDevice? device;

  @override
  State<ExtensionSheet> createState() => _ExtensionSheetState();
}

class _ExtensionSheetState extends State<ExtensionSheet> {
  /// A downward fling on the header faster than this closes the top window.
  static const _swipeVelocity = 300.0;

  /// The least height the sheet's body takes while a window is on top, so that window isn't cut off.
  static const _roomForTop = 420.0;

  static bool _holdsPage(UiNode node) => node.kind == UiKind.page || node.children.any(_holdsPage);

  var _leaving = false;

  /// What had the focus before a window came on top: it gets it back once that window goes.
  FocusNode? _focusBeforeTop;
  var _hadTop = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
    // Ended before the sheet was first built (a screen the engine opened while the app drew no frames), or a window
    // that asks for the whole screen already there (Phase 7c): no change will come, so it acts now.
    if (widget.session.closed || widget.session.windows.any((window) => window.fullScreen)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    super.dispose();
  }

  /// The sheet's own windows: those below the first that asks for the whole screen, which shows over the sheet in the
  /// full-screen view (Phase 7c's §2).
  List<UiWindow> get _own {
    final windows = widget.session.windows;
    final first = windows.indexWhere((window) => window.fullScreen);
    return first < 0 ? windows : windows.sublist(0, first);
  }

  void _changed() {
    if (!mounted) return;
    final session = widget.session;
    // Its bottom window asks for the whole screen: the screen goes on in the full-screen view (showExtensionScreen).
    if (!session.closed && session.windows.isNotEmpty && session.windows.first.fullScreen) {
      if (!_leaving) {
        setState(() => _leaving = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final route = mounted ? ModalRoute.of(context) : null;
          if (route != null && route.isActive) Navigator.of(context).removeRoute(route);
        });
      }
      return;
    }
    // One above its own asks for it: the full-screen view shows it over the sheet, which keeps its own.
    if (!session.closed && session.windows.any((window) => window.fullScreen)) {
      unawaited(showExtensionFullScreen(context, session: session, title: widget.title, device: widget.device));
    }
    final hasTop = _own.length > 1;
    if (hasTop && !_hadTop) _focusBeforeTop = FocusManager.instance.primaryFocus;
    if (!hasTop && _hadTop) {
      final before = _focusBeforeTop;
      _focusBeforeTop = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && before != null && before.context != null) before.requestFocus();
      });
    }
    _hadTop = hasTop;
    if (widget.session.closed && !_leaving) {
      setState(() => _leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final route = mounted ? ModalRoute.of(context) : null;
        if (route == null || !route.isActive) return;
        // Whatever is over the sheet (its More menu) goes first.
        Navigator.of(context)
          ..popUntil((r) => r == route)
          ..pop();
      });
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final l10n = AppLocalizations.of(context)!;
    final windows = _own;
    final bottom = windows.isEmpty ? null : windows.first;
    final top = windows.length > 1 ? windows.last : null;
    return PopScope(
      canPop: _leaving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(session.close());
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Above any window on top, so Force close stays in reach. A swipe down on it closes the top
          // window, as Back does.
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) > _swipeVelocity) unawaited(session.close());
            },
            child: _Header(
              title: bottom?.title ?? widget.title,
              closable: top == null && (bottom?.cancelable ?? true),
              session: session,
            ),
          ),
          if (session.error case final error?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                l10n.extensionSheetError(CloudStreamRepository.errorMessage(error)),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Flexible(
            child: ConstrainedBox(
              // A window on top holding a page takes all the sheet has: its buttons stay in view below the page.
              constraints: BoxConstraints(
                minHeight: top == null
                    ? 0
                    : _holdsPage(top.root)
                    ? MediaQuery.sizeOf(context).height
                    : _roomForTop,
              ),
              child: Stack(
                children: [
                  // Behind a window on top nothing takes the focus: the remote acts on that window.
                  ExcludeFocus(
                    excluding: top != null,
                    child: bottom == null
                        ? const Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        : LayoutBuilder(
                            builder: (context, constraints) => ExtensionPageRoom(
                              height: constraints.maxHeight,
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                child: FocusTraversalGroup(
                                  policy: ReadingOrderTraversalPolicy(),
                                  child: UiNodeView(node: bottom.root, session: session),
                                ),
                              ),
                            ),
                          ),
                  ),
                  // Every window over the first, in order: the topmost alone takes taps and the focus.
                  for (final window in windows.skip(1))
                    _TopWindow(key: ValueKey(window.id), window: window, session: session, active: window == top),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.closable, required this.session});

  final String title;
  final bool closable;
  final ExtensionUiSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (closable)
            IconButton(
              tooltip: l10n.extensionSheetClose,
              icon: const Icon(Icons.close_rounded),
              onPressed: () => unawaited(session.close()),
            ),
          PopupMenuButton<void>(
            tooltip: l10n.extensionSheetMore,
            itemBuilder: (_) => [
              PopupMenuItem<void>(
                onTap: () => unawaited(session.close(force: true)),
                child: Text(l10n.extensionSheetForceClose),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A second window (an alert, a sub-dialog), over the sheet: the only one the person can use. Its first
/// control takes the focus, so a remote or keyboard acts on it at once.
class _TopWindow extends StatefulWidget {
  const _TopWindow({super.key, required this.window, required this.session, this.active = true});

  final UiWindow window;
  final ExtensionUiSession session;

  /// Whether it's the topmost: a window under another shows, but takes neither taps nor the focus.
  final bool active;

  @override
  State<_TopWindow> createState() => _TopWindowState();
}

class _TopWindowState extends State<_TopWindow> {
  final _content = FocusScopeNode(debugLabel: 'extension window on top');

  @override
  void initState() {
    super.initState();
    if (widget.active) _focusFirst();
  }

  @override
  void didUpdateWidget(_TopWindow old) {
    super.didUpdateWidget(old);
    // The window over it closed: it's on top now.
    if (widget.active && !old.active) _focusFirst();
  }

  void _focusFirst() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      final first = ReadingOrderTraversalPolicy().sortDescendants(_content.traversalDescendants, _content).firstOrNull;
      (first ?? _content).requestFocus();
    });
  }

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final window = widget.window;
    final session = widget.session;
    final l10n = AppLocalizations.of(context)!;
    return Positioned.fill(
      child: Stack(
        children: [
          const ModalBarrier(dismissible: false, color: Colors.black54),
          ExcludeFocus(
            excluding: !widget.active,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Card(
                  margin: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (window.cancelable)
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: IconButton(
                            tooltip: l10n.extensionSheetClose,
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => unawaited(session.act(window.root.id, 'close')),
                          ),
                        ),
                      Flexible(
                        child: LayoutBuilder(
                          builder: (context, constraints) => ExtensionPageRoom(
                            height: constraints.maxHeight,
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                              child: FocusScope(
                                node: _content,
                                child: FocusTraversalGroup(
                                  policy: ReadingOrderTraversalPolicy(),
                                  child: UiNodeView(node: window.root, session: session),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
