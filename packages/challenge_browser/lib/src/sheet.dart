import 'dart:async';
import 'dart:math';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'browser.dart';
import 'events.dart';
import 'view.dart';

/// How a check sheet ended.
enum ChallengeSheetResult {
  /// The check cleared: `cleared` completed while the sheet showed.
  verified,

  /// The person said they were done.
  done,

  /// The person closed the sheet: Close, Escape, Back, or a tap outside it.
  closed,

  /// The person asked not to be shown this site's check by itself again
  /// ([ChallengeSheetStrings.quiet]).
  quiet,
}

/// The sheet's words, in the app's language.
@immutable
class ChallengeSheetStrings {
  const ChallengeSheetStrings({
    required this.note,
    required this.retry,
    required this.fullScreen,
    required this.exitFullScreen,
    required this.close,
    this.done,
    required this.verified,
    this.quiet,
    this.help,
  });

  /// One plain sentence under the address: what the site asks, and why.
  final String note;
  final String retry;
  final String fullScreen;
  final String exitFullScreen;
  final String close;

  /// The person's word that a check they finished cleared, for checks the app can't see clear. Null
  /// leaves the button out: a sign-in finishes by itself, when the page reaches its redirect.
  final String? done;

  /// Shown when the check clears, just before the sheet closes.
  final String verified;

  /// A button that closes the sheet with [ChallengeSheetResult.quiet]: the
  /// person doesn't want this site's check to open by itself again. Null
  /// leaves it out.
  final String? quiet;

  /// One line under [note] that helps with checks that keep showing.
  final String? help;
}

/// Shows [browser]'s page so a person can finish a check the hidden page couldn't: Cloudflare's
/// checkbox, a captcha. The sheet takes the shape that suits the screen: a bottom sheet on phones, a
/// compact dialog on tablets and desktops, the whole screen on a TV ([tv]), with its buttons above
/// the page there, a short D-pad press away.
///
/// Completes with [ChallengeSheetResult.verified] once [cleared] completes, after showing
/// [ChallengeSheetStrings.verified] for a moment. The page stays the caller's, loaded and running,
/// whatever the result.
Future<ChallengeSheetResult> showChallengeSheet(
  BuildContext context, {
  required ChallengeBrowser browser,
  required ChallengeSheetStrings strings,
  Future<void>? cleared,
  bool tv = false,
}) async {
  final shape = tv
      ? _Shape.tv
      : MediaQuery.sizeOf(context).shortestSide < 600
      ? _Shape.phone
      : _Shape.dialog;
  // In English whatever the app's language, Material's own words and direction too: nothing in it
  // needs translating.
  Widget sheet(BuildContext context) => Localizations.override(
    context: context,
    locale: const Locale('en'),
    child: _ChallengeSheet(browser: browser, strings: strings, cleared: cleared, shape: shape),
  );
  final result = shape == _Shape.phone
      ? await showModalBottomSheet<ChallengeSheetResult>(
          context: context,
          // Over the app's own bars, as a dialog is: the app's navigator, not the one of the tab that asked.
          useRootNavigator: true,
          isScrollControlled: true,
          useSafeArea: true,
          showDragHandle: true,
          // The page scrolls under the finger; the sheet moves by its handle alone.
          enableDrag: false,
          builder: sheet,
        )
      : await showDialog<ChallengeSheetResult>(context: context, builder: sheet);
  return result ?? ChallengeSheetResult.closed;
}

enum _Shape { phone, dialog, tv }

/// The phone sheet's least height, in logical pixels: the page keeps about 200 of them on a 360×640
/// phone, under the note and two lines of buttons.
const _phoneMinHeight = 460.0;

class _ChallengeSheet extends StatefulWidget {
  const _ChallengeSheet({required this.browser, required this.strings, required this.cleared, required this.shape});

  final ChallengeBrowser browser;
  final ChallengeSheetStrings strings;
  final Future<void>? cleared;
  final _Shape shape;

  @override
  State<_ChallengeSheet> createState() => _ChallengeSheetState();
}

class _ChallengeSheetState extends State<_ChallengeSheet> {
  StreamSubscription<BrowserEvent>? _events;
  Uri? _url;
  double _progress = 1;
  bool _fullScreen = false;
  bool _verified = false;

  @override
  void initState() {
    super.initState();
    _events = widget.browser.events.listen(_onEvent);
    unawaited(_locate());
    widget.cleared?.then((_) => _verify());
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  /// Where the page already is: it loaded before the sheet opened. An engine that doesn't answer
  /// ([ChallengeBrowser.evaluate]'s timeout), or answers what can't be read, leaves it to the page's
  /// next event.
  Future<void> _locate() async {
    final Object? href;
    try {
      href = jsonDecode(await widget.browser.evaluate('location.href'));
    } catch (_) {
      return;
    }
    if (href is! String) return;
    final url = Uri.tryParse(href);
    if (mounted && _url == null) setState(() => _url = url);
  }

  void _onEvent(BrowserEvent event) {
    switch (event) {
      case PageStarted(:final url):
        setState(() {
          _url = url;
          _progress = 0;
        });
      case PageProgress(:final value):
        setState(() => _progress = value);
      case PageFinished(:final url):
        setState(() {
          _url = url;
          _progress = 1;
        });
      default:
    }
  }

  Future<void> _verify() async {
    if (!mounted) return;
    setState(() => _verified = true);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted && ModalRoute.of(context)!.isCurrent) Navigator.pop(context, ChallengeSheetResult.verified);
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final theme = Theme.of(context);
    final tv = widget.shape == _Shape.tv;
    final url = _url;
    final others = <({String label, IconData? icon, VoidCallback onPressed})>[
      (label: strings.retry, icon: Icons.refresh, onPressed: () => widget.browser.evaluate('location.reload()')),
      if (!tv)
        (
          label: _fullScreen ? strings.exitFullScreen : strings.fullScreen,
          icon: _fullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
          onPressed: () => setState(() => _fullScreen = !_fullScreen),
        ),
      if (strings.quiet case final quiet?)
        (label: quiet, icon: null, onPressed: () => Navigator.pop(context, ChallengeSheetResult.quiet)),
    ];
    final ends = [
      TextButton(onPressed: () => Navigator.pop(context, ChallengeSheetResult.closed), child: Text(strings.close)),
      if (strings.done case final done?)
        FilledButton(onPressed: () => Navigator.pop(context, ChallengeSheetResult.done), child: Text(done)),
    ];
    final buttons = [
      for (final other in others)
        if (other.icon case final icon?)
          TextButton.icon(onPressed: other.onPressed, icon: Icon(icon), label: Text(other.label))
        else
          TextButton(onPressed: other.onPressed, child: Text(other.label)),
      ...ends,
    ];
    // A phone's sheet and the dialog are narrow: Close and Done stay in sight and the rest go under a
    // menu, as a column of buttons would leave the page no room.
    final compact = widget.shape == _Shape.phone || widget.shape == _Shape.dialog && !_fullScreen;
    final phone = widget.shape == _Shape.phone;
    final content = Padding(
      // A phone's sheet reaches the screen's bottom edge: its buttons stay above the system's navigation bar.
      padding: EdgeInsets.fromLTRB(16, phone ? 0 : 16, 16, 16 + (phone ? MediaQuery.paddingOf(context).bottom : 0)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // Like a browser's address bar: the site the check is for.
              Icon(url?.scheme == 'https' ? Icons.lock_outline : Icons.public, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(url?.host ?? '', style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
              ),
              if (tv) ...[
                const SizedBox(width: 16),
                ...buttons.expand((b) => [b, const SizedBox(width: 8)]),
              ],
            ],
          ),
          const SizedBox(height: 8),
          if (_verified)
            Row(
              children: [
                Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 18),
                const SizedBox(width: 8),
                Text(strings.verified, style: theme.textTheme.bodyMedium),
              ],
            )
          else
            Text(strings.note, style: theme.textTheme.bodyMedium),
          if (strings.help case final help? when !_verified) ...[
            const SizedBox(height: 4),
            Text(help, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 8),
          SizedBox(
            height: 4,
            child: _progress < 1 ? LinearProgressIndicator(value: _progress == 0 ? null : _progress) : null,
          ),
          const SizedBox(height: 8),
          Expanded(
            // A TV's D-pad, and a keyboard on a desktop, start inside the page. The D-pad goes through a
            // check's controls in order: its checkbox can't be reached by position.
            child: ChallengeBrowserView(
              browser: widget.browser,
              autofocus: widget.shape != _Shape.phone,
              dpadInTabOrder: true,
              // The page's drags are its own, ahead of a sheet or anything else around it: it scrolls.
              gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)},
            ),
          ),
          if (!tv) ...[
            const SizedBox(height: 8),
            if (compact)
              Row(
                children: [
                  PopupMenuButton<VoidCallback>(
                    onSelected: (action) => action(),
                    itemBuilder: (context) => [
                      for (final other in others)
                        PopupMenuItem(
                          value: other.onPressed,
                          child: ListTile(title: Text(other.label)),
                        ),
                    ],
                  ),
                  const Spacer(),
                  ...ends.expand((b) => [const SizedBox(width: 8), b]),
                ],
              )
            else
              OverflowBar(alignment: MainAxisAlignment.end, spacing: 8, children: buttons),
          ],
        ],
      ),
    );
    final height = MediaQuery.sizeOf(context).height;
    return switch (widget.shape) {
      // Six tenths of the screen, but room enough for a check on a small phone; above the keyboard, which
      // a sign-in's fields bring up, with the page taking what room is left.
      _Shape.phone => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SizedBox(
          height: _fullScreen ? height : (height * 0.6).clamp(min(_phoneMinHeight, height * 0.9), height),
          child: content,
        ),
      ),
      _Shape.dialog when !_fullScreen => Dialog(child: SizedBox(width: 480, height: 560, child: content)),
      _ => Dialog.fullscreen(child: content),
    };
  }
}
