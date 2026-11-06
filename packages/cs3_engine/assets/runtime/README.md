The Java runtime desktop builds bundle: `runtime-<os>-<arch>.tar.gz` and its `.json`, written by
`tool/build_runtime.dart` (see BUILD_INSTRUCTIONS.md) and not committed. Without one, the app uses
the machine's Java 17 or newer. This file keeps the folder, which pubspec.yaml lists, in place.
