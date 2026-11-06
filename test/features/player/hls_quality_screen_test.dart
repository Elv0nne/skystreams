/// Choosing an HLS stream's quality on the real screen over a mocked engine:
/// Auto's cap from the quality preference, then the Quality tab's ladder and
/// a pick.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/network/dio_client_provider.dart';
import 'package:skystream/core/services/download_service.dart';
import 'package:skystream/core/services/local_proxy_service.dart';
import 'package:skystream/features/player/domain/media_options.dart'
    show kLiveDelayMs;
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_row.dart';
import 'package:skystream/features/player/presentation/vlc/source_check_provider.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_screen.dart'
    show openingOverlayKey;
import 'package:skystream/features/player/presentation/widgets/player_stream_widgets.dart'
    show PlayerBufferingIndicator;
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart' show VlcPlayerController;

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

const String _master = 'https://cdn.test/show/master.m3u8';

/// Three heights, audio in each.
const String _threeHeights =
    '#EXTM3U\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080\nfhd.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\nhd.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=848x480\nsd.m3u8\n';

/// Serves [pages] and records what was asked for; anything else is a 404.
/// A URL in [gates] is answered once its gate completes.
class _Playlists implements HttpClientAdapter {
  _Playlists(this.pages);

  final Map<String, String> pages;
  final Map<String, Completer<void>> gates = <String, Completer<void>>{};
  final List<String> asked = <String>[];

  /// Films, by how many 64 KB chunks each has to give, and how many of them
  /// were read.
  final Map<String, int> films = <String, int>{};
  final Map<String, int> chunksRead = <String, int>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    asked.add(url);
    await gates[url]?.future;
    final chunks = films[url];
    if (chunks != null) {
      return ResponseBody(
        _film(url, chunks),
        200,
        headers: {
          Headers.contentTypeHeader: ['video/mp4'],
        },
      );
    }
    // SkyStream's own proxy, for a stream whose headers libVLC cannot send:
    // answered as the address it stands for.
    final proxied =
        options.uri.host == '127.0.0.1' && options.uri.path == '/proxy';
    final page = pages[proxied ? options.uri.queryParameters['url'] : url];
    return page == null
        ? ResponseBody.fromString('Page Not Found', 404)
        : ResponseBody.fromString(page, 200);
  }

  /// An MP4's opening box, then zeros, a chunk every 10 ms as a network
  /// delivers it, counted as each is handed over.
  Stream<Uint8List> _film(String url, int chunks) async* {
    for (var i = 0; i < chunks; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      chunksRead[url] = (chunksRead[url] ?? 0) + 1;
      final chunk = Uint8List(64 * 1024);
      if (i == 0) chunk.setAll(0, [0, 0, 0, 0x18, ...'ftypmp42'.codeUnits]);
      yield chunk;
    }
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  late _Playlists web;

  /// Where the position clock has got to, and the decoder's counters, for
  /// [overwhelm]. Each test starts them afresh: each has its own engine.
  var positionMs = 4000;
  var displayed = 0;
  var lost = 0;

  setUp(() {
    web = _Playlists(<String, String>{_master: _threeHeights});
    positionMs = 4000;
    displayed = 0;
    lost = 0;
  });

  Future<AppLocalizations> english() =>
      AppLocalizations.delegate.load(const Locale('en'));

  Map<Object?, Object?> lastOpen() =>
      engine.callsTo('setSource').last.arguments as Map<Object?, Object?>;

  /// The screen on a 1080p television (a device rung of 1080 wherever this
  /// runs), its playlists served by [web].
  Future<void> play(
    WidgetTester tester, {
    MultimediaItem? item,
    Episode? episode,
    String videoUrl = _master,
    List<StreamResult>? preloadedStreams,
    List<Override> overrides = const <Override>[],
  }) => pumpPlayer(
    tester,
    item: item,
    episode: episode,
    videoUrl: videoUrl,
    preloadedStreams: preloadedStreams,
    panelPhysicalSize: const Size(1920, 1080),
    panelDevicePixelRatio: 2,
    overrides: [
      dioClientProvider.overrideWithValue(Dio()..httpClientAdapter = web),
      ...overrides,
    ],
  );

  /// Options, then the Quality tab, as a viewer opens it.
  Future<void> openQuality(WidgetTester tester) async {
    final l10n = await english();
    await revealPlayerControls(tester);
    await tester.tap(find.byTooltip(l10n.options));
    await settle(tester);
    await tester.tap(find.text(l10n.playerQuality));
    await settle(tester);
  }

  Future<void> pickQuality(WidgetTester tester, String row) async {
    await openQuality(tester);
    await tester.tap(find.widgetWithText(PanelRow, row));
    await settle(tester);
  }

  List<String> rows(WidgetTester tester) => [
    for (final row in tester.widgetList<PanelRow>(find.byType(PanelRow)))
      row.label,
  ];

  List<String> ticked(WidgetTester tester) => [
    for (final row in tester.widgetList<PanelRow>(find.byType(PanelRow)))
      if (row.selected) row.label,
  ];

  /// Twelve seconds of a decoder throwing away most of what it decodes - the
  /// slideshow the step-down answers - with the clock moving all along.
  Future<void> overwhelm(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      displayed += 2;
      lost += 22;
      engine.decodedPictures(displayed: displayed, lost: lost);
      positionMs += 1000;
      await sendSnapshot(tester, <String, Object?>{
        ...snapshot(position: positionMs, duration: 7200000),
        'videoSize': <String, Object?>{'width': 1920, 'height': 1080},
      });
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 700));
    }
  }

  /// The per-media options of the last open.
  List<String> lastMediaOptions() {
    final arguments =
        engine.callsTo('setSource').last.arguments as Map<Object?, Object?>;
    return (arguments['mediaOptions'] as List<Object?>? ?? <Object?>[])
        .cast<String>();
  }

  /// A 1080p television, so the device's own rung is 1080 wherever these run
  /// and only the preference moves the cap.
  Future<void> playOnFullHd(
    WidgetTester tester, {
    PlayerSettings settings = const PlayerSettings(),
  }) => pumpPlayer(
    tester,
    settings: settings,
    panelPhysicalSize: const Size(1920, 1080),
    panelDevicePixelRatio: 2,
  );

  group('Auto follows the quality preference', () {
    testWidgets(
      'a 720p preference caps it at 720 on Wi-Fi',
      variant: texturePlatform,
      (tester) async {
        await playOnFullHd(
          tester,
          settings: const PlayerSettings(wifiQuality: QualityPreference.q720),
        );

        expect(lastMediaOptions(), contains(':adaptive-maxheight=720'));

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      "on mobile data it is mobile data's preference",
      variant: texturePlatform,
      (tester) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              connectivityChannel,
              (call) async => <String>['mobile'],
            );
        await playOnFullHd(
          tester,
          settings: const PlayerSettings(
            wifiQuality: QualityPreference.q1080,
            mobileQuality: QualityPreference.q480,
          ),
        );

        expect(lastMediaOptions(), contains(':adaptive-maxheight=480'));

        await tester.pumpWidget(const SizedBox());
      },
    );

    for (final preference in const [
      QualityPreference.any,
      QualityPreference.q1080,
      QualityPreference.q4k,
    ]) {
      testWidgets(
        '${preference.name} asks nothing of its own here: the '
        "device's rung stands",
        variant: texturePlatform,
        (tester) async {
          await playOnFullHd(
            tester,
            settings: PlayerSettings(wifiQuality: preference),
          );

          expect(
            lastMediaOptions().where(
              (o) => o.startsWith(':adaptive-maxheight'),
            ),
            isEmpty,
          );

          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  });

  group('the Quality tab', () {
    testWidgets(
      'a master with several heights gets it once it shows a '
      'picture',
      variant: texturePlatform,
      (tester) async {
        await play(tester);
        expect(
          web.asked,
          isEmpty,
          reason:
              'libVLC reads the playlist first: an address that works once is '
              'its to spend',
        );

        await sendFirstFrame(tester);
        await settle(tester);
        expect(web.asked, [_master]);
        await openQuality(tester);
        expect(rows(tester), ['Auto', '1080p', '720p', '480p']);
        expect(ticked(tester), ['Auto']);

        await tester.pumpWidget(const SizedBox());
      },
    );

    for (final (name, playlist) in const [
      (
        'a master with one height',
        '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1280x720\na.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2,RESOLUTION=1280x720\nb.m3u8\n',
      ),
      ('a media playlist', '#EXTM3U\n#EXTINF:10,\na.ts\n#EXT-X-ENDLIST\n'),
    ]) {
      testWidgets('$name is no choice', variant: texturePlatform, (
        tester,
      ) async {
        web.pages[_master] = playlist;
        final l10n = await english();
        await play(tester);
        await sendFirstFrame(tester);
        await settle(tester);
        expect(web.asked, [_master]);

        await revealPlayerControls(tester);
        await tester.tap(find.byTooltip(l10n.options));
        await settle(tester);
        expect(find.byType(PlayerPanel), findsOneWidget);
        expect(find.text(l10n.playerQuality), findsNothing);

        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets(
      'an address marked adaptive that answers with a film is read no '
      'further than its start, and is no choice',
      variant: texturePlatform,
      (tester) async {
        const film = 'https://cdn.test/show/film.mp4';
        web.films[film] = 200;
        final l10n = await english();
        await play(
          tester,
          videoUrl: film,
          preloadedStreams: const [
            StreamResult(url: film, source: 'Server', quality: 0),
          ],
        );
        await sendFirstFrame(tester);
        await settle(tester);
        expect(web.asked, contains(film), reason: 'marked adaptive: read');
        expect(
          web.chunksRead[film],
          lessThan(5),
          reason: 'its first bytes are no playlist: the rest is not read',
        );

        await revealPlayerControls(tester);
        await tester.tap(find.byTooltip(l10n.options));
        await settle(tester);
        expect(find.byType(PlayerPanel), findsOneWidget);
        expect(find.text(l10n.playerQuality), findsNothing);

        await tester.pumpWidget(const SizedBox());
      },
    );

    // Review Focus 2: a reopen of this source while its read is out.
    testWidgets(
      'a read that lands after a reopen of the same source still '
      'brings the tab, read once',
      variant: texturePlatform,
      (tester) async {
        final held = web.gates[_master] = Completer<void>();
        await play(tester);
        await sendFirstFrame(tester);
        await settle(tester);
        expect(web.asked, [_master], reason: 'asked, and not answered yet');

        // The source drops after its first picture and recovery opens it
        // again while the read is still out.
        await sendEvent(tester, snapshot(state: 'error'));
        await settle(tester);
        expect(lastOpen()['uri'], _master);

        held.complete();
        await settle(tester);
        await sendFirstFrame(tester);
        await settle(tester);
        await openQuality(tester);
        expect(rows(tester), ['Auto', '1080p', '720p', '480p']);
        expect(web.asked, [_master], reason: 'one read for one source');

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('a pick', () {
    // Review Focus 5: a live channel under the new Auto. The pick is exact,
    // and going back to Auto hands the stream back to predictive.
    testWidgets(
      'on a live channel reopens at the edge, and Auto follows the link again',
      variant: texturePlatform,
      (tester) async {
        final l10n = await english();
        await play(
          tester,
          item: MultimediaItem(
            title: 'Channel',
            url: _master,
            posterUrl: '',
            contentType: MultimediaContentType.livestream,
            provider: 'Remote',
          ),
        );
        await sendFirstFrame(tester);
        await settle(tester);

        await pickQuality(tester, '480p');
        final picked = (lastOpen()['mediaOptions'] as List<Object?>)
            .cast<String>();
        expect(
          picked,
          containsAll(<String>[
            ':adaptive-maxheight=480',
            ':adaptive-logic=highest',
            ':adaptive-livedelay=$kLiveDelayMs',
          ]),
        );
        expect(lastOpen()['startPosition'] ?? 0, 0, reason: 'the live edge');

        await sendEvent(tester, snapshot(position: 2500));
        await pickQuality(tester, l10n.playerQualityAuto);
        final auto = (lastOpen()['mediaOptions'] as List<Object?>)
            .cast<String>();
        expect(auto.where((o) => o.startsWith(':adaptive-logic')), isEmpty);
        expect(auto, contains(':adaptive-livedelay=$kLiveDelayMs'));

        await tester.pumpWidget(const SizedBox());
      },
    );

    // The final review's first finding: the reopen's own setMedia clears the
    // seek on its way, and the screen took that for a live seek libVLC never
    // took, so it reopened a second time at the seek's distance.
    testWidgets(
      'on a live channel while a seek in its window is on its way reopens '
      'once, at the live delay',
      variant: texturePlatform,
      (tester) async {
        // A desktop, where Left steps.
        await pumpPlayer(
          tester,
          item: MultimediaItem(
            title: 'Channel',
            url: _master,
            posterUrl: '',
            contentType: MultimediaContentType.livestream,
            provider: 'Remote',
          ),
          videoUrl: _master,
          isTv: false,
          panelPhysicalSize: const Size(1920, 1080),
          panelDevicePixelRatio: 2,
          overrides: [
            dioClientProvider.overrideWithValue(Dio()..httpClientAdapter = web),
          ],
        );
        await sendFirstFrame(tester);
        await settle(tester);
        // A two-minute window, 4,000 s into the stream's own timeline.
        await sendEvent(tester, <String, Object?>{
          ...snapshot(position: 4000000, duration: 120000),
          'positionFraction': 0.9,
        });
        await settle(tester);
        // Three steps back, as Left steps on a desktop.
        await revealPlayerControls(tester);
        await tester.pump();
        for (var i = 0; i < 3; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pump();
        }
        await tester.pump(VlcPlayerController.seekMergeWindow);
        final before = engine.callsTo('setSource').length;

        await pickQuality(tester, '480p');

        expect(engine.callsTo('setSource').length, before + 1);
        expect(
          (lastOpen()['mediaOptions'] as List<Object?>).cast<String>(),
          contains(':adaptive-livedelay=$kLiveDelayMs'),
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'reopens this source where it is, capped at the height',
      variant: texturePlatform,
      (tester) async {
        await play(tester);
        await sendFirstFrame(tester);
        await sendEvent(tester, snapshot(position: 60000, duration: 5400000));
        await settle(tester);
        final opens = engine.callsTo('setSource').length;

        await pickQuality(tester, '480p');

        expect(
          find.byType(PlayerPanel),
          findsNothing,
          reason: 'the panel closes first, so the viewer sees the reopen',
        );
        expect(engine.callsTo('setSource'), hasLength(opens + 1));
        expect(lastOpen()['uri'], _master);
        expect(lastOpen()['startPosition'], 60000);
        expect(
          (lastOpen()['mediaOptions'] as List<Object?>).cast<String>(),
          contains(':adaptive-maxheight=480'),
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      "Auto goes back to Auto's cap, and a height Auto already "
      'plays at is no reopen',
      variant: texturePlatform,
      (tester) async {
        final l10n = await english();
        await play(tester);
        await sendFirstFrame(tester);
        await settle(tester);
        final opens = engine.callsTo('setSource').length;

        await pickQuality(tester, '1080p');
        expect(
          engine.callsTo('setSource'),
          hasLength(opens),
          reason: "Auto's cap on this device is 1080 already",
        );

        await pickQuality(tester, '480p');
        expect(
          (lastOpen()['mediaOptions'] as List<Object?>).cast<String>(),
          contains(':adaptive-maxheight=480'),
        );

        // The reopened media's first picture: a later position than the one
        // the controller already holds, since an equal value notifies no one.
        await sendEvent(tester, snapshot(position: 2500));
        await pickQuality(tester, l10n.playerQualityAuto);
        expect(
          ((lastOpen()['mediaOptions'] as List<Object?>?) ?? const <Object?>[])
              .cast<String>()
              .where((o) => o.startsWith(':adaptive-maxheight')),
          isEmpty,
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'holds across a failover, and the next source ticks what '
      'plays under it',
      variant: texturePlatform,
      (tester) async {
        const a = 'https://cdn.test/a/master.m3u8';
        const b = 'https://cdn.test/b/master.m3u8';
        web.pages[a] = _threeHeights;
        web.pages[b] =
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2,RESOLUTION=1280x720\nhd.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=640x360\nld.m3u8\n';
        await play(
          tester,
          preloadedStreams: const [
            StreamResult(url: a, source: 'A', providerName: 'One'),
            StreamResult(url: b, source: 'B', providerName: 'Two'),
          ],
          // A's link is gone: its failure fails over at once, as the test
          // needs, rather than reopening a source that played (spec 2).
          overrides: [
            sourceCheckProvider.overrideWithValue(
              (stream) =>
                  stream.url == a ? goneCheck(stream) : answeringCheck(stream),
            ),
          ],
        );
        await sendFirstFrame(tester);
        await settle(tester);
        await pickQuality(tester, '480p');
        expect(lastOpen()['uri'], a);

        // The reopened source dies, and its link is gone: failover.
        await sendEvent(tester, snapshot(state: 'error'));
        await settle(tester);
        expect(lastOpen()['uri'], b);
        expect(
          (lastOpen()['mediaOptions'] as List<Object?>).cast<String>(),
          contains(':adaptive-maxheight=480'),
        );

        await sendFirstFrame(tester);
        await settle(tester);
        expect(web.asked, [a, b]);
        await openQuality(tester);
        expect(ticked(tester), [
          '360p',
        ], reason: 'B has no 480p: below it plays');

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('holds into the next episode', variant: texturePlatform, (
      tester,
    ) async {
      final e1 = Episode(
        name: 'One',
        url: 'https://cdn.test/e1/master.m3u8',
        season: 1,
        episode: 1,
      );
      final e2 = Episode(
        name: 'Two',
        url: 'https://cdn.test/e2/master.m3u8',
        season: 1,
        episode: 2,
      );
      web.pages[e1.url] = _threeHeights;
      web.pages[e2.url] = _threeHeights;
      GatedDownloads? downloads;
      await play(
        tester,
        item: MultimediaItem(
          title: 'Show',
          url: 'https://cdn.test/show',
          posterUrl: '',
          contentType: MultimediaContentType.series,
          episodes: [e1, e2],
          provider: 'Remote',
        ),
        episode: e1,
        videoUrl: e1.url,
        overrides: [
          downloadServiceProvider.overrideWith(
            (ref) => downloads = GatedDownloads(ref),
          ),
        ],
      );
      await sendFirstFrame(tester);
      await settle(tester);
      await pickQuality(tester, '720p');
      await sendFirstFrame(tester);

      // To the end, which goes on to the next episode by itself.
      await sendEvent(tester, snapshot(position: 1199000, duration: 1200000));
      await sendEvent(tester, snapshot(state: 'ended'));
      await settle(tester);
      downloads!.gate.complete();
      await settle(tester);

      expect(lastOpen()['uri'], e2.url);
      expect(
        lastOpen().containsKey('keepPicture'),
        isFalse,
        reason: 'the next episode is other media: the start-up view names it',
      );
      expect(
        (lastOpen()['mediaOptions'] as List<Object?>).cast<String>(),
        contains(':adaptive-maxheight=720'),
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'a step-down lowers a pick, and leaves one under 720 alone',
      variant: texturePlatform,
      (tester) async {
        await play(tester);
        await sendFirstFrame(tester);
        await settle(tester);
        await pickQuality(tester, '1080p');
        final opens = engine.callsTo('setSource').length;

        await overwhelm(tester);
        expect(engine.callsTo('setSource'), hasLength(opens + 1));
        expect(
          (lastOpen()['mediaOptions'] as List<Object?>).cast<String>(),
          contains(':adaptive-maxheight=720'),
        );
        await sendFirstFrame(tester);
        await openQuality(tester);
        expect(ticked(tester), ['720p'], reason: 'the pick came down with it');
        await sendBack(tester);
        await settle(tester);

        await pickQuality(tester, '480p');
        final picked = engine.callsTo('setSource').length;
        await sendFirstFrame(tester);
        await overwhelm(tester);
        expect(
          engine.callsTo('setSource'),
          hasLength(picked),
          reason: 'a pick under 720 is not lowered on its own',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    // Review Focus 3: a live channel.
    testWidgets(
      'a live channel offers its qualities, and a pick reopens it '
      'at the live edge',
      variant: texturePlatform,
      (tester) async {
        await play(
          tester,
          item: MultimediaItem(
            title: 'News',
            url: _master,
            posterUrl: '',
            contentType: MultimediaContentType.livestream,
            provider: 'Remote',
          ),
        );
        await sendEvent(tester, <String, Object?>{
          ...snapshot(),
          'isLive': true,
          'isSeekable': false,
        });
        await settle(tester);

        await pickQuality(tester, '480p');

        expect(lastOpen()['uri'], _master);
        expect(
          lastOpen().containsKey('startPosition'),
          isFalse,
          reason: 'a channel reopens at its live edge',
        );
        expect(
          (lastOpen()['mediaOptions'] as List<Object?>).cast<String>(),
          contains(':adaptive-maxheight=480'),
        );

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group("a stream SkyStream's own proxy serves", () {
    setUpAll(LocalProxyService.instance.startServer);
    tearDownAll(LocalProxyService.instance.shutdown);

    testWidgets(
      'gets the Quality tab like any other stream: no platform waits on '
      "libVLC on Dart's thread any more",
      variant: texturePlatform,
      (tester) async {
        final l10n = await english();
        // Origin is a header libVLC cannot send, so the screen hands it the
        // proxy's address instead of the master's.
        await play(
          tester,
          preloadedStreams: const [
            StreamResult(
              url: _master,
              source: 'Server',
              headers: {'Origin': 'https://site.test'},
            ),
          ],
        );
        expect(
          lastOpen()['uri'],
          startsWith(
            'http://127.0.0.1:${LocalProxyService.instance.port}/proxy',
          ),
        );
        await sendFirstFrame(tester);
        await settle(tester);

        await revealPlayerControls(tester);
        await tester.tap(find.byTooltip(l10n.options));
        await settle(tester);
        expect(find.text(l10n.playerQuality), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('the picture stays (spec 2, The reopen)', () {
    testWidgets(
      'a Quality pick keeps the picture: no start-up view, the controls up, '
      'a spinner, and no status line',
      variant: texturePlatform,
      (tester) async {
        engine.holdsPictures = true;
        final l10n = await english();
        await play(tester);
        await sendFirstFrame(tester);
        await sendEvent(tester, snapshot(position: 60000, duration: 5400000));
        await settle(tester);

        await pickQuality(tester, '480p');

        expect(lastOpen()['keepPicture'], isTrue);
        expect(lastOpen()['startPosition'], 60000);
        expect(find.byKey(openingOverlayKey), findsNothing);
        expect(find.byType(VlcPlayerControls), findsOneWidget);
        expect(find.byType(PlayerBufferingIndicator), findsOneWidget);
        expect(find.text(l10n.playerReconnecting), findsNothing);

        // The held media plays from the start position: the hold ends, and the
        // spinner goes with it - before the controller's own stall flag could
        // rise a second later - and the picture is this attempt's own.
        await engine.endHold(snapshot(position: 60400, duration: 5400000));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(PlayerBufferingIndicator), findsNothing);
        expect(find.byKey(openingOverlayKey), findsNothing);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'the bar keeps the length and goes where the reopen is going',
      variant: texturePlatform,
      (tester) async {
        engine.holdsPictures = true;
        await play(tester);
        await sendFirstFrame(tester);
        await sendEvent(tester, snapshot(position: 60000, duration: 5400000));
        await settle(tester);

        await pickQuality(tester, '480p');
        final controller = tester
            .widget<VlcPlayerControls>(find.byType(VlcPlayerControls))
            .controller;

        expect(controller.value.duration, const Duration(minutes: 90));
        expect(controller.value.isSeekable, isTrue);
        expect(controller.pendingSeekTarget.value, const Duration(minutes: 1));

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'an output that cannot hold shows the start-up view, as before',
      variant: texturePlatform,
      (tester) async {
        await play(tester);
        await sendFirstFrame(tester);
        await sendEvent(tester, snapshot(position: 60000, duration: 5400000));
        await settle(tester);

        await pickQuality(tester, '480p');

        expect(lastOpen()['keepPicture'], isTrue);
        expect(find.byKey(openingOverlayKey), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'a pick while a seek is on its way reopens where the seek was going',
      variant: texturePlatform,
      (tester) async {
        await play(tester);
        await sendFirstFrame(tester);
        await sendEvent(tester, snapshot(position: 60000, duration: 5400000));
        await settle(tester);
        final controller = tester
            .widget<VlcPlayerControls>(find.byType(VlcPlayerControls))
            .controller;
        // Every backend goes on reporting where the seek left from until it
        // lands.
        await controller.seekTo(const Duration(minutes: 5));
        await tester.pump(VlcPlayerController.seekMergeWindow);

        await pickQuality(tester, '480p');

        expect(lastOpen()['startPosition'], 300000);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'a live channel with a window reopens at the live start, not at its '
      'stream time',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(
          tester,
          item: MultimediaItem(
            title: 'Channel',
            url: _master,
            posterUrl: '',
            contentType: MultimediaContentType.livestream,
            provider: 'Remote',
          ),
          videoUrl: _master,
          panelPhysicalSize: const Size(1920, 1080),
          panelDevicePixelRatio: 2,
          overrides: [
            dioClientProvider.overrideWithValue(Dio()..httpClientAdapter = web),
          ],
        );
        await sendFirstFrame(tester);
        // A two-minute window, 4,000 s into the stream's own timeline: the
        // engine calls it seekable with a length, so it is not "live" to the
        // engine's own verdict.
        await sendEvent(tester, <String, Object?>{
          ...snapshot(position: 4000000, duration: 120000),
          'positionFraction': 0.9,
        });
        await settle(tester);

        await pickQuality(tester, '480p');

        expect(lastOpen().containsKey('startPosition'), isFalse);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'the first picture after a kept reopen does not bring the bars up again',
      variant: texturePlatform,
      (tester) async {
        engine.holdsPictures = true;
        await play(tester);
        await sendFirstFrame(tester);
        await sendEvent(tester, snapshot(position: 60000, duration: 5400000));
        await settle(tester);
        await pickQuality(tester, '480p');
        // Bars down, as Back on a remote puts them: over a picture that isn't
        // playing they never go by themselves.
        final chrome = tester
            .widget<VlcPlayerControls>(find.byType(VlcPlayerControls))
            .chrome!;
        if (chrome.value) chrome.toggle();
        await tester.pump();
        expect(chrome.value, isFalse);

        await engine.endHold(snapshot(position: 60400, duration: 5400000));
        await tester.pump(const Duration(milliseconds: 400));

        expect(chrome.value, isFalse);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
