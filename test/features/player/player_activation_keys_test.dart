import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/widgets/player_activation.dart';

/// Guards the rule that made Skip Intro, Play now, Cancel and Start Over dead
/// controls on a game controller: **a player control that activates on Select
/// must activate on a controller's A as well.**
///
/// A D-pad "OK" is not one key. A television remote sends
/// `LogicalKeyboardKey.select`, a keyboard sends enter or space, and a Shield
/// remote, an Xbox or PlayStation pad, and every Android TV device whose HID
/// layer reports DPAD_CENTER as BUTTON_A send `LogicalKeyboardKey.gameButtonA`.
/// Nothing higher up rescues a miss: WidgetsApp binds gameButtonA to an
/// ActivateIntent but its default actions map ships no ActivateAction, and in
/// these widgets the `Focus` sits above the `InkWell`, so the InkWell's own
/// `Actions` map is a descendant of the focused node and is never reached. The
/// failure is therefore total and silent - and it looked random, because the
/// bottom bar (Material `TextButton`s, whose `Actions` really is an ancestor)
/// kept working while the overlays did not.
///
/// This is a line-oriented heuristic over formatted source, not an AST. For
/// each `LogicalKeyboardKey.select` it reads forward to the end of the
/// enclosing condition - the first line that opens a block, at most eight
/// lines - and requires `LogicalKeyboardKey.gameButtonA` inside that slice.
/// The clean way to satisfy it is not to spell the keys out at all but to call
/// [isPlayerActivation], which is why the shared predicate is pinned below
/// too: a guard over source text is worthless if the helper it points at can
/// quietly lose a key.
void main() {
  test('every player control that takes Select also takes a controller A', () {
    final Directory root = Directory('lib/features/player');
    expect(
      root.existsSync(),
      isTrue,
      reason: 'run this from the package root so lib/ resolves',
    );

    final offenders = <String>[];
    for (final entity in root.listSync(recursive: true).whereType<File>()) {
      if (!entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('LogicalKeyboardKey.select')) continue;
        final buffer = StringBuffer();
        for (var j = i; j < lines.length && j < i + 8; j++) {
          buffer.writeln(lines[j]);
          if (lines[j].contains('{')) break;
        }
        if (buffer.toString().contains('LogicalKeyboardKey.gameButtonA')) {
          continue;
        }
        offenders.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'these handlers answer a remote but not a game controller. Call '
          'isPlayerActivation(key) from '
          'lib/features/player/presentation/widgets/player_activation.dart '
          'instead of spelling the keys out:\n${offenders.join('\n')}',
    );
  });

  group('isPlayerActivation', () {
    test('takes all four activation keys', () {
      expect(isPlayerActivation(LogicalKeyboardKey.select), isTrue);
      expect(isPlayerActivation(LogicalKeyboardKey.enter), isTrue);
      expect(isPlayerActivation(LogicalKeyboardKey.space), isTrue);
      expect(
        isPlayerActivation(LogicalKeyboardKey.gameButtonA),
        isTrue,
        reason: 'the key the whole guard above exists for',
      );
    });

    test('claims nothing a control has to leave to traversal', () {
      expect(isPlayerActivation(LogicalKeyboardKey.arrowUp), isFalse);
      expect(isPlayerActivation(LogicalKeyboardKey.arrowDown), isFalse);
      expect(isPlayerActivation(LogicalKeyboardKey.arrowLeft), isFalse);
      expect(isPlayerActivation(LogicalKeyboardKey.arrowRight), isFalse);
      // Back is the escape hatch out of every overlay; an activation that
      // swallowed it would trap the remote.
      expect(isPlayerActivation(LogicalKeyboardKey.goBack), isFalse);
      expect(isPlayerActivation(LogicalKeyboardKey.escape), isFalse);
      // B is Cancel on a controller, not Select.
      expect(isPlayerActivation(LogicalKeyboardKey.gameButtonB), isFalse);
    });
  });
}
