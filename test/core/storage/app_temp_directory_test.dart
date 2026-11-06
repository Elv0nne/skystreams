import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/storage/app_temp_directory.dart';
import 'package:skystream/core/storage/storage_service.dart';

/// The temporary directory of Linux (/tmp), macOS ($TMPDIR: the app isn't
/// sandboxed) and Windows (%TEMP%) is shared with every program the user runs.
/// Clearing SkyStream's cache, and resetting its data, deleted that whole
/// directory: other programs' sockets, locks and unfinished downloads went with
/// it. SkyStream now keeps its temporary files to a folder of its own and
/// clears only that.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory temp; // the platform's temporary directory
  late Directory cache; // the app's cache directory
  late Directory hive;

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('app_temp');
    temp = Directory(p.join(root.path, 'tmp'))..createSync();
    cache = Directory(p.join(root.path, 'cache'))..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => switch (call.method) {
            'getTemporaryDirectory' => temp.path,
            'getApplicationCacheDirectory' => cache.path,
            _ => p.join(root.path, 'other'),
          },
        );
    // The image cache keeps the path it was first built with, and makes its
    // folder without waiting: build it, and its folder, before any test runs
    // (see storage_box_recovery_test.dart).
    final images = DefaultCacheManager();
    try {
      await images.emptyCache();
    } catch (_) {
      // Its database can't open under flutter_test, as in every clear below.
    }
    await images.store.fileSystem.createFile('warm-up');
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  setUp(() {
    hive = Directory.systemTemp.createTempSync('app_temp_hive');
    Hive.init(hive.path);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    debugTempIsShared = null;
    await Hive.close();
    if (hive.existsSync()) hive.deleteSync(recursive: true);
    // Android's and iOS's clear deletes the whole temporary directory, the
    // image cache's folder with it: both come back for the next test.
    Directory(
      p.join(temp.path, DefaultCacheManager.key),
    ).createSync(recursive: true);
    for (final entity in temp.listSync()) {
      if (p.basename(entity.path) != DefaultCacheManager.key) {
        entity.deleteSync(recursive: true);
      }
    }
    for (final entity in cache.listSync()) {
      entity.deleteSync(recursive: true);
    }
  });

  File write(String path, int bytes) => File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(List.filled(bytes, 1));

  /// Another program's files in the shared temporary directory.
  List<File> othersFiles() => [
    write(p.join(temp.path, 'other-program.lock'), 1000),
    write(p.join(temp.path, 'tmux-1000', 'default'), 10),
  ];

  test('on a desktop, the temporary files go to a folder of their own in the '
      "app's cache directory", () async {
    expect((await appTempDirectory()).path, p.join(cache.path, 'temp'));
    expect(Directory(p.join(cache.path, 'temp')).existsSync(), isTrue);
  });

  test("clearing the cache leaves other programs' temporary files", () async {
    final others = othersFiles();
    final subtitle = write(
      p.join((await appTempDirectory()).path, 'temp_sub_1.srt'),
      100,
    );

    await StorageService().clearImageVideoCache();

    for (final file in others) {
      expect(file.existsSync(), isTrue, reason: '${file.path} was deleted');
    }
    expect(subtitle.existsSync(), isFalse);
  });

  test(
    "resetting SkyStream's data leaves other programs' temporary files",
    () async {
      final others = othersFiles();
      final download = write(
        p.join((await appTempDirectory()).path, 'temp_1.sky'),
        100,
      );

      await StorageService().clearPreferences(keepRepos: false);

      for (final file in others) {
        expect(file.existsSync(), isTrue, reason: '${file.path} was deleted');
      }
      expect(download.existsSync(), isFalse);
    },
  );

  test("the cache size counts SkyStream's temporary files and image cache, "
      "and nothing else in the temporary directory", () async {
    othersFiles();
    write(p.join((await appTempDirectory()).path, 'temp_sub_1.srt'), 100);
    write(p.join(temp.path, DefaultCacheManager.key, 'poster.jpg'), 10);
    addTearDown(
      () =>
          File(p.join(temp.path, DefaultCacheManager.key, 'poster.jpg'))
              .deleteSync(),
    );

    expect(await StorageService().computeImageVideoCacheBytes(), 110);
  });

  test('on Android and iOS the temporary directory is the app\'s own, and is '
      'used and cleared whole', () async {
    debugTempIsShared = false;
    expect((await appTempDirectory()).path, temp.path);

    final leftover = write(p.join(temp.path, 'temp_sub_1.srt'), 100);
    expect(await StorageService().computeImageVideoCacheBytes(), 100);

    await StorageService().clearImageVideoCache();
    expect(leftover.existsSync(), isFalse);
  });

  test(
    'lib/ reaches the temporary directory only through appTempDirectory',
    () {
      final lib = Directory('lib');
      expect(
        lib.existsSync(),
        isTrue,
        reason: 'run this from the package root',
      );
      final offenders = <String>[];
      for (final file in lib.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart') || file.path.endsWith('.g.dart')) {
          continue;
        }
        if (p.basename(file.path) == 'app_temp_directory.dart') continue;
        final source = file.readAsStringSync();
        if (source.contains('getTemporaryDirectory(') ||
            source.contains('Directory.systemTemp')) {
          offenders.add(file.path);
        }
      }
      expect(offenders, isEmpty);
    },
  );
}
