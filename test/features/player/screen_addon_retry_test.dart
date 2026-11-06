/// Retry in the player, for a title a Stremio add-on plays (Stremio direct
/// play): by then every link the page handed over has failed, and links from
/// a page left open for a while may have expired, so the add-on is asked
/// again instead of the same links being tried again.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/data/addon_stream_service.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/core/addons/models/addon_stream_source.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import '../addons/stremio_page_fakes.dart'
    show BridgeRepo, FakeStreamService, kBridgeUrl;
import 'vlc_screen_harness.dart';

void main() {
  setUp(installEngineMocks);
  tearDown(removeEngineMocks);

  const fresh = AddonStreamSource(
    addonId: 'com.bridge',
    addonName: 'Bridge',
    url: 'https://cdn.test/fresh.m3u8',
    name: 'Auto',
  );

  final film = MultimediaItem(
    title: 'Spider-Man',
    url: 'cnc:film',
    posterUrl: '',
    provider: 'Bridge',
    source: kAddonItemSource,
    addonUrl: kBridgeUrl,
    addonType: 'other',
  );

  testWidgets(
    'Retry asks the add-on again rather than the links that failed',
    variant: texturePlatform,
    (tester) async {
      final service = FakeStreamService(const [fresh]);
      await pumpPlayer(
        tester,
        item: film,
        videoUrl: film.url,
        preloadedStreams: const [
          StreamResult(url: 'https://cdn.test/old.m3u8', source: 'Auto'),
        ],
        overrides: [
          addonRepositoryProvider.overrideWith(BridgeRepo.new),
          addonStreamServiceProvider.overrideWithValue(service),
        ],
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      // The handed-over link dies before it ever plays: the one source there
      // is, so the screen runs out and offers Retry.
      await sendEvent(tester, snapshot(state: 'ended'));
      await settle(tester);
      expect(find.text(l10n.retry), findsOneWidget);
      expect(service.asked, isEmpty);

      await tester.tap(find.text(l10n.retry));
      await settle(tester);

      expect(service.asked, hasLength(1));
      expect(service.asked.single.request.contentId, 'cnc:film');
      expect(service.asked.single.personWaiting, isTrue);

      await tester.pumpWidget(const SizedBox());
    },
  );
}
