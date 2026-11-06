import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every method the desktop plugins' channel handlers call on a player is one
/// its player class defines.
///
/// The Windows and Linux plugins wrap the shared core in a class of their own,
/// and no Dart test compiles them: a handler that calls a method the wrapper
/// never got builds nowhere but on a desktop, as `SeekToFraction` didn't on
/// the Windows VM (P1 plan, Task 18). So the calls and the definitions are
/// compared as source.
void main() {
  for (final (platform, path, className) in const [
    ('Windows', 'windows/vlc_player_plugin.cpp', 'WindowsVlcPlayer'),
    ('Linux', 'linux/vlc_player_plugin.cc', 'LinuxVlcPlayer'),
  ]) {
    test('$platform: the handler calls only what $className defines', () {
      final source = File(path).readAsStringSync();
      final called = {
        for (final match in RegExp(r'player->(\w+)\(').allMatches(source))
          match.group(1)!,
      };
      final defined = _definedMethods(_classBody(source, 'class $className'));

      expect(called, isNotEmpty);
      expect(called.difference(defined), isEmpty);
    });
  }
}

/// The body of the class declared at [declaration], brace-matched.
String _classBody(String source, String declaration) {
  // Not the forward declaration, which ends in a semicolon.
  final at = RegExp('${RegExp.escape(declaration)}[\\s:{]').firstMatch(source);
  if (at == null) fail('Could not find $declaration.');
  final start = source.indexOf('{', at.start);
  var depth = 0;
  for (var index = start; index < source.length; index += 1) {
    final char = source.codeUnitAt(index);
    if (char == 0x7b) depth += 1;
    if (char == 0x7d) {
      depth -= 1;
      if (depth == 0) return source.substring(start, index + 1);
    }
  }
  fail('Could not find the end of $declaration.');
}

/// The names of the member functions [body] defines: a return type, the
/// name, its parameters and an opening brace, as the wrappers write them.
Set<String> _definedMethods(String body) => {
  for (final match in RegExp(
    r'^\s+[\w:<>*&]+(?:\s+[\w:<>*&]+)*\s+[*&]?(\w+)\(([^;{}]*)\)\s*(?:const\s*)?\{',
    multiLine: true,
  ).allMatches(body))
    match.group(1)!,
};
