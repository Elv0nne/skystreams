/// Reading an HLS stream's real length off the video's own playlist.
///
/// libVLC reports a master's length as that of the longest playlist it has
/// loaded, alternative renditions included. NetMirror wraps each subtitle
/// file as a playlist of one segment claiming 99,999 seconds, so its episodes
/// read 27:46:39. The measurement here is what the player caps that at.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/hls_video_length.dart';

final Uri _master = Uri.parse(
  'https://cdn.test/newtv/hls/pv/episode.m3u8?in=token',
);

/// The shape of a NetMirror master: audio in the variant, subtitles as
/// renditions with their own playlists.
const String _netMirrorMaster = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",AUTOSELECT=YES,URI="subs/en.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Hindi",LANGUAGE="hi",AUTOSELECT=YES,URI="subs/hi.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,SUBTITLES="subs"
1080/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,SUBTITLES="subs"
720/index.m3u8
''';

String _vod(List<num> segments, {bool endList = true, String? type}) => [
  '#EXTM3U',
  '#EXT-X-VERSION:3',
  '#EXT-X-TARGETDURATION:10',
  ?type == null ? null : '#EXT-X-PLAYLIST-TYPE:$type',
  for (var i = 0; i < segments.length; i++) ...[
    '#EXTINF:${segments[i]},',
    'seg$i.ts',
  ],
  if (endList) '#EXT-X-ENDLIST',
].join('\n');

/// Answers from [pages] and records what was asked for.
class _Web {
  _Web(this.pages);

  final Map<String, String> pages;
  final List<Uri> asked = <Uri>[];

  Future<String?> fetch(Uri url) async {
    asked.add(url);
    return pages[url.toString()];
  }
}

void main() {
  group('measureHlsVideoLength', () {
    test('reads the video playlist, not the renditions', () async {
      final web = _Web(<String, String>{
        '$_master': _netMirrorMaster,
        // 49:37, in ten-second segments and one short one.
        'https://cdn.test/newtv/hls/pv/1080/index.m3u8': _vod(<num>[
          for (var i = 0; i < 297; i++) 10,
          7,
        ]),
      });

      final length = await measureHlsVideoLength(_master, web.fetch);

      expect(length, const Duration(minutes: 49, seconds: 37));
      // The first variant, resolved against the master; the subtitle
      // playlists are never asked for - the video's is the one that counts.
      expect(web.asked, <Uri>[
        _master,
        Uri.parse('https://cdn.test/newtv/hls/pv/1080/index.m3u8'),
      ]);
    });

    test('has nothing to correct in a media playlist', () async {
      final web = _Web(<String, String>{
        '$_master': _vod(<num>[10, 10]),
      });

      expect(await measureHlsVideoLength(_master, web.fetch), isNull);
      expect(web.asked, <Uri>[_master]);
    });

    test('has nothing to correct in a master with no renditions', () async {
      // Without an alternative rendition there is no other playlist for
      // libVLC to take a length from; the variant is not even fetched.
      final web = _Web(<String, String>{
        '$_master':
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n'
            '360/index.m3u8\n',
      });

      expect(await measureHlsVideoLength(_master, web.fetch), isNull);
      expect(web.asked, <Uri>[_master]);
    });

    test('counts audio renditions that have their own playlist', () async {
      final web = _Web(<String, String>{
        '$_master':
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Hindi",URI="audio/hi.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="aud"\n'
            'video.m3u8\n',
        'https://cdn.test/newtv/hls/pv/video.m3u8': _vod(<num>[6, 6, 6]),
      });

      expect(
        await measureHlsVideoLength(_master, web.fetch),
        const Duration(seconds: 18),
      );
    });

    test('says nothing about a live stream', () async {
      final web = _Web(<String, String>{
        '$_master': _netMirrorMaster,
        'https://cdn.test/newtv/hls/pv/1080/index.m3u8': _vod(<num>[
          6,
          6,
        ], endList: false),
      });

      expect(await measureHlsVideoLength(_master, web.fetch), isNull);
    });

    test('says nothing when a playlist cannot be read', () async {
      final web = _Web(<String, String>{'$_master': _netMirrorMaster});

      expect(await measureHlsVideoLength(_master, web.fetch), isNull);
      expect(await measureHlsVideoLength(_master, (_) async => null), isNull);
    });
  });

  group('hlsVodLength', () {
    test('adds up fractional segment lengths', () {
      expect(
        hlsVodLength(_vod(<num>[4.004, 4.004, 2.5])),
        const Duration(microseconds: 10508000),
      );
    });

    test('takes PLAYLIST-TYPE:VOD as an ending, as libVLC does', () {
      expect(
        hlsVodLength(_vod(<num>[6, 6], endList: false, type: 'VOD')),
        const Duration(seconds: 12),
      );
    });

    test('an EVENT playlist still growing has no length', () {
      expect(
        hlsVodLength(_vod(<num>[6, 6], endList: false, type: 'EVENT')),
        isNull,
      );
    });

    test('a segment without its own length takes the target duration', () {
      const playlist = '''#EXTM3U
#EXT-X-TARGETDURATION:10
seg0.ts
#EXTINF:4,
seg1.ts
#EXT-X-ENDLIST''';

      expect(hlsVodLength(playlist), const Duration(seconds: 14));
    });

    test('a playlist with no segments has no length', () {
      expect(hlsVodLength('#EXTM3U\n#EXT-X-ENDLIST\n'), isNull);
      expect(hlsVodLength('<html>Page Not Found</html>'), isNull);
    });
  });

  group('looksLikeHls', () {
    test('knows a playlist by its path, or by the one a proxy carries', () {
      expect(looksLikeHls(_master), isTrue);
      expect(
        looksLikeHls(
          Uri.parse(
            'http://127.0.0.1:4000/proxy?url=https%3A%2F%2Fcdn.test%2Fa.m3u8'
            '&extension=.m3u8',
          ),
        ),
        isTrue,
      );
      expect(looksLikeHls(Uri.parse('https://cdn.test/movie.mp4')), isFalse);
      expect(looksLikeHls(Uri.parse('https://cdn.test/movie.mkv')), isFalse);
    });
  });
}
