import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards against the dialog-controller lifetime bug that crashed the iOS
/// build: a controller created in a function, handed to a dialog, and
/// disposed as soon as `await showDialog` returned - while the dialog was
/// still mounted for its exit transition. The rule is that every such
/// controller is owned by a `State`, so it is disposed when its element
/// unmounts and never earlier.
///
/// This is a line-oriented heuristic over formatted source, not an AST. It
/// reads each file once to learn, per line, the enclosing column-0
/// declaration, the brace depth relative to it, and the class member whose
/// body the line sits in. Strings and `//` comments are stripped before
/// braces are counted; multi-line strings are not understood.
///
/// Rules, in the order they are checked:
///
///  1. Every `TextEditingController(` and `TextEditingController.fromValue(`
///     must sit inside a `class ... State<` (plain or `ConsumerState`).
///  2. Its assignment target must be a private field - `_name`, optionally
///     typed/`late`/`final`, optionally indexed like `_controllers[key]`.
///     A target that carries a declaration keyword or type (`final _c =`,
///     `TextEditingController _c =`) is only a field when it sits directly in
///     the class body; the same text inside a method body is a local and is
///     flagged. A bare `_c =` inside a method is an assignment to a field.
///  3. `.dispose()` on an identifier known to hold a TextEditingController may
///     only appear inside a member named `dispose()`. An identifier is
///     "known" when it is the target of a creation in rule 1, is declared
///     with an explicit `TextEditingController` type, or is the loop variable
///     of a `for (... in known)` / `for (... in known.values)`. One shape is
///     exempt: a method that disposes controllers and then, later in the same
///     body, calls `.clear()` and creates new ones is rebuilding a controller
///     map in place (plugin_settings_screen `_load()`), not tying a lifetime
///     to a dialog.
///  4. A `ScrollController(` or `FocusNode(` declared as a local (a
///     declaration keyword or type, inside a member body) must not be
///     referenced inside the argument list of a `showDialog` or
///     `showModalBottomSheet` call in the same body. State fields and
///     assignments in `initState` carry no keyword and are never matched.
///
/// What it still cannot see: a controller whose type is only inferred from a
/// non-constructor expression (`final c = widget.controller`); controllers
/// reached through a collection other than a `.values` loop; a fallback
/// controller swapped in `didUpdateWidget` (rule 3 will flag it - give the
/// widget a State-owned field instead); the rule 3 exemption is satisfied by
/// any body that clears a collection and creates a controller, so a
/// `showDialog` in such a body goes unchecked; a ScrollController or
/// FocusNode created in a top-level helper and passed into a dialog through a
/// parameter rather than a closure; and `showGeneralDialog` or other
/// route-opening helpers not named in rule 4.
void main() {
  test('dialog-lifetime controllers in lib/ are owned by a State', () {
    final Directory lib = Directory('lib');
    expect(
      lib.existsSync(),
      isTrue,
      reason: 'run this from the package root so lib/ resolves',
    );

    final List<String> offenders = <String>[];

    for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String relative = entity.path.replaceAll(
        Platform.pathSeparator,
        '/',
      );
      final _Scan scan = _Scan(entity.readAsLinesSync());

      for (final _Finding f in <_Finding>[
        ...scan.textEditingControllerCreations(),
        ...scan.earlyTextEditingControllerDisposes(),
        ...scan.localsHandedToDialogs(),
      ]) {
        offenders.add(
          '$relative:${f.line + 1}: ${f.reason}\n    ${scan.lines[f.line].trim()}',
        );
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Controllers that outlive a function must be owned by a State (a '
          'private field, disposed in dispose()). For a one-off prompt use '
          'lib/shared/widgets/text_input_dialog.dart or give the dialog its '
          'own StatefulWidget.\n\n${offenders.join('\n')}',
    );
  });
}

class _Finding {
  final int line;
  final String reason;
  const _Finding(this.line, this.reason);
}

/// Where an identifier is known to hold a TextEditingController: the whole
/// enclosing declaration for fields, the enclosing member body for loop
/// variables.
class _Typed {
  final String name;
  final int from;
  final int to;
  const _Typed(this.name, this.from, this.to);
}

class _Scan {
  final List<String> lines;

  /// Index of the enclosing column-0 declaration, or -1 before the first.
  final List<int> declaration;

  /// Brace depth at the start of the line, relative to [declaration].
  final List<int> depth;

  /// Index of the line that opened the enclosing member body, or -1 when the
  /// line is at declaration level (class body or top level).
  final List<int> member;

  _Scan._(this.lines, this.declaration, this.depth, this.member);

  factory _Scan(List<String> lines) {
    final List<int> declaration = List<int>.filled(lines.length, -1);
    final List<int> depth = List<int>.filled(lines.length, 0);
    final List<int> member = List<int>.filled(lines.length, -1);

    int decl = -1;
    int d = 0;
    int memberDepth = 0;
    int open = -1;
    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i];
      if (_declaration.hasMatch(line)) {
        decl = i;
        d = 0;
        open = -1;
        memberDepth = _classLike.hasMatch(line) ? 1 : 0;
      }
      final String code = _stripStringsAndComments(line);
      final int opens = code.split('{').length - 1;
      final int closes = code.split('}').length - 1;

      declaration[i] = decl;
      depth[i] = d;
      if (open == -1 && d == memberDepth && opens > closes) {
        open = i;
      }
      member[i] = open;

      d += opens - closes;
      if (d <= memberDepth) open = -1;
    }
    return _Scan._(lines, declaration, depth, member);
  }

  bool _isComment(int i) => lines[i].trimLeft().startsWith('//');

  /// Class headers wrap when the name is long, so read through to the
  /// opening brace before deciding what the class extends.
  String _declarationHeader(int decl) {
    final StringBuffer header = StringBuffer(lines[decl]);
    for (
      int k = decl + 1;
      k < lines.length && !lines[k - 1].contains('{');
      k++
    ) {
      header.write(' ${lines[k]}');
    }
    return header.toString();
  }

  int _declarationEnd(int decl) {
    for (int k = decl + 1; k < lines.length; k++) {
      if (_declaration.hasMatch(lines[k])) return k - 1;
    }
    return lines.length - 1;
  }

  /// Last line of the member body opened at [open].
  int _memberEnd(int open) {
    for (int k = open + 1; k < lines.length; k++) {
      if (member[k] != open) return k - 1;
    }
    return lines.length - 1;
  }

  /// The member's signature, read back from its opening brace to the first
  /// line at member indentation so wrapped parameter lists are included.
  String _memberHeader(int open) {
    final int decl = declaration[open];
    final RegExp start = _classLike.hasMatch(lines[decl])
        ? RegExp(r'^  [A-Za-z_]')
        : RegExp(r'^[A-Za-z_]');
    int k = open;
    while (k > decl && !start.hasMatch(lines[k])) {
      k--;
    }
    return lines.sublist(k, open + 1).join(' ');
  }

  bool _isLocalDeclaration(int i, String target) =>
      member[i] != -1 && _declaredWithKeywordOrType.hasMatch(target);

  Iterable<_Finding> textEditingControllerCreations() sync* {
    for (int i = 0; i < lines.length; i++) {
      if (_isComment(i)) continue;
      final Match? at = _textEditingControllerCtor.firstMatch(lines[i]);
      if (at == null) continue;
      final String target = lines[i].substring(0, at.start);

      final int decl = declaration[i];
      if (decl == -1 || !_stateClass.hasMatch(_declarationHeader(decl))) {
        yield _Finding(i, 'created outside a State subclass');
        continue;
      }
      if (!_privateFieldTarget.hasMatch(target)) {
        yield _Finding(i, 'assigned to a local, not a State field');
        continue;
      }
      if (_isLocalDeclaration(i, target)) {
        yield _Finding(i, 'declared as a local inside a method body');
      }
    }
  }

  List<_Typed> _typedIdentifiers() {
    final List<_Typed> typed = <_Typed>[];
    for (int i = 0; i < lines.length; i++) {
      if (_isComment(i)) continue;
      final String line = lines[i];
      final int decl = declaration[i];
      if (decl == -1) continue;
      final int end = _declarationEnd(decl);

      final Match? ctor = _textEditingControllerCtor.firstMatch(line);
      if (ctor != null) {
        final Match? target = _assignmentTarget.firstMatch(
          line.substring(0, ctor.start),
        );
        if (target != null) typed.add(_Typed(target.group(1)!, decl, end));
      }
      for (final Match m in _explicitlyTyped.allMatches(line)) {
        typed.add(_Typed(m.group(1)!, decl, end));
      }
    }
    // Loop variables are added after every field is known, since a loop can
    // sit above the field it iterates.
    for (int i = 0; i < lines.length; i++) {
      if (_isComment(i) || member[i] == -1) continue;
      final Match? loop = _forIn.firstMatch(lines[i]);
      if (loop == null) continue;
      final String source = loop.group(2)!;
      final bool known = typed.any(
        (t) => t.name == source && t.from <= i && i <= t.to,
      );
      if (known) {
        typed.add(_Typed(loop.group(1)!, member[i], _memberEnd(member[i])));
      }
    }
    return typed;
  }

  Iterable<_Finding> earlyTextEditingControllerDisposes() sync* {
    final List<_Typed> typed = _typedIdentifiers();
    if (typed.isEmpty) return;

    for (int i = 0; i < lines.length; i++) {
      if (_isComment(i)) continue;
      final Match? call = _disposeCall.firstMatch(lines[i]);
      if (call == null) continue;
      final String name = call.group(1)!;
      final bool known = typed.any(
        (t) => t.name == name && t.from <= i && i <= t.to,
      );
      if (!known) continue;

      final int open = member[i];
      if (open != -1 && _disposeMember.hasMatch(_memberHeader(open))) continue;
      if (open != -1 && _rebuildsInPlace(i, _memberEnd(open))) continue;

      yield _Finding(
        i,
        'TextEditingController disposed outside dispose(); the widget tree '
        'may still be mounted',
      );
    }
  }

  bool _rebuildsInPlace(int from, int to) {
    bool cleared = false;
    bool recreated = false;
    for (int k = from + 1; k <= to; k++) {
      if (_isComment(k)) continue;
      cleared |= lines[k].contains('.clear()');
      recreated |= _textEditingControllerCtor.hasMatch(lines[k]);
    }
    return cleared && recreated;
  }

  Iterable<_Finding> localsHandedToDialogs() sync* {
    for (int i = 0; i < lines.length; i++) {
      if (_isComment(i) || member[i] == -1) continue;
      final Match? local = _localScrollOrFocus.firstMatch(lines[i]);
      if (local == null) continue;
      final String name = local.group(1)!;
      final RegExp use = RegExp('\\b${RegExp.escape(name)}\\b');
      final int end = _memberEnd(member[i]);

      for (int k = i + 1; k <= end; k++) {
        if (_isComment(k)) continue;
        final Match? show = _showCall.firstMatch(lines[k]);
        if (show == null) continue;
        final int last = _callEnd(k, show.end - 1, end);
        for (int u = k; u <= last; u++) {
          if (!_isComment(u) && use.hasMatch(lines[u])) {
            yield _Finding(
              i,
              'function-local ${local.group(2)} referenced inside '
              '${show.group(1)} at line ${u + 1}; the dialog outlives this '
              'function, so give it a State that owns the controller',
            );
            break;
          }
        }
      }
    }
  }

  /// Last line of the call whose opening parenthesis is at [lines[k][col]].
  int _callEnd(int k, int col, int limit) {
    int balance = 0;
    for (int u = k; u <= limit; u++) {
      final String code = _stripStringsAndComments(lines[u]);
      final int start = u == k ? col : 0;
      for (int c = start; c < code.length; c++) {
        if (code[c] == '(') balance++;
        if (code[c] == ')') balance--;
        if (balance == 0) return u;
      }
    }
    return limit;
  }
}

String _stripStringsAndComments(String line) {
  final String noStrings = line
      .replaceAll(_singleQuoted, "''")
      .replaceAll(_doubleQuoted, '""');
  final int comment = noStrings.indexOf('//');
  return comment == -1 ? noStrings : noStrings.substring(0, comment);
}

/// A column-0 line that opens a declaration. Skips `}`, annotations, doc
/// comments and directives so the walk lands on the enclosing class or
/// function rather than a stray closing brace.
final RegExp _declaration = RegExp(r'^[A-Za-z_]');
final RegExp _classLike = RegExp(
  r'^(?:(?:abstract|base|final|sealed|interface|mixin)\s+)*(?:class|mixin|extension|enum)\s',
);
final RegExp _stateClass = RegExp(r'^(?:abstract\s+)?class\s.*State<');
final RegExp _textEditingControllerCtor = RegExp(
  r'TextEditingController(?:\.fromValue)?\(',
);
final RegExp _privateFieldTarget = RegExp(
  r'^\s*(?:late\s+)?(?:final\s+)?(?:[A-Za-z_][\w<>, ?]*\s+)?_\w+\s*(?:\[[^\]]*\])?\s*=\s*$',
);
final RegExp _declaredWithKeywordOrType = RegExp(
  r'^\s*(?:(?:late|final|var)\s+|[A-Za-z_][\w<>, ?]*\s+)+_?\w+\s*(?:\[[^\]]*\])?\s*=\s*$',
);
final RegExp _assignmentTarget = RegExp(r'(\w+)\s*(?:\[[^\]]*\])?\s*=\s*$');
final RegExp _explicitlyTyped = RegExp(
  r'\bTextEditingController\??\s+([A-Za-z_]\w*)\b',
);
final RegExp _forIn = RegExp(
  r'\bfor\s*\(\s*(?:final|var|[A-Za-z_][\w<>?]*)\s+(\w+)\s+in\s+(\w+)(?:\.values)?\s*\)',
);
final RegExp _disposeCall = RegExp(r'\b(\w+)[?!]?\.dispose\(\)');
final RegExp _disposeMember = RegExp(r'\bdispose\(\)');
final RegExp _localScrollOrFocus = RegExp(
  r'^\s*(?:(?:late|final|var)\s+|(?:ScrollController|FocusNode)\??\s+)+(\w+)\s*=\s*(ScrollController|FocusNode)\(',
);
final RegExp _showCall = RegExp(
  r'\b(showDialog|showModalBottomSheet)\b[^(]*\(',
);
final RegExp _singleQuoted = RegExp(r"'(?:[^'\\]|\\.)*'");
final RegExp _doubleQuoted = RegExp(r'"(?:[^"\\]|\\.)*"');
