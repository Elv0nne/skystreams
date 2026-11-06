import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/generated/app_localizations.dart';
import '../services/notification_service.dart';
import 'extension_ui/extension_pages.dart';

enum ExtensionNoticeKind { toast, copy, link }

/// What an extension asked the system for that the app shows itself: a toast, text for the clipboard, a
/// link. Only the engine on the desktops and iOS sends these; Android shows its own.
class ExtensionNotice {
  const ExtensionNotice(this.kind, this.plugin, this.text, {this.inScreen = false});

  final ExtensionNoticeKind kind;

  /// The extension's name, the toast's title.
  final String plugin;

  /// The toast's words, the text to copy, or the link.
  final String text;

  /// Whether the extension had its screen open: the person is in it, so its link opens at once.
  final bool inScreen;
}

/// Shows [notice]:
/// - a toast as the extension's;
/// - a copy put on the clipboard, and a toast says so;
/// - a link opened while the extension's screen is open, as Android would; at other times a toast offers
///   it, since an extension in the background doesn't open the browser by itself.
Future<void> showExtensionNotice(
  ExtensionNotice notice, {
  required AppLocalizations l10n,
  required NotificationService notifications,
  Future<void> Function(String text) copy = _copy,
  Future<bool> Function(Uri url) open = _open,
  Future<bool> Function(String text) inPage = _inPage,
}) async {
  switch (notice.kind) {
    case ExtensionNoticeKind.toast:
      // Over an extension's full-screen page it shows in that page: nothing of the app's shows over a page that is a
      // window of its own (Windows, Linux), and the app's toasts stand down over the player (Phase 7c).
      if (await inPage(notice.text)) return;
      notifications.showExtension(notice.text, title: notice.plugin);
    case ExtensionNoticeKind.copy:
      await copy(notice.text);
      notifications.showExtension(l10n.extensionCopied, title: notice.plugin);
    case ExtensionNoticeKind.link:
      final url = Uri.tryParse(notice.text);
      if (url == null || !url.hasScheme) return;
      if (notice.inScreen) {
        await open(url);
        return;
      }
      notifications.showToast(
        title: notice.plugin,
        message: notice.text,
        type: ToastType.extension,
        icon: Icons.open_in_new_rounded,
        actionLabel: l10n.extensionOpenLink,
        onAction: () => unawaited(open(url)),
      );
  }
}

Future<void> _copy(String text) => Clipboard.setData(ClipboardData(text: text));

Future<bool> _inPage(String text) => ExtensionPages.shared.toast(text);

Future<bool> _open(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);
