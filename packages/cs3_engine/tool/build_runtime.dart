// Builds the Java runtime the desktop engine runs on and puts it among this package's assets, so a
// macOS, Windows or Linux build of the app carries it and needs no Java on the user's machine.
//
//   dart run packages/cs3_engine/tool/build_runtime.dart [--java-home JDK]
//
// The runtime is a trimmed image of the JDK it is made from (jlink): every standard module, plus
// the JDK modules extensions are known to need (sun.misc.Unsafe, extra charsets, all locales), for
// that JDK's own platform and architecture. So run it with a JDK 17 or newer of the platform and
// architecture being built - CI installs one per build. It writes
// assets/runtime/runtime-<os>-<arch>.tar.gz and a .json beside it describing the archive.
//
// Without a runtime in the build, the app uses the machine's Java instead (see lib/cs3_engine.dart).
// Uses dart:io only, so it runs from anywhere with `dart run`.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

/// Every Java SE module, and the JDK modules extensions use: jdk.unsupported (sun.misc.Unsafe,
/// which Gson needs), jdk.crypto.ec (TLS), jdk.charsets (sites in legacy encodings),
/// jdk.localedata (dates and numbers in every language), jdk.dynalink (Rhino), jdk.zipfs.
const modules = [
  'java.se',
  'jdk.unsupported',
  'jdk.crypto.ec',
  'jdk.charsets',
  'jdk.localedata',
  'jdk.dynalink',
  'jdk.zipfs',
];

Future<void> main(List<String> args) async {
  final package = File.fromUri(Platform.script).parent.parent;
  final javaHome = _option(args, '--java-home') ?? await _findJdk();
  if (javaHome == null) {
    _fail('No JDK found. Pass --java-home, or set JAVA_HOME to a JDK 17 or newer that has a jmods '
        'folder (Temurin, Zulu...; Android Studio\'s bundled runtime has none).');
  }
  final bin = '$javaHome${Platform.pathSeparator}bin${Platform.pathSeparator}';
  final exe = Platform.isWindows ? '.exe' : '';
  if (!Directory('$javaHome${Platform.pathSeparator}jmods').existsSync()) {
    _fail('$javaHome has no jmods folder, which jlink needs. Use a full JDK (Temurin, Zulu...).');
  }

  final properties = await Process.run('${bin}java$exe', ['-XshowSettings:properties', '-version']);
  final settings = '${properties.stdout}${properties.stderr}';
  String property(String name) => RegExp('^\\s*${RegExp.escape(name)} = (.*)\$', multiLine: true)
      .firstMatch(settings)
      ?.group(1)
      ?.trim() ??
      '';
  final version = property('java.version');
  final feature = int.tryParse(version.split(RegExp(r'[.+-]')).first) ?? 0;
  if (feature < 17) _fail('$javaHome is Java $version; the engine needs 17 or newer.');
  final os = switch (property('os.name').toLowerCase()) {
    final name when name.startsWith('mac') => 'macos',
    final name when name.startsWith('windows') => 'windows',
    final name when name.startsWith('linux') => 'linux',
    final name => _fail('Unsupported platform: $name'),
  };
  final arch = switch (property('os.arch')) {
    'aarch64' || 'arm64' => 'arm64',
    'amd64' || 'x86_64' => 'x64',
    final other => _fail('Unsupported architecture: $other'),
  };

  final name = 'runtime-$os-$arch';
  final out = Directory('${package.path}/assets/runtime')..createSync(recursive: true);
  final work = Directory.systemTemp.createTempSync('cs3_runtime');
  try {
    final image = '${work.path}${Platform.pathSeparator}image';
    print('jlink: Java $version ($os $arch) from $javaHome');
    await _run('${bin}jlink$exe', [
      '--add-modules', modules.join(','),
      '--strip-debug', '--no-man-pages', '--no-header-files', '--compress', 'zip-9',
      '--output', image,
    ]);

    // Links (the legal notices) become plain files: the archive must unpack the same everywhere.
    final archive = File('${out.path}/$name.tar.gz');
    if (archive.existsSync()) archive.deleteSync();
    await _run(_tar(), ['-czhf', archive.path, '-C', image, '.']);

    final digest = await _sha256(archive);
    File('${out.path}/$name.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'java': version,
        'os': os,
        'arch': arch,
        'modules': modules,
        'size': archive.lengthSync(),
        'sha256': digest,
      }),
    );
    print('Wrote ${archive.path} (${(archive.lengthSync() / 1048576).toStringAsFixed(1)} MB)');
  } finally {
    work.deleteSync(recursive: true);
  }
}

String? _option(List<String> args, String name) {
  final index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
}

/// JAVA_HOME, then on macOS the newest JDK 21 or 17+ that java_home knows.
Future<String?> _findJdk() async {
  final fromEnvironment = Platform.environment['JAVA_HOME'];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) return fromEnvironment;
  if (Platform.isMacOS) {
    for (final version in ['21', '17+']) {
      final result = await Process.run('/usr/libexec/java_home', ['-v', version]);
      if (result.exitCode == 0) return (result.stdout as String).trim();
    }
  }
  return null;
}

/// SHA-256 with the platform's own tool (shasum, sha256sum or certutil): dart:io has none.
Future<String> _sha256(File file) async {
  final ProcessResult result;
  if (Platform.isWindows) {
    result = await Process.run('certutil', ['-hashfile', file.path, 'SHA256']);
    final line = (result.stdout as String).split('\n').map((l) => l.trim().replaceAll(' ', '')).firstWhere(
      (l) => RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(l),
      orElse: () => '',
    );
    if (line.isNotEmpty) return line.toLowerCase();
  } else {
    result = await Process.run(Platform.isMacOS ? 'shasum' : 'sha256sum', [
      if (Platform.isMacOS) ...['-a', '256'],
      file.path,
    ]);
    final hash = (result.stdout as String).split(' ').first.trim();
    if (RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) return hash;
  }
  _fail('Could not compute the SHA-256 of ${file.path}: ${result.stderr}');
}

/// Windows' own bsdtar: in a Git Bash step `tar` is GNU tar, which reads `C:\...` as a remote host.
String _tar() {
  if (!Platform.isWindows) return 'tar';
  final windows = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  return '$windows\\System32\\tar.exe';
}

Future<void> _run(String executable, List<String> arguments) async {
  final process = await Process.start(executable, arguments, mode: ProcessStartMode.inheritStdio);
  final code = await process.exitCode;
  if (code != 0) _fail('$executable exited with $code');
}

Never _fail(String message) {
  stderr.writeln('build_runtime: $message');
  exit(1);
}
