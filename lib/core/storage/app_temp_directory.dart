import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// SkyStream's own folder for temporary files, such as the subtitles it
/// downloads and plugins on their way to being installed. Clearing its cache
/// empties it.
///
/// Android's and iOS's temporary directory is the app's own, and is used
/// whole. On Linux (/tmp), macOS ($TMPDIR: the app isn't sandboxed) and
/// Windows (%TEMP%) it is shared with every program the user runs, so
/// SkyStream keeps to a `temp` folder in its own cache directory there:
/// clearing its cache must never delete another program's files.
Future<Directory> appTempDirectory() async {
  if (!_tempIsShared) return getTemporaryDirectory();
  final dir = Directory(
    p.join((await getApplicationCacheDirectory()).path, 'temp'),
  );
  await dir.create(recursive: true);
  return dir;
}

/// The folders SkyStream's cache is made of: its temporary files, and on the
/// desktops the image cache, which keeps its files in the shared temporary
/// directory under its own name. On Android and iOS the image cache is inside
/// [appTempDirectory] already.
Future<List<Directory>> appCacheDirectories() async => [
  await appTempDirectory(),
  if (_tempIsShared)
    Directory(
      p.join((await getTemporaryDirectory()).path, DefaultCacheManager.key),
    ),
];

/// Overrides, for tests, whether the platform's temporary directory is shared
/// with other programs.
@visibleForTesting
bool? debugTempIsShared;

bool get _tempIsShared =>
    debugTempIsShared ??
    (Platform.isLinux || Platform.isMacOS || Platform.isWindows);
