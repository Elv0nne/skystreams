import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'test_support.dart';

const String _segmentAsset = 'assets/format_fixtures/hls/segment.ts';

/// The length libVLC reports for an HLS master, and the cap that corrects it.
///
/// libVLC takes a master's length from the longest playlist it has loaded,
/// alternative renditions included, selected or not. NetMirror wraps each
/// subtitle file as a playlist of one segment claiming 99,999 seconds, so its
/// episodes read 27:46:39 - with a seek bar to match, and a real ending that
/// looked like a stream dying short of its length. The host measures the
/// video's own playlist and hands the controller that length.
///
/// If the first test starts failing because libVLC reports 20 seconds, the
/// engine has stopped counting renditions and the host's measuring is no
/// longer needed.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;

  setUpAll(() async {
    final segment = (await rootBundle.load(_segmentAsset)).buffer.asUint8List();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      final response = request.response;
      if (path.endsWith('.ts')) {
        response.headers.contentType = ContentType('video', 'mp2t');
        response.add(segment);
      } else if (path.endsWith('.vtt')) {
        response.headers.contentType = ContentType('text', 'vtt');
        response.write('WEBVTT\n\n00:00:00.500 --> 00:00:05.000\nHello\n');
      } else {
        response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        response.write(_playlists[path] ?? '');
      }
      await response.close();
    });
  });

  tearDownAll(() => server.close(force: true));

  Future<VlcPlayerController> play(WidgetTester tester, String master) async {
    final controller = VlcPlayerController(options: headlessPlayerOptions());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 135,
            child: VlcPlayer(controller: controller),
          ),
        ),
      ),
    );
    await pumpUntil(tester, () => controller.isAttached);
    await controller.setMedia(
      VlcMediaSource(uri: Uri.parse('http://127.0.0.1:${server.port}$master')),
      autoPlay: true,
    );
    await pumpUntil(
      tester,
      () => controller.value.duration > Duration.zero,
      description: 'a length for $master',
    );
    return controller;
  }

  testWidgets('a rendition claiming more than the video sets the length', (
    tester,
  ) async {
    final plain = await play(tester, '/plain.m3u8');
    expect(plain.value.duration, const Duration(seconds: 20));
    await tester.pumpWidget(const SizedBox.shrink());

    // Not selected - DEFAULT=NO - and it still counts.
    final subtitled = await play(tester, '/subtitled.m3u8');
    expect(subtitled.value.duration, const Duration(seconds: 99999));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the measured length caps it, while libVLC keeps reporting', (
    tester,
  ) async {
    final controller = await play(tester, '/subtitled.m3u8');

    controller.setDurationCap(const Duration(seconds: 20));
    // Past a few more native snapshots, each still carrying 99,999 s.
    await tester.pump(const Duration(seconds: 2));

    expect(controller.value.duration, const Duration(seconds: 20));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// Ten 2 s segments of the fixture: a 20 s video.
final String _video = [
  '#EXTM3U',
  '#EXT-X-VERSION:3',
  '#EXT-X-TARGETDURATION:2',
  '#EXT-X-PLAYLIST-TYPE:VOD',
  for (var i = 0; i < 10; i++) ...[
    if (i > 0) '#EXT-X-DISCONTINUITY',
    '#EXTINF:2.000,',
    '/seg$i.ts',
  ],
  '#EXT-X-ENDLIST',
].join('\n');

final Map<String, String> _playlists = <String, String>{
  '/plain.m3u8':
      '#EXTM3U\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=160x90\n'
      '/video.m3u8\n',
  '/subtitled.m3u8':
      '#EXTM3U\n'
      '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",'
      'LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,URI="/subs.m3u8"\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=160x90,'
      'SUBTITLES="subs"\n'
      '/video.m3u8\n',
  '/video.m3u8': _video,
  // One WebVTT file wrapped as a playlist that claims 99,999 s, as NetMirror
  // serves its subtitles.
  '/subs.m3u8':
      '#EXTM3U\n'
      '#EXT-X-VERSION:3\n'
      '#EXT-X-TARGETDURATION:99999\n'
      '#EXT-X-PLAYLIST-TYPE:VOD\n'
      '#EXTINF:99999,\n'
      '/subs.vtt\n'
      '#EXT-X-ENDLIST\n',
};
