import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/network/dio_client_provider.dart';
import 'package:skystream/features/player/presentation/player_debug_flags.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_row.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/player/presentation/widgets/hotstar_player_style.dart';
import 'package:skystream/features/tracking/data/sync_manager.dart';
import 'package:skystream/features/tracking/data/tracking_service.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

/// Serves [pages], and records what was asked for; anything else is a 404.
class _Pages implements HttpClientAdapter {
  _Pages(this.pages);

  final Map<String, String> pages;
  final List<String> asked = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    asked.add(url);
    final page = pages[url];
    return page == null
        ? ResponseBody.fromString('Page Not Found', 404)
        : ResponseBody.fromString(page, 200);
  }

  @override
  void close({bool force = false}) {}
}

/// A live media playlist of [segment]-second segments: no end.
String _livePlaylist(int segment) =>
    '#EXTM3U\n#EXT-X-TARGETDURATION:$segment\n#EXT-X-MEDIA-SEQUENCE:400\n'
    '#EXTINF:$segment.0,\n400.ts\n#EXTINF:$segment.0,\n401.ts\n';

/// What the scrubber says on the real screen while the engine has not named a
/// length, and once it has.
///
/// The harness's default snapshot is `duration: 0, isSeekable: true`, which is
/// exactly what libVLC sends for the first beat of every VOD item - so until
/// this change every screen test was quietly rendering the LIVE pill over a
/// movie. The pill now needs a verdict: the app's, from the item and URL, or
/// the engine's, which arrives as `isLive: true` with `isSeekable: false`.
void main() {
  setUp(installEngineMocks);
  tearDown(removeEngineMocks);

  Future<AppLocalizations> english() =>
      AppLocalizations.delegate.load(const Locale('en'));

  testWidgets(
    'a movie with no length yet reads --:--, then the clock, then LIVE only '
    'when the engine says so',
    variant: texturePlatform,
    (tester) async {
      await pumpPlayer(
        tester,
        // A real length is what starts scrobbling, and the other screen
        // tests never send one; the tracker would otherwise read a sync
        // manager whose services are not stood up here.
        overrides: [
          syncManagerProvider.overrideWithValue(
            SyncManager(const <TrackingService>[]),
          ),
        ],
      );
      final l10n = await english();

      await sendFirstFrame(tester);
      expect(find.byType(VlcPlayerControls), findsOneWidget);
      expect(
        find.text(l10n.live),
        findsNothing,
        reason: 'a length that has not arrived is not a live verdict',
      );
      expect(find.text('0:01 / --:--'), findsOneWidget);

      await sendEvent(tester, snapshot(position: 1999, duration: 5400000));
      expect(find.text('0:01 / 1:30:00'), findsOneWidget);
      expect(find.text(l10n.live), findsNothing);

      await sendEvent(tester, <String, Object?>{
        ...snapshot(position: 2500),
        'isSeekable': false,
        'isLive': true,
      });
      expect(find.text(l10n.live), findsOneWidget);
      expect(find.textContaining('--:--'), findsNothing);

      // A playing controller holds the stall watchdog; leave it paused.
      await sendEvent(tester, snapshot(state: 'paused', position: 2500));
    },
  );

  // Spec section 8: seeking in a live window. The steps are pressed as keys:
  // in a widget test the screen lays out for the host, a desktop, which has
  // no step buttons, and every step - a button, Left and Right, a double tap -
  // goes through the same `_seekBy`.
  group('a live window', () {
    late FakeVlcEngine engine;

    setUp(() {
      engine = FakeVlcEngine();
      installEngineMocks(engine: engine);
    });

    MultimediaItem channel(String url) => MultimediaItem(
      title: 'Channel',
      url: url,
      posterUrl: '',
      provider: 'Remote',
      contentType: MultimediaContentType.livestream,
    );

    /// Live HLS 4,000 s into its own timeline, [fraction] of the way through
    /// a two-minute window.
    Map<String, Object?> inWindow(double fraction, {int position = 4000000}) =>
        <String, Object?>{
          ...snapshot(position: position, duration: 120000),
          'positionFraction': fraction,
        };

    List<double> fractionsSent() => <double>[
      for (final call in engine.callsTo('seekToFraction'))
        (call.arguments as Map<Object?, Object?>)['fraction']! as double,
    ];

    Future<void> stepBack(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
    }

    /// The screen on [item], its playlists served by [web].
    Future<void> playServed(
      WidgetTester tester,
      _Pages web,
      MultimediaItem item, {
      List<StreamResult>? preloadedStreams,
    }) => pumpPlayer(
      tester,
      item: item,
      videoUrl: item.url,
      preloadedStreams: preloadedStreams,
      isTv: false,
      overrides: [
        dioClientProvider.overrideWithValue(Dio()..httpClientAdapter = web),
      ],
    );

    /// LIVE, pressed as a viewer presses it: the fraction it sent.
    Future<double> goLive(WidgetTester tester) async {
      final l10n = await english();
      await revealPlayerControls(tester);
      await tester.pump();
      await tester.tap(find.byTooltip(l10n.playerGoLive));
      await tester.pump(VlcPlayerController.seekMergeWindow);
      return fractionsSent().last;
    }

    testWidgets(
      'a step moves in it, the clock says how far behind live, and LIVE goes '
      'back to the edge',
      variant: texturePlatform,
      (tester) async {
        const url = 'https://example.com/live/index.m3u8';
        await pumpPlayer(
          tester,
          item: channel(url),
          videoUrl: url,
          isTv: false,
        );
        final l10n = await english();
        await sendEvent(tester, inWindow(0.5));
        await revealPlayerControls(tester);
        // The bar publishes the place it shows on the frame after it is built.
        await tester.pump();

        // Half-way through 120 s: a minute behind the edge.
        expect(find.text('\u22121:00'), findsOneWidget);

        await stepBack(tester);
        expect(fractionsSent().last, closeTo(0.5 - 10 / 120, 1e-6));

        // The playlist can't be read here, so segments are taken as 10 s: the
        // edge is one segment before the window's end.
        // Straight after the step, so the controller merges it, and sends it
        // when the merge window closes.
        await tester.tap(find.byTooltip(l10n.playerGoLive));
        await tester.pump(VlcPlayerController.seekMergeWindow);
        expect(fractionsSent().last, closeTo(110 / 120, 1e-6));

        await sendEvent(tester, <String, Object?>{
          ...inWindow(0.92, position: 4050000),
          'state': 'paused',
        });
      },
    );

    testWidgets(
      'on a television, Left steps back in it',
      variant: texturePlatform,
      (tester) async {
        const url = 'https://example.com/live/index.m3u8';
        await pumpPlayer(tester, item: channel(url), videoUrl: url);
        await sendEvent(tester, inWindow(0.5));
        // The first picture raises the bars, and while they are up the arrows
        // move focus; once they hide, Left and Right seek, as on demand.
        await tester.pump(const Duration(seconds: 4));

        await stepBack(tester);

        expect(fractionsSent().single, closeTo(0.5 - 10 / 120, 1e-6));
        await sendEvent(tester, <String, Object?>{
          ...inWindow(0.42),
          'state': 'paused',
        });
      },
    );

    testWidgets(
      'a seek libVLC carries on without reopens the stream that far behind '
      'the edge',
      variant: texturePlatform,
      (tester) async {
        const url = 'https://example.com/live/index.m3u8';
        await pumpPlayer(
          tester,
          item: channel(url),
          videoUrl: url,
          isTv: false,
        );
        await sendEvent(tester, inWindow(0.5));
        final opens = engine.callsTo('setSource').length;

        await stepBack(tester);
        // The engine carries on from where it was: a dozen reports, the seek
        // once more, and a dozen again.
        var position = 4000000;
        for (var i = 0; i < 24; i++) {
          position += 400;
          await sendEvent(tester, inWindow(0.5, position: position));
        }
        await settle(tester);

        expect(engine.callsTo('setSource'), hasLength(opens + 1));
        final options =
            ((engine.callsTo('setSource').last.arguments
                        as Map<Object?, Object?>)['mediaOptions']!
                    as List<Object?>)
                .cast<String>();
        // 10 s back from half-way: 70 s behind the edge.
        expect(options, contains(':adaptive-livedelay=70000'));
        expect(
          (engine.callsTo('setSource').last.arguments
              as Map<Object?, Object?>)['keepPicture'],
          isTrue,
          reason: 'spec 8: the fallback reopens "keeping the picture"',
        );

        await sendEvent(tester, <String, Object?>{
          ...inWindow(0.4),
          'state': 'paused',
        });
      },
    );

    // Review Focus 4: a feed that reports no window keeps today's controls.
    testWidgets(
      'a feed with no window does not step, until one arrives',
      variant: texturePlatform,
      (tester) async {
        const url = 'https://example.com/live.ts';
        await pumpPlayer(
          tester,
          item: channel(url),
          videoUrl: url,
          isTv: false,
        );
        final l10n = await english();
        await sendEvent(tester, <String, Object?>{
          ...snapshot(position: 2500),
          'isSeekable': false,
          'isLive': true,
        });

        await stepBack(tester);
        expect(find.text(l10n.live), findsOneWidget);
        expect(engine.callsTo('seekToFraction'), isEmpty);
        expect(engine.callsTo('seekTo'), isEmpty);

        await sendEvent(tester, inWindow(0.5));
        await stepBack(tester);
        expect(fractionsSent(), hasLength(1));

        await sendEvent(tester, <String, Object?>{
          ...inWindow(0.42),
          'state': 'paused',
        });
      },
    );

    testWidgets(
      'one libVLC counts from where it was joined is placed as the window '
      'moves on',
      variant: texturePlatform,
      (tester) async {
        // libVLC 3.0.24 counts a live HLS stream's time from the join and its
        // window from the playlist it last read, so its fraction runs ahead of
        // the window as the window moves on. The screen says the media is
        // live, and the controller places it: ten seconds played while the
        // window moves on ten is the same place.
        const url = 'https://example.com/live/index.m3u8';
        final web = _Pages({url: _livePlaylist(4)});
        await playServed(tester, web, channel(url));
        Map<String, Object?> fromJoin(int position) => <String, Object?>{
          ...snapshot(position: position, duration: 24000),
          'positionFraction': position / 24000,
        };
        double place() => tester
            .widget<VlcPlayer>(find.byType(VlcPlayer, skipOffstage: false))
            .controller
            .value
            .positionFraction!;
        // Past the controller's event throttle, so each reading is out.
        const throttle = Duration(milliseconds: 500);

        await sendEvent(tester, fromJoin(12000));
        await tester.pump(throttle);
        final first = place();

        await tester.pump(const Duration(seconds: 10) - throttle);
        await sendEvent(tester, fromJoin(22000));
        await tester.pump(throttle);
        // Within a second of it: the harness's own frames take some time on
        // some platforms. libVLC's own fraction would read 0.92 here.
        expect(place(), closeTo(first, 0.05));

        await sendEvent(tester, <String, Object?>{
          ...fromJoin(22100),
          'state': 'paused',
        });
      },
    );

    testWidgets(
      'at its live delay behind the edge, the clock says LIVE',
      variant: texturePlatform,
      (tester) async {
        // Where libVLC starts a live stream: the live delay behind the edge,
        // rounded to a segment - 12 s here. That is live, not "-0:12".
        const url = 'https://example.com/live/index.m3u8';
        final web = _Pages({url: _livePlaylist(4)});
        await playServed(tester, web, channel(url));
        await sendEvent(tester, <String, Object?>{
          ...snapshot(position: 4000000, duration: 24000),
          'positionFraction': 0.48,
        });
        await settle(tester);
        await revealPlayerControls(tester);
        await tester.pump();

        expect(find.textContaining('\u2212'), findsNothing);
        expect(find.text('LIVE'), findsOneWidget);

        await sendEvent(tester, <String, Object?>{
          ...snapshot(position: 4000100, duration: 24000),
          'positionFraction': 0.48,
          'state': 'paused',
        });
      },
    );

    // The final review's third finding: with segments it has to assume, the
    // clock counts as live for a long way back, and the badge it shows there
    // must still go back to the edge.
    // The Android TV run of P1 Part 1: Right from play/pause reaches LIVE, but
    // the pill drew only InkWell's faint default overlay, where every other
    // player button draws the white ring, so a remote could not see it.
    testWidgets(
      'on a television, LIVE draws the remote\'s focus ring',
      variant: texturePlatform,
      (tester) async {
        final l10n = await english();
        const url = 'https://example.com/live/manifest.mpd';
        await pumpPlayer(tester, item: channel(url), videoUrl: url);
        await sendEvent(tester, inWindow(0.5));
        await revealPlayerControls(tester);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.sendKeyEvent(
          LogicalKeyboardKey.arrowRight,
          platform: 'android',
        );
        await tester.pump(const Duration(milliseconds: 400));

        final pill = find.descendant(
          of: find.byTooltip(l10n.playerGoLive),
          matching: find.byType(Container),
        );
        final border =
            (tester.widget<Container>(pill.first).decoration! as BoxDecoration)
                    .border!
                as Border;
        expect(border.top.color, HotstarPlayerStyle.focusRing);
        expect(border.top.width, HotstarPlayerStyle.focusRingWidth);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'whose segments are not known keeps LIVE a button',
      variant: texturePlatform,
      (tester) async {
        // DASH, or HLS whose playlist could not be read: 10 s segments are
        // assumed, so up to 38 s behind reads as live at an 8 s delay.
        final l10n = await english();
        const url = 'https://example.com/live/manifest.mpd';
        await pumpPlayer(
          tester,
          item: channel(url),
          videoUrl: url,
          isTv: false,
        );
        await sendEvent(tester, inWindow(1 - 20 / 120));
        await revealPlayerControls(tester);
        await tester.pump();
        expect(find.textContaining('\u2212'), findsNothing);

        await tester.tap(find.byTooltip(l10n.playerGoLive));
        await tester.pump(VlcPlayerController.seekMergeWindow);
        expect(fractionsSent(), isNotEmpty, reason: 'back to the edge');

        await sendEvent(tester, <String, Object?>{
          ...inWindow(0.92, position: 4050000),
          'state': 'paused',
        });
      },
    );

    testWidgets(
      'takes its segments from the playlist it opened',
      variant: texturePlatform,
      (tester) async {
        const url = 'https://example.com/live/index.m3u8';
        final web = _Pages({url: _livePlaylist(4)});
        await playServed(tester, web, channel(url));
        await sendEvent(tester, inWindow(0.5));
        await settle(tester);
        expect(web.asked, [url], reason: 'one read, shared with Quality');

        // Four-second segments: the edge is 4 s before the window's end.
        expect(await goLive(tester), closeTo(116 / 120, 1e-6));

        await sendEvent(tester, <String, Object?>{
          ...inWindow(0.97, position: 4050000),
          'state': 'paused',
        });
      },
    );

    testWidgets(
      "takes a master's segments from the first playlist it lists",
      variant: texturePlatform,
      (tester) async {
        const url = 'https://example.com/live/master.m3u8';
        const first = 'https://example.com/live/low/index.m3u8';
        final web = _Pages({
          url:
              '#EXTM3U\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n'
              'low/index.m3u8\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\n'
              'high/index.m3u8\n',
          first: _livePlaylist(6),
        });
        await playServed(tester, web, channel(url));
        await sendEvent(tester, inWindow(0.5));
        await settle(tester);
        expect(web.asked, [url, first]);

        expect(await goLive(tester), closeTo(114 / 120, 1e-6));

        await sendEvent(tester, <String, Object?>{
          ...inWindow(0.95, position: 4050000),
          'state': 'paused',
        });
      },
    );

    testWidgets(
      "another source does not keep the last one's segments",
      variant: texturePlatform,
      (tester) async {
        const alpha = 'https://example.com/live/alpha.m3u8';
        const beta = 'https://example.com/live/beta.m3u8';
        // Beta's playlist can't be read, so its segments are assumed.
        final web = _Pages({alpha: _livePlaylist(4)});
        final item = MultimediaItem(
          title: 'Channel',
          url: alpha,
          posterUrl: '',
          contentType: MultimediaContentType.livestream,
        );
        await playServed(
          tester,
          web,
          item,
          preloadedStreams: const [
            StreamResult(url: alpha, source: 'Alpha'),
            StreamResult(url: beta, source: 'Beta'),
          ],
        );
        await sendEvent(tester, inWindow(0.5));
        await settle(tester);
        expect(web.asked, [alpha]);

        final l10n = await english();
        await revealPlayerControls(tester);
        await tester.tap(find.byTooltip(l10n.options));
        await settle(tester);
        await tester.tap(find.text(l10n.sources));
        await settle(tester);
        await tester.tap(find.widgetWithText(PanelRow, 'Beta'));
        await settle(tester);
        expect(
          (engine.callsTo('setSource').last.arguments as Map)['uri'],
          beta,
        );

        await sendEvent(tester, inWindow(0.5, position: 5000000));
        await settle(tester);
        expect(web.asked, [alpha, beta]);
        expect(await goLive(tester), closeTo(110 / 120, 1e-6));

        await sendEvent(tester, <String, Object?>{
          ...inWindow(0.92, position: 5050000),
          'state': 'paused',
        });
      },
    );
  });

  // Spec 1.9: the live delay is picked by measurement, through this switch;
  // 7 s is none of the delays measured, so it can't be the shipped one.
  group('the live delay', () {
    late FakeVlcEngine engine;

    setUp(() {
      engine = FakeVlcEngine();
      installEngineMocks(engine: engine);
      addTearDown(
        () => PlayerDiagnostics.environment = const <String, String>{},
      );
    });

    testWidgets(
      'a measured one replaces the shipped one',
      variant: texturePlatform,
      (tester) async {
        PlayerDiagnostics.environment = const <String, String>{
          'SKYSTREAM_LIVE_DELAY_MS': '7000',
        };
        const url = 'https://example.com/live/index.m3u8';
        await pumpPlayer(
          tester,
          item: MultimediaItem(
            title: 'Channel',
            url: url,
            posterUrl: '',
            provider: 'Remote',
            contentType: MultimediaContentType.livestream,
          ),
          videoUrl: url,
        );
        await settle(tester);

        final options =
            ((engine.callsTo('setSource').last.arguments
                        as Map<Object?, Object?>)['mediaOptions']!
                    as List<Object?>)
                .cast<String>();
        expect(options.where((o) => o.contains('livedelay')), [
          ':adaptive-livedelay=7000',
        ]);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
