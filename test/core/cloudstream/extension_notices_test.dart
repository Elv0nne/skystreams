/// How an extension's toast, copy or link shows: the engine leaves them to the app on the desktops and iOS.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/extension_notices.dart';
import 'package:skystream/core/services/notification_service.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

void main() {
  // The service's toasts and snackbars reach the app through the widget binding.
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = lookupAppLocalizations(const Locale('en'));
  late NotificationService notifications;

  setUp(() {
    notifications = NotificationService();
    addTearDown(notifications.clearSnackBars);
  });

  test('a toast shows as its extension\'s', () async {
    await showExtensionNotice(
      const ExtensionNotice(ExtensionNoticeKind.toast, 'Test', 'Saved'),
      l10n: l10n,
      notifications: notifications,
    );
    final toast = notifications.toasts.single;
    expect((toast.title, toast.message, toast.type), ('Test', 'Saved', ToastType.extension));
  });

  test('a copy goes on the clipboard, and a toast says so', () async {
    final copied = <String>[];
    await showExtensionNotice(
      const ExtensionNotice(ExtensionNoticeKind.copy, 'Test', 'abc'),
      l10n: l10n,
      notifications: notifications,
      copy: (text) async => copied.add(text),
    );
    expect(copied, ['abc']);
    expect((notifications.toasts.single.title, notifications.toasts.single.message), ('Test', 'Copied'));
  });

  test("a link opens while its extension's screen is open, and is offered otherwise", () async {
    final opened = <Uri>[];
    Future<bool> open(Uri url) async {
      opened.add(url);
      return true;
    }

    await showExtensionNotice(
      const ExtensionNotice(ExtensionNoticeKind.link, 'Test', 'https://example.com', inScreen: true),
      l10n: l10n,
      notifications: notifications,
      open: open,
    );
    expect(opened, [Uri.parse('https://example.com')]);
    expect(notifications.toasts, isEmpty);

    await showExtensionNotice(
      const ExtensionNotice(ExtensionNoticeKind.link, 'Test', 'https://example.com/b'),
      l10n: l10n,
      notifications: notifications,
      open: open,
    );
    expect(opened, hasLength(1), reason: 'an extension in the background opens no browser by itself');
    final offer = notifications.toasts.single;
    expect((offer.message, offer.actionLabel), ('https://example.com/b', 'Open link'));
    offer.onAction!();
    await Future<void>.delayed(Duration.zero);
    expect(opened.last, Uri.parse('https://example.com/b'));
  });

  test("a toast while an extension's full-screen page shows goes in that page, as Android's shows over it", () async {
    // Phase 7c: a game's "Press back again to save & exit". The app's own toast would sit under a desktop's native page,
    // and stands down over the player.
    final inPage = <String>[];
    await showExtensionNotice(
      const ExtensionNotice(ExtensionNoticeKind.toast, 'Pokemon', 'Press back again to save & exit'),
      l10n: l10n,
      notifications: notifications,
      inPage: (text) async {
        inPage.add(text);
        return true;
      },
    );
    expect(inPage, ['Press back again to save & exit']);
    expect(notifications.toasts, isEmpty);
  });
}
