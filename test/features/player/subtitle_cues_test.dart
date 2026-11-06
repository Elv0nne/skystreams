import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/subtitle_cues.dart';

Duration _ms(int milliseconds) => Duration(milliseconds: milliseconds);

void main() {
  group('SubRip', () {
    test('reads counters, CRLF line ends and a byte order mark', () {
      final cues = parseSubtitles(
        '﻿1\r\n00:00:01,000 --> 00:00:04,000\r\nHello\r\nthere\r\n\r\n'
        '2\r\n00:00:05,500 --> 00:00:07,250\r\nSecond\r\n',
      )!;

      expect(cues, hasLength(2));
      expect(cues[0].start, _ms(1000));
      expect(cues[0].end, _ms(4000));
      expect(cues[0].text, 'Hello\nthere');
      expect(cues[0].placement, SubtitlePlacement.bottom);
      expect(cues[1].start, _ms(5500));
      expect(cues[1].end, _ms(7250));
      expect(cues[1].text, 'Second');
    });

    test('splits cues whose blank line is missing', () {
      final cues = parseSubtitles(
        '1\n00:00:01,000 --> 00:00:02,000\nFirst\n'
        '2\n00:00:03,000 --> 00:00:04,000\nSecond\n',
      )!;

      expect(cues.map((cue) => cue.text), ['First', 'Second']);
    });

    test('keeps a line that is only a number', () {
      final cues = parseSubtitles(
        '1\n00:00:01,000 --> 00:00:02,000\nThe answer is\n42\n',
      )!;

      expect(cues.single.text, 'The answer is\n42');
    });

    test('reads points, short fractions and no counters', () {
      final cues = parseSubtitles(
        '0:00:01.5 --> 0:00:02.25\nOne\n\n1:02:03,004 --> 1:02:04,000\nTwo\n',
      )!;

      expect(cues[0].start, _ms(1500));
      expect(cues[0].end, _ms(2250));
      expect(
        cues[1].start,
        const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 4),
      );
    });

    test('keeps italics and bold, drops other tags, decodes entities', () {
      final cues = parseSubtitles(
        '1\n00:00:01,000 --> 00:00:02,000\n'
        '<font color="#ffff00">Tom &amp; <i>Jerry</i></font>\n<b>Run!</b>\n',
      )!;

      expect(cues.single.spans, const [
        SubtitleSpan('Tom & '),
        SubtitleSpan('Jerry', italic: true),
        SubtitleSpan('\n'),
        SubtitleSpan('Run!', bold: true),
      ]);
    });

    test('reads the overrides SubRip files borrow from SubStation Alpha', () {
      final cues = parseSubtitles(
        '1\n00:00:01,000 --> 00:00:02,000\n{\\an8}{\\i1}Sign{\\i0} text\n',
      )!;

      expect(cues.single.placement, SubtitlePlacement.top);
      expect(cues.single.spans, const [
        SubtitleSpan('Sign', italic: true),
        SubtitleSpan(' text'),
      ]);
    });

    test('keeps text that only looks like markup', () {
      final cues = parseSubtitles(
        '1\n00:00:01,000 --> 00:00:02,000\nI <3 you & {him}\n',
      )!;

      expect(cues.single.text, 'I <3 you & {him}');
    });

    test('drops cues with nothing to show or no time on screen', () {
      final cues = parseSubtitles(
        '1\n00:00:01,000 --> 00:00:02,000\n<font color="red"></font>\n\n'
        '2\n00:00:03,000 --> 00:00:03,000\nZero\n\n'
        '3\n00:00:05,000 --> 00:00:04,000\nBackwards\n\n'
        '4\n00:00:06,000 --> 00:00:07,000\nKept\n',
      )!;

      expect(cues.map((cue) => cue.text), ['Kept']);
    });
  });

  group('WebVTT', () {
    test('skips the header, notes, styles and cue identifiers', () {
      final cues = parseSubtitles('''
WEBVTT - with a title
Kind: captions
Language: en

NOTE a comment
that spans lines

STYLE
::cue { color: yellow }

intro
00:01.000 --> 00:04.000
First

2
01:00:05.000 --> 01:00:06.000 align:start position:10%
Second
''')!;

      expect(cues, hasLength(2));
      expect(cues[0].start, _ms(1000));
      expect(cues[0].text, 'First');
      expect(cues[1].start, const Duration(hours: 1, seconds: 5));
      expect(cues[1].text, 'Second');
    });

    test('drops voice, class and timestamp tags and decodes entities', () {
      final cues = parseSubtitles('''
WEBVTT

00:00:01.000 --> 00:00:02.000
<v Bob>Hi <c.yellow>there</c></v> &lt;3<00:00:01.500> again&nbsp;
''')!;

      expect(cues.single.text, 'Hi there <3 again');
    });

    test('drops ruby annotations but keeps the base text', () {
      final cues = parseSubtitles('''
WEBVTT

00:00:01.000 --> 00:00:02.000
<ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>
''')!;

      expect(cues.single.text, '漢字');
    });

    test('places cues by their line setting', () {
      final cues = parseSubtitles('''
WEBVTT

00:00:01.000 --> 00:00:02.000 line:0
Top by line number

00:00:01.000 --> 00:00:02.000 line:10%,start
Top by percentage

00:00:01.000 --> 00:00:02.000 line:50%
Middle

00:00:01.000 --> 00:00:02.000 line:-1
Bottom by line number

00:00:01.000 --> 00:00:02.000 line:85%
Bottom by percentage

00:00:01.000 --> 00:00:02.000
Default
''')!;

      expect(cues.map((cue) => cue.placement), [
        SubtitlePlacement.top,
        SubtitlePlacement.top,
        SubtitlePlacement.middle,
        SubtitlePlacement.bottom,
        SubtitlePlacement.bottom,
        SubtitlePlacement.bottom,
      ]);
    });

    test('reads a cue that follows the header without a blank line', () {
      final cues = parseSubtitles(
        'WEBVTT\n00:00:01.000 --> 00:00:02.000\nTight\n',
      )!;

      expect(cues.single.text, 'Tight');
    });
  });

  group('SubStation Alpha', () {
    const script = r'''
[Script Info]
ScriptType: v4.00+
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1
Style: Sign,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,-1,-1,0,0,100,100,0,0,1,2,2,8,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Comment: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,Not shown
Dialogue: 0,0:00:01.00,0:00:04.50,Default,,0,0,0,,Well, hello{\i1} there{\i0}\Nsecond line
Dialogue: 0,0:00:02.00,0:00:03.00,Sign,,0,0,0,,{\pos(320,50)}A sign
Dialogue: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,{\an7}Moved{\r} up
Dialogue: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,{\p1}m 0 0 l 100 0 100 100{\p0}
Dialogue: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,{a comment}Hard\hspace and soft\nbreak
Dialogue: 0,0:00:02.00,0:00:03.00,Missing,,0,0,0,,{\b700}Heavy{\b0} light
''';

    test('reads dialogue with commas, breaks, italics and escapes', () {
      final cues = parseSubtitles(script)!;

      expect(cues, hasLength(5));
      expect(cues[0].start, _ms(1000));
      expect(cues[0].end, _ms(4500));
      expect(cues[0].spans, const [
        SubtitleSpan('Well, hello'),
        SubtitleSpan(' there', italic: true),
        SubtitleSpan('\nsecond line'),
      ]);
      expect(cues[3].text, 'Hard space and soft break');
    });

    test('takes placement and style from the line style', () {
      final cues = parseSubtitles(script)!;

      final sign = cues[1];
      expect(sign.placement, SubtitlePlacement.top);
      expect(sign.spans, const [
        SubtitleSpan('A sign', italic: true, bold: true),
      ]);
    });

    test('lets an alignment override move the line', () {
      final cues = parseSubtitles(script)!;

      expect(cues[2].placement, SubtitlePlacement.top);
      expect(cues[2].text, 'Moved up');
    });

    test('drops drawings and reads weights as bold', () {
      final cues = parseSubtitles(script)!;

      expect(cues.map((cue) => cue.text), isNot(contains(contains('m 0 0'))));
      expect(cues[4].spans, const [
        SubtitleSpan('Heavy', bold: true),
        SubtitleSpan(' light'),
      ]);
    });

    test('reads the legacy alignments of v4 styles', () {
      final cues = parseSubtitles(r'''
[Script Info]
ScriptType: v4.00

[V4 Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
Style: *Default,Arial,20,16777215,65535,65535,-2147483640,0,0,1,2,2,6,10,10,10,0,1

[Events]
Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: Marked=0,0:00:01.00,0:00:02.00,*Default,,0000,0000,0000,,Up top
Dialogue: Marked=0,0:00:01.00,0:00:02.00,*Default,,0000,0000,0000,,{\a10}Middle
''')!;

      expect(cues.map((cue) => cue.placement), [
        SubtitlePlacement.top,
        SubtitlePlacement.middle,
      ]);
    });
  });

  test('parseSubtitles returns null for text in no subtitle format', () {
    expect(parseSubtitles('<html><body>Not found</body></html>'), isNull);
    expect(parseSubtitles(''), isNull);
  });

  group('SubtitleTimeline', () {
    SubtitleCue cue(int start, int end, String text) => SubtitleCue(
      start: _ms(start),
      end: _ms(end),
      spans: [SubtitleSpan(text)],
    );

    test('finds overlapping cues, a long one included, in start order', () {
      final timeline = SubtitleTimeline([
        cue(5000, 6000, 'late'),
        cue(0, 60000, 'sign'),
        cue(1000, 2000, 'a'),
        cue(1500, 2500, 'b'),
      ]);

      expect(timeline.at(_ms(1600)).map((c) => c.text), ['sign', 'a', 'b']);
      expect(timeline.at(_ms(5000)).map((c) => c.text), ['sign', 'late']);
      expect(timeline.at(_ms(2500)).map((c) => c.text), ['sign']);
      expect(timeline.at(_ms(60000)), isEmpty);
    });

    test('keeps file order for cues that start together', () {
      final timeline = SubtitleTimeline([
        for (var i = 0; i < 20; i++) cue(1000, 2000, '$i'),
      ]);

      expect(timeline.at(_ms(1000)).map((c) => c.text), [
        for (var i = 0; i < 20; i++) '$i',
      ]);
    });

    test('says when the lines on screen next change', () {
      final timeline = SubtitleTimeline([
        cue(1000, 5000, 'long'),
        cue(2000, 3000, 'short'),
        cue(8000, 9000, 'later'),
      ]);

      expect(timeline.nextChange(Duration.zero), _ms(1000));
      expect(timeline.nextChange(_ms(1500)), _ms(2000));
      expect(timeline.nextChange(_ms(2500)), _ms(3000));
      expect(timeline.nextChange(_ms(3000)), _ms(5000));
      expect(timeline.nextChange(_ms(5000)), _ms(8000));
      expect(timeline.nextChange(_ms(9000)), isNull);
    });

    test('is empty before the first cue and for no cues', () {
      expect(SubtitleTimeline([cue(1000, 2000, 'a')]).at(_ms(999)), isEmpty);
      expect(SubtitleTimeline.empty.at(Duration.zero), isEmpty);
    });
  });

  group('decodeSubtitleBytes', () {
    test('reads UTF-8 with and without a byte order mark', () {
      expect(decodeSubtitleBytes(utf8.encode('Olá')), 'Olá');
      expect(
        decodeSubtitleBytes([0xEF, 0xBB, 0xBF, ...utf8.encode('Olá')]),
        'Olá',
      );
    });

    test('reads UTF-16 in either byte order', () {
      expect(decodeSubtitleBytes([0xFF, 0xFE, 0x48, 0x00, 0xE9, 0x00]), 'Hé');
      expect(decodeSubtitleBytes([0xFE, 0xFF, 0x00, 0x48, 0x00, 0xE9]), 'Hé');
    });

    test('falls back to Windows-1252 for bytes that are not UTF-8', () {
      expect(
        decodeSubtitleBytes([0x93, 0x43, 0x61, 0x66, 0xE9, 0x94, 0x80]),
        '“Café”€',
      );
    });

    test('reads a file that is not Unicode in the code page chosen', () {
      // A word in each language, as its code page writes it.
      const words = <String, (List<int>, String)>{
        'Windows-1250': ([0x5A, 0x61, 0xBF, 0xF3, 0xB3, 0xE6], 'Zażółć'),
        'Windows-1251': ([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2], 'Привет'),
        'Windows-1252': ([0x93, 0x43, 0x61, 0x66, 0xE9, 0x94], '“Café”'),
        'Windows-1253': ([0xC3, 0xE5, 0xE9, 0xDC], 'Γειά'),
        'Windows-1254': ([0x49, 0xFE, 0xFD, 0x6B], 'Işık'),
        'Windows-1255': ([0xF9, 0xEC, 0xE5, 0xED], 'שלום'),
        'Windows-1256': ([0xD3, 0xE1, 0xC7, 0xE3], 'سلام'),
        'Windows-1257': ([0x41, 0xE8, 0x69, 0xFB], 'Ačiū'),
        // Vietnamese spells most tones with a combining mark, kept as one.
        'Windows-1258': ([0xD0, 0xFD, 0xF5, 0xCC], 'Đươ\u0300'),
      };
      for (final MapEntry(key: encoding, value: (bytes, word))
          in words.entries) {
        expect(
          decodeSubtitleBytes(bytes, encoding: encoding),
          word,
          reason: encoding,
        );
      }
    });

    test('a byte order mark or valid UTF-8 wins over the code page', () {
      // A Unicode file read as Cyrillic would be nothing but garbage: the
      // chosen code page is for the files that are not Unicode.
      expect(
        decodeSubtitleBytes(utf8.encode('Привет'), encoding: 'Windows-1251'),
        'Привет',
      );
      expect(
        decodeSubtitleBytes([
          0xEF,
          0xBB,
          0xBF,
          ...utf8.encode('Olá'),
        ], encoding: 'Windows-1251'),
        'Olá',
      );
      expect(
        decodeSubtitleBytes([0xFF, 0xFE, 0x1F, 0x04], encoding: 'Windows-1253'),
        'П',
      );
    });

    test('Auto, and a name it does not know, read Windows-1252', () {
      const bytes = <int>[0xCF, 0xF0, 0xE8];
      expect(decodeSubtitleBytes(bytes), 'Ïðè');
      expect(decodeSubtitleBytes(bytes, encoding: ''), 'Ïðè');
      expect(decodeSubtitleBytes(bytes, encoding: 'KOI8-R'), 'Ïðè');
    });

    test('a byte the code page leaves undefined reads as U+FFFD', () {
      expect(decodeSubtitleBytes([0x41, 0x81]), 'A\uFFFD');
      expect(decodeSubtitleBytes([0xAA], encoding: 'Windows-1253'), '\uFFFD');
    });

    test('the tables are what tool/subtitle_code_pages.py makes', () {
      final table = File('lib/features/player/domain/subtitle_code_pages.dart')
          .readAsStringSync();
      // A python3 that is there and cannot run is skipped like one that is
      // not there: Windows' App Execution Alias, with no Python behind it,
      // answers every call by exiting 9009.
      ProcessResult? version;
      try {
        version = Process.runSync('python3', ['--version']);
      } on ProcessException {
        version = null;
      }
      if (version == null || version.exitCode != 0) {
        markTestSkipped('no python3 to run the generator with');
        return;
      }
      final made = Process.runSync('python3', [
        '-I',
        'tool/subtitle_code_pages.py',
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      expect(made.stdout, table);
    });
  });

  group('HLS subtitle playlists', () {
    final base = Uri.parse('https://cdn.example/subs/en/index.m3u8?token=1');

    test('lists segments with their start times, resolved to the playlist', () {
      final segments = hlsSubtitleSegments('''
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
seg0.vtt
#EXTINF:4.5,
../other/seg1.vtt
seg2.vtt
#EXT-X-ENDLIST
''', base)!;

      expect(segments.map((s) => s.url.toString()), [
        'https://cdn.example/subs/en/seg0.vtt',
        'https://cdn.example/subs/other/seg1.vtt',
        'https://cdn.example/subs/en/seg2.vtt',
      ]);
      expect(segments.map((s) => s.start), [
        Duration.zero,
        const Duration(seconds: 6),
        const Duration(milliseconds: 10500),
      ]);
    });

    test('is null for a master playlist and for no playlist', () {
      expect(
        hlsSubtitleSegments(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nvideo.m3u8\n',
          base,
        ),
        isNull,
      );
      expect(hlsSubtitleSegments('WEBVTT\n', base), isNull);
    });

    test('places segments by their timestamp maps', () {
      final cues = joinSubtitleSegments([
        'WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n\n'
            '00:00:01.000 --> 00:00:02.000\nFirst\n',
        // Local times restart per segment; the map puts this one 6s later.
        'WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:1440000\n\n'
            '00:00:01.000 --> 00:00:02.000\nSecond\n',
      ]);

      expect(cues.map((cue) => (cue.start, cue.text)), [
        (_ms(1000), 'First'),
        (_ms(7000), 'Second'),
      ]);
    });

    test('keeps a cue repeated across segments once', () {
      const map = 'X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000';
      final cues = joinSubtitleSegments([
        'WEBVTT\n$map\n\n00:00:05.000 --> 00:00:07.000\nStraddles\n',
        'WEBVTT\n$map\n\n00:00:05.000 --> 00:00:07.000\nStraddles\n\n'
            '00:00:08.000 --> 00:00:09.000\nNext\n',
      ]);

      expect(cues.map((cue) => cue.text), ['Straddles', 'Next']);
      expect(cues.first.start, _ms(5000));
    });

    test('handles the MPEG-2 timestamp wrapping between segments', () {
      final cues = joinSubtitleSegments([
        'WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:8589844592,LOCAL:00:00:00.000\n\n'
            '00:00:00.000 --> 00:00:01.000\nBefore\n',
        // 8589934592 wraps to 0: this segment is 1 second (90000 ticks) later.
        'WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n'
            '00:00:00.000 --> 00:00:01.000\nAfter\n',
      ]);

      expect(cues.last.start, _ms(1000));
    });
  });

  group('loadSubtitleCues', () {
    Future<List<int>?> Function(Uri) serve(
      Map<String, String?> files, [
      List<Uri>? log,
    ]) {
      return (url) async {
        log?.add(url);
        final text = files[url.toString()];
        return text == null ? null : utf8.encode(text);
      };
    }

    test('reads a plain file', () async {
      final load = await loadSubtitleCues(
        Uri.parse('https://x/a.srt'),
        serve({'https://x/a.srt': '1\n00:00:01,000 --> 00:00:02,000\nHi\n'}),
      );

      expect(load.failure, isNull);
      expect(load.cues.single.text, 'Hi');
    });

    test('reads a file that is not Unicode in the code page given', () async {
      final file = <int>[
        ...ascii.encode('1\n00:00:01,000 --> 00:00:02,000\n'),
        0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, // Привет in Windows-1251
        0x0A,
      ];
      final load = await loadSubtitleCues(
        Uri.parse('https://x/ru.srt'),
        (url) async => file,
        encoding: 'Windows-1251',
      );

      expect(load.cues.single.text, 'Привет');
    });

    test('reads a playlist\'s segments in the code page given', () async {
      final segment = <int>[
        ...ascii.encode('WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n'),
        0xC3, 0xE5, 0xE9, 0xDC, // Γειά in Windows-1253
        0x0A,
      ];
      final load = await loadSubtitleCues(
        Uri.parse('https://x/subs.m3u8'),
        (url) async => url.path.endsWith('.m3u8')
            ? ascii.encode('#EXTM3U\n#EXTINF:10,\n0.vtt\n#EXT-X-ENDLIST\n')
            : segment,
        encoding: 'Windows-1253',
      );

      expect(load.cues.single.text, 'Γειά');
    });

    test(
      'tells a file it could not fetch from one it could not read',
      () async {
        final fetch = serve({
          'https://x/page': '<html></html>',
          'https://x/empty.vtt': 'WEBVTT\n',
        });
        Future<SubtitleLoadFailure?> failure(
          String url, [
          SubtitleFetcher? f,
        ]) async =>
            (await loadSubtitleCues(Uri.parse(url), f ?? fetch)).failure;

        expect(
          await failure('https://x/gone'),
          SubtitleLoadFailure.unavailable,
        );
        expect(
          await failure('https://x/a.srt', (_) => throw StateError('offline')),
          SubtitleLoadFailure.unavailable,
        );
        expect(await failure('https://x/page'), SubtitleLoadFailure.unreadable);
        expect(
          await failure('https://x/empty.vtt'),
          SubtitleLoadFailure.unreadable,
        );
      },
    );

    test(
      'calls a playlist none of whose segments arrived unavailable',
      () async {
        final load = await loadSubtitleCues(
          Uri.parse('https://x/subs.m3u8'),
          serve({'https://x/subs.m3u8': '#EXTM3U\n#EXTINF:10,\n0.vtt\n'}),
        );

        expect(load.failure, SubtitleLoadFailure.unavailable);
      },
    );

    test('joins a playlist, skipping a segment that fails', () async {
      final cues = await loadSubtitleCues(
        Uri.parse('https://x/subs.m3u8'),
        serve({
          'https://x/subs.m3u8': '#EXTM3U\n#EXTINF:10,\n0.vtt\n#EXTINF:10,\n1.vtt\n#EXTINF:10,\n2.vtt\n#EXT-X-ENDLIST\n',
          'https://x/0.vtt': 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nZero\n',
          'https://x/1.vtt': null,
          'https://x/2.vtt': 'WEBVTT\n\n00:00:21.000 --> 00:00:22.000\nTwo\n',
        }),
      );

      expect(SubtitleTimeline(cues.cues).cues.map((cue) => cue.text), [
        'Zero',
        'Two',
      ]);
    });

    test('reads a playlist of one whole file, the NetMirror shape', () async {
      final cues = await loadSubtitleCues(
        Uri.parse('https://x/subs.m3u8'),
        serve({
          'https://x/subs.m3u8': '#EXTM3U\n#EXT-X-TARGETDURATION:99999\n#EXTINF:99999,\nhttps://y/full.vtt\n#EXT-X-ENDLIST\n',
          'https://y/full.vtt': 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nOne\n\n01:30:00.000 --> 01:30:01.000\nLater\n',
        }),
      );

      expect(cues.cues.map((cue) => cue.text), ['One', 'Later']);
    });

    test(
      'fetches the first segment, then nearest the resume point first',
      () async {
        final log = <Uri>[];
        final files = <String, String?>{
          'https://x/subs.m3u8': [
            '#EXTM3U',
            for (var i = 0; i < 10; i++) ...['#EXTINF:10,', '$i.vtt'],
            '#EXT-X-ENDLIST',
          ].join('\n'),
          for (var i = 0; i < 10; i++)
            'https://x/$i.vtt':
                'WEBVTT\n\n00:00:${i}0.500 --> 00:00:${i}1.000\nSegment $i\n',
        };
        await loadSubtitleCues(
          Uri.parse('https://x/subs.m3u8'),
          serve(files, log),
          from: const Duration(seconds: 65),
        );

        final order = log.skip(1).map((url) => url.pathSegments.last).toList();
        expect(order.take(2), ['0.vtt', '6.vtt']);
        expect(order.toSet(), {for (var i = 0; i < 10; i++) '$i.vtt'});
        expect(order.indexOf('7.vtt'), lessThan(order.indexOf('5.vtt')));
      },
    );

    test('stops fetching once cancelled', () async {
      final log = <Uri>[];
      var cancel = false;
      final result = await loadSubtitleCues(Uri.parse('https://x/subs.m3u8'), (
        url,
      ) async {
        log.add(url);
        if (url.path.endsWith('0.vtt')) cancel = true;
        return utf8.encode(
          url.path.endsWith('.m3u8')
              ? [
                  '#EXTM3U',
                  for (var i = 0; i < 50; i++) ...['#EXTINF:10,', '$i.vtt'],
                ].join('\n')
              : 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nX\n',
        );
      }, cancelled: () => cancel);

      expect(result.failure, SubtitleLoadFailure.unavailable);
      expect(log, hasLength(2));
    });
  });
}
