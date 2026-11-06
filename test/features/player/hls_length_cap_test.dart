import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/dio_client_provider.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

const String _master = 'https://cdn.test/newtv/hls/pv/episode.m3u8?in=token';
const String _variant = 'https://cdn.test/newtv/hls/pv/1080/index.m3u8';

/// 99,999 seconds: what libVLC reports for a NetMirror episode, because the
/// master's subtitle playlists each claim one segment that long.
const int _inflatedMs = 99999000;

/// The length the player shows for an HLS stream whose master lists a
/// rendition claiming more than the video.
///
/// libVLC takes an HLS master's length from the longest playlist it has
/// loaded, renditions included, so every NetMirror episode read 27:46:39.
/// The screen now reads the video's own playlist and caps the length at it.
void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  testWidgets(
    "shows the video's own length, read off its playlist",
    variant: texturePlatform,
    (tester) async {
      final web = _Playlists(<String, String>{
        _master:
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",'
            'URI="subs/en.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=5000000,SUBTITLES="subs"\n'
            '1080/index.m3u8\n',
        _variant: [
          '#EXTM3U',
          '#EXT-X-TARGETDURATION:10',
          for (var i = 0; i < 297; i++) '#EXTINF:10,\nseg$i.ts',
          '#EXTINF:7,\nseg297.ts',
          '#EXT-X-ENDLIST',
        ].join('\n'),
      });
      await pumpPlayer(
        tester,
        videoUrl: _master,
        overrides: [
          dioClientProvider.overrideWithValue(Dio()..httpClientAdapter = web),
        ],
      );

      await sendFirstFrame(tester);
      await sendEvent(tester, snapshot(position: 1999, duration: _inflatedMs));
      // Two playlists away.
      await settle(tester);

      expect(find.text('0:01 / 49:37'), findsOneWidget);
      expect(find.textContaining('27:46:39'), findsNothing);
      expect(web.asked, <String>[_master, _variant]);

      // libVLC keeps saying what it says; the screen keeps the measurement.
      // Paused by the viewer: a pause nobody asked for is a failure.
      await tester
          .widget<VlcPlayerControls>(find.byType(VlcPlayerControls))
          .controller
          .pause();
      await sendEvent(
        tester,
        snapshot(state: 'paused', position: 2500, duration: _inflatedMs),
      );
      expect(find.text('0:02 / 49:37'), findsOneWidget);
      expect(web.asked, hasLength(2), reason: 'measured once per attempt');
    },
  );

  testWidgets(
    'a capped stream ends as finished, not as one that died short of its length',
    variant: texturePlatform,
    (tester) async {
      // Shorter than the half minute a sample must be to be kept, so the
      // samples taken before the cap - carrying 99,999 s - would otherwise
      // be the last word on how long this was.
      final web = _Playlists(<String, String>{
        _master:
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",'
            'URI="subs/en.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=5000000,SUBTITLES="subs"\n'
            '1080/index.m3u8\n',
        _variant:
            '#EXTM3U\n#EXTINF:10,\na.ts\n#EXTINF:10,\nb.ts\n#EXT-X-ENDLIST\n',
      });
      await pumpPlayer(
        tester,
        videoUrl: _master,
        overrides: [
          dioClientProvider.overrideWithValue(Dio()..httpClientAdapter = web),
        ],
      );

      await sendFirstFrame(tester);
      await sendEvent(tester, snapshot(position: 1999, duration: _inflatedMs));
      await settle(tester);
      expect(find.text('0:01 / 0:20'), findsOneWidget);
      await sendEvent(tester, snapshot(position: 10000, duration: _inflatedMs));
      await sendEvent(tester, snapshot(position: 19400, duration: _inflatedMs));

      await sendEvent(
        tester,
        snapshot(state: 'ended', position: 19400, duration: _inflatedMs),
      );
      await settle(tester);

      expect(find.textContaining("You've finished"), findsOneWidget);
      expect(
        engine.callsTo('setSource'),
        hasLength(1),
        reason: 'the ending was taken for a failure and the source reopened',
      );
    },
  );

  testWidgets(
    'a file that is not a playlist is taken at its word, and nothing is fetched',
    variant: texturePlatform,
    (tester) async {
      final web = _Playlists(const <String, String>{});
      await pumpPlayer(
        tester,
        overrides: [
          dioClientProvider.overrideWithValue(Dio()..httpClientAdapter = web),
        ],
      );

      await sendFirstFrame(tester);
      await sendEvent(tester, snapshot(position: 1999, duration: 5400000));
      await settle(tester);

      expect(find.text('0:01 / 1:30:00'), findsOneWidget);
      expect(web.asked, isEmpty);
      await sendEvent(
        tester,
        snapshot(state: 'paused', position: 2500, duration: 5400000),
      );
    },
  );
}

/// Serves [pages] and records what was asked for; anything else is a 404.
class _Playlists implements HttpClientAdapter {
  _Playlists(this.pages);

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
