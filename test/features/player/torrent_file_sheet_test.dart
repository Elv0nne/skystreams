import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/models/torrent_status.dart';
import 'package:skystream/features/player/presentation/vlc/torrent_file_sheet.dart';

void main() {
  TorrentStatus statusWith(Object? fileStats) =>
      TorrentStatus.fromMap(<dynamic, dynamic>{
        'title': 'Pack',
        'file_stats': fileStats,
      });

  group('torrentFilesOf', () {
    test('reads id, leaf name and size', () {
      final files = torrentFilesOf(
        statusWith([
          {'id': 0, 'path': 'Show.S02/Show.S02E01.mkv', 'length': 1500000000},
          {'id': 1, 'path': 'Show.S02/Show.S02E02.mkv', 'length': 1400000000},
        ]),
      );
      expect(files.map((f) => f.index), <int>[0, 1]);
      expect(files.map((f) => f.name), <String>[
        'Show.S02E01.mkv',
        'Show.S02E02.mkv',
      ]);
      expect(files.first.sizeBytes, 1500000000);
    });

    test('keeps the ids the server gave, not list positions', () {
      // getStreamUrlForFileIndex takes the server's own id. Filtering the
      // samples out shifts every position but must not shift an id.
      final files = torrentFilesOf(
        statusWith([
          {'id': 0, 'path': 'pack/readme.nfo'},
          {'id': 1, 'path': 'pack/Sample.txt'},
          {'id': 2, 'path': 'pack/E01.mkv'},
        ]),
      );
      expect(files.single.index, 2);
    });

    test('drops everything that is not a video file', () {
      final files = torrentFilesOf(
        statusWith([
          {'id': 0, 'path': 'pack/E01.mkv'},
          {'id': 1, 'path': 'pack/E01.srt'},
          {'id': 2, 'path': 'pack/cover.jpg'},
          {'id': 3, 'path': 'pack/RARBG.txt'},
          {'id': 4, 'path': 'pack/E02.MP4'},
        ]),
      );
      expect(files.map((f) => f.name), <String>['E01.mkv', 'E02.MP4']);
    });

    test('handles Windows separators and extensionless entries', () {
      final files = torrentFilesOf(
        statusWith([
          {'id': 0, r'path': r'pack\sub\E01.mkv'},
          {'id': 1, 'path': 'pack/DISC_IMAGE'},
        ]),
      );
      expect(files.single.name, 'E01.mkv');
    });

    test('a torrent with no metadata yet yields nothing', () {
      // Every field can be missing while the magnet is still resolving, and
      // the whole key can be absent. None of that may throw over the video.
      expect(torrentFilesOf(null), isEmpty);
      expect(torrentFilesOf(statusWith(null)), isEmpty);
      expect(torrentFilesOf(statusWith('not a list')), isEmpty);
      expect(
        torrentFilesOf(
          statusWith([
            'junk',
            {'path': 'pack/E01.mkv'}, // no id
            {'id': 3}, // no path
            {'id': 4, 'path': ''},
          ]),
        ),
        isEmpty,
      );
    });
  });

  group('showTorrentFileSheet', () {
    const files = <TorrentFile>[
      TorrentFile(index: 0, name: 'E01.mkv'),
      TorrentFile(index: 1, name: 'E02.mkv'),
      TorrentFile(index: 2, name: 'E03.mkv'),
    ];

    /// Opens the sheet from a real route so it gets the focus scope a modal
    /// bottom sheet has in the app.
    Future<void> open(
      WidgetTester tester, {
      required int? currentIndex,
      required bool isTv,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTorrentFileSheet(
                  context,
                  files: files,
                  currentIndex: currentIndex,
                  isTv: isTv,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    String? focusedTile() {
      final context = FocusManager.instance.primaryFocus?.context;
      final title = context?.findAncestorWidgetOfExactType<ListTile>()?.title;
      return title is Text ? title.data : null;
    }

    testWidgets('on TV focus opens on the file that is playing', (
      tester,
    ) async {
      await open(tester, currentIndex: 1, isTv: true);
      expect(focusedTile(), 'E02.mkv');
    });

    testWidgets('on TV with nothing playing yet, focus opens on the first', (
      tester,
    ) async {
      await open(tester, currentIndex: null, isTv: true);
      expect(focusedTile(), 'E01.mkv');
    });

    testWidgets('off TV no row takes focus', (tester) async {
      await open(tester, currentIndex: 1, isTv: false);
      expect(focusedTile(), isNull);
    });
  });
}
