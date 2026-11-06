import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// Cheerio-compatible DOM backing for Nuvio scrapers.
///
/// Real Nuvio plugins are bundled with `cheerio-without-node-native`. Beyond
/// `load / $(sel) / find / attr / text` they routinely walk the tree
/// (`parent`, `closest`, `children`, `next`, `siblings`) and narrow selections
/// (`filter('a')`, `not('.x')`), so all of that is served here — package:html
/// does the work and JS only ever holds stable node ids, which keeps one
/// selector to one bridge call.
class NuvioDom {
  final Map<String, _Doc> _docs = {};
  int _seq = 0;

  String load(String html) {
    final id = 'd${++_seq}';
    _docs[id] = _Doc(html_parser.parse(html));
    return id;
  }

  void free(String docId) => _docs.remove(docId);

  void clear() => _docs.clear();

  /// Query within the document, or within [contextId] when provided.
  List<String> query(String docId, String? contextId, String selector) {
    final doc = _docs[docId];
    if (doc == null) return const [];

    final root = contextId == null || contextId.isEmpty
        ? null
        : doc.nodes[contextId];
    if (contextId != null && contextId.isNotEmpty && root == null) {
      return const [];
    }

    final Iterable<dom.Element> found;
    try {
      final stepped = _SteppedSelector.parse(selector);
      found = stepped != null
          ? _querySteps(doc, root, stepped)
          : root == null
          ? doc.document.querySelectorAll(selector)
          : root.querySelectorAll(selector);
    } catch (_) {
      // Cheerio tolerates selectors package:html rejects.
      return const [];
    }
    return [for (final element in found) doc.register(element)];
  }

  /// A selector matched step by step, as cheerio and Jsoup match it:
  /// package:html matches each step's compound on its own, the text a
  /// `:contains(...)` names narrows it, and the combinators are walked over
  /// whole sets, so no step settles for the nearest element that fits it.
  ///
  /// Under a context, as in cheerio's `find`, the context itself may take the
  /// first step but only elements inside it are found. Results come back once
  /// each, in document order.
  List<dom.Element> _querySteps(
    _Doc doc,
    dom.Element? root,
    _SteppedSelector selector,
  ) {
    final found = Set<dom.Element>.identity();
    for (final steps in selector.alternatives) {
      final first = steps.first;
      var current = <dom.Element>[
        if (root != null &&
            _matching(doc, first.css).contains(root) &&
            first.accepts(root))
          root,
        for (final element
            in root == null
                ? doc.document.querySelectorAll(first.css)
                : root.querySelectorAll(first.css))
          if (first.accepts(element)) element,
      ];
      for (final step in steps.skip(1)) {
        current = _follow(doc, current, step);
      }
      found.addAll(current);
    }
    if (root != null) found.removeWhere((element) => !_inside(element, root));
    final order = doc.documentOrder();
    return found.toList()
      ..sort((a, b) => (order[a] ?? 0).compareTo(order[b] ?? 0));
  }

  /// The elements [step] reaches from [current] through its combinator.
  List<dom.Element> _follow(_Doc doc, List<dom.Element> current, _Step step) {
    final matched = _matching(doc, step.css);
    bool fits(dom.Element element) =>
        matched.contains(element) && step.accepts(element);
    final from = Set<dom.Element>.identity()..addAll(current);
    final next = <dom.Element>[];
    final seen = Set<dom.Element>.identity();
    void add(dom.Element element) {
      if (seen.add(element)) next.add(element);
    }

    switch (step.combinator) {
      case '>':
        for (final element in current) {
          for (final child in element.children) {
            if (fits(child)) add(child);
          }
        }
      case '+':
        for (final element in current) {
          final sibling = _sibling(element, forward: true);
          if (sibling != null && fits(sibling)) add(sibling);
        }
      case '~':
        for (final element in current) {
          var sibling = _sibling(element, forward: true);
          // A later sibling that is itself in the set walks the rest.
          while (sibling != null && !from.contains(sibling)) {
            if (fits(sibling)) add(sibling);
            sibling = _sibling(sibling, forward: true);
          }
          if (sibling != null && fits(sibling)) add(sibling);
        }
      default:
        for (final element in matched) {
          if (!step.accepts(element)) continue;
          for (var up = element.parent; up != null; up = up.parent) {
            if (from.contains(up)) {
              add(element);
              break;
            }
          }
        }
    }
    return next;
  }

  static bool _inside(dom.Element element, dom.Element root) {
    for (var up = element.parent; up != null; up = up.parent) {
      if (identical(up, root)) return true;
    }
    return false;
  }

  /// package:html has no `Element.matches`, so "does this node match?" is
  /// answered by matching the selector once per document and testing identity.
  Set<dom.Element> _matching(_Doc doc, String selector) {
    final cached = doc.matchCache[selector];
    if (cached != null) return cached;
    Set<dom.Element> matched;
    try {
      final stepped = _SteppedSelector.parse(selector);
      matched = Set<dom.Element>.identity()
        ..addAll(
          stepped != null
              ? _querySteps(doc, null, stepped)
              : doc.document.querySelectorAll(selector),
        );
    } catch (_) {
      matched = Set<dom.Element>.identity();
    }
    doc.matchCache[selector] = matched;
    return matched;
  }

  /// `selection.filter('sel')` / `.not('sel')` / `.is('sel')`.
  List<String> filter(String docId, List<String> nodeIds, String selector) {
    final doc = _docs[docId];
    if (doc == null) return const [];
    final matched = _matching(doc, selector);
    final out = <String>[];
    for (final id in nodeIds) {
      final element = doc.nodes[id];
      if (element != null && matched.contains(element)) out.add(id);
    }
    return out;
  }

  /// Tree walking: `parent`, `parents`, `closest`, `children`, `next`,
  /// `nextAll`, `prev`, `prevAll`, `siblings`, plus `index`.
  List<String> relation(
    String docId,
    List<String> nodeIds,
    String kind,
    String? selector,
  ) {
    final doc = _docs[docId];
    if (doc == null) return const [];

    final matchSet = (selector == null || selector.isEmpty)
        ? null
        : _matching(doc, selector);
    bool matches(dom.Element element) =>
        matchSet == null || matchSet.contains(element);

    final out = <String>[];
    final seen = <String>{};
    void add(dom.Element? element) {
      if (element == null || !matches(element)) return;
      final id = doc.register(element);
      if (seen.add(id)) out.add(id);
    }

    for (final id in nodeIds) {
      final element = doc.nodes[id];
      if (element == null) continue;
      switch (kind) {
        case 'parent':
          add(element.parent);
        case 'parents':
          var current = element.parent;
          while (current != null) {
            add(current);
            current = current.parent;
          }
        case 'closest':
          dom.Element? current = element;
          while (current != null) {
            if (matches(current)) {
              add(current);
              break;
            }
            current = current.parent;
          }
        case 'children':
          for (final child in element.children) {
            add(child);
          }
        case 'next':
          add(_sibling(element, forward: true));
        case 'nextAll':
          var next = _sibling(element, forward: true);
          while (next != null) {
            add(next);
            next = _sibling(next, forward: true);
          }
        case 'prev':
          add(_sibling(element, forward: false));
        case 'prevAll':
          var prev = _sibling(element, forward: false);
          while (prev != null) {
            add(prev);
            prev = _sibling(prev, forward: false);
          }
        case 'siblings':
          final parent = element.parent;
          if (parent != null) {
            for (final child in parent.children) {
              if (!identical(child, element)) add(child);
            }
          }
        case 'index':
          final parent = element.parent;
          out.add(
            parent == null ? '-1' : '${parent.children.indexOf(element)}',
          );
      }
    }
    return out;
  }

  static dom.Element? _sibling(dom.Element element, {required bool forward}) {
    final parent = element.parent;
    if (parent == null) return null;
    final siblings = parent.children;
    final index = siblings.indexOf(element);
    if (index < 0) return null;
    final target = forward ? index + 1 : index - 1;
    if (target < 0 || target >= siblings.length) return null;
    return siblings[target];
  }

  String? attr(String docId, String nodeId, String name) =>
      _docs[docId]?.nodes[nodeId]?.attributes[name];

  String text(String docId, String nodeId) =>
      _docs[docId]?.nodes[nodeId]?.text ?? '';

  /// cheerio concatenates the text of every node in the selection.
  String textOf(String docId, List<String> nodeIds) {
    final doc = _docs[docId];
    if (doc == null) return '';
    if (nodeIds.isEmpty) {
      return doc.document.body?.text ?? doc.document.text ?? '';
    }
    final buffer = StringBuffer();
    for (final id in nodeIds) {
      buffer.write(doc.nodes[id]?.text ?? '');
    }
    return buffer.toString();
  }

  /// Empty [nodeId] means "the whole document", matching `$.html()`.
  String html(String docId, String nodeId) {
    final doc = _docs[docId];
    if (doc == null) return '';
    if (nodeId.isEmpty) return doc.document.outerHtml;
    return doc.nodes[nodeId]?.innerHtml ?? '';
  }

  /// Tag names of [nodeIds], lower-case, as cheerio's nodes carry them.
  List<String> tagsOf(String docId, List<String> nodeIds) {
    final doc = _docs[docId];
    if (doc == null) return const [];
    return [for (final id in nodeIds) doc.nodes[id]?.localName ?? ''];
  }

  /// Everything the JS side needs about a batch of nodes in one call: cuts the
  /// bridge chatter that would otherwise dominate a big page.
  String describeBatch(String docId, List<String> nodeIds) {
    final doc = _docs[docId];
    if (doc == null) return '[]';
    return jsonEncode([
      for (final id in nodeIds)
        if (doc.nodes[id] case final element?)
          {
            'id': id,
            'tag': element.localName ?? '',
            'text': element.text,
            'attrs': element.attributes.map(
              (key, value) => MapEntry(key.toString(), value),
            ),
          },
    ]);
  }

  int get documentCount => _docs.length;
}

class _Doc {
  _Doc(this.document);

  final dom.Document document;
  final Map<String, dom.Element> nodes = {};
  final Map<String, Set<dom.Element>> matchCache = {};
  final Map<dom.Element, String> _ids = {};
  int _seq = 0;
  Map<dom.Element, int>? _order;

  /// Each element's position in the document, for putting a merged match set
  /// back in order.
  Map<dom.Element, int> documentOrder() {
    final cached = _order;
    if (cached != null) return cached;
    final order = Map<dom.Element, int>.identity();
    var index = 0;
    for (final element in document.querySelectorAll('*')) {
      order[element] = index++;
    }
    return _order = order;
  }

  String register(dom.Element element) {
    final existing = _ids[element];
    if (existing != null) return existing;
    final id = 'n${++_seq}';
    nodes[id] = element;
    _ids[element] = id;
    return id;
  }
}

/// A selector package:html cannot be left to match on its own.
///
/// package:html matches right to left and settles each descendant or `~` step
/// on the nearest element that fits it, never trying one further out: HDHub4u's
/// `.page-body > div a` missed every link whose nearest div was not the one
/// under `.page-body`. So any selector with a combinator is split into its
/// compound steps, which package:html does match correctly.
///
/// So is one with jQuery's `:contains(text)`, which cheerio accepts, and so
/// does the Nuvio app's Jsoup that the scrapers are tested against, while
/// package:html rejects the whole selector. It is read as Jsoup reads it:
/// case-insensitive, whitespace collapsed, over the element's own text and its
/// descendants'. The argument may be in double or single quotes or bare -
/// `script:contains(?go=)` is.
class _SteppedSelector {
  _SteppedSelector(this.alternatives);

  /// `a, b` is two alternatives; each is its steps, joined by combinators.
  final List<List<_Step>> alternatives;

  static const String _marker = ':contains(';

  /// Null for a selector package:html matches correctly as it is: compounds
  /// alone, without `:contains`.
  static _SteppedSelector? parse(String selector) {
    final alternatives = <List<_Step>>[];
    for (final part in _split(selector)) {
      final steps = _steps(part);
      if (steps.isEmpty) return null;
      alternatives.add(steps);
    }
    final stepped =
        selector.contains(_marker) ||
        alternatives.any((steps) => steps.length > 1);
    return stepped ? _SteppedSelector(alternatives) : null;
  }

  /// [selector]'s comma-separated alternatives, ignoring commas in quotes,
  /// brackets and parentheses.
  static List<String> _split(String selector) {
    final parts = <String>[];
    final buffer = StringBuffer();
    var depth = 0;
    String? quote;
    for (var i = 0; i < selector.length; i++) {
      final c = selector[i];
      if (quote != null) {
        buffer.write(c);
        if (c == quote) quote = null;
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '(' || c == '[') {
        depth++;
      } else if (c == ')' || c == ']') {
        depth--;
      } else if (c == ',' && depth == 0) {
        parts.add(buffer.toString().trim());
        buffer.clear();
        continue;
      }
      buffer.write(c);
    }
    parts.add(buffer.toString().trim());
    return [
      for (final part in parts)
        if (part.isNotEmpty) part,
    ];
  }

  /// One alternative's compound selectors and the combinators between them.
  static List<_Step> _steps(String selector) {
    final steps = <_Step>[];
    final buffer = StringBuffer();
    var depth = 0;
    String? quote;
    var combinator = '';
    var pending = '';

    void flush() {
      if (buffer.isEmpty) return;
      steps.add(_Step.of(combinator, buffer.toString()));
      buffer.clear();
      combinator = '';
    }

    for (var i = 0; i < selector.length; i++) {
      final c = selector[i];
      if (quote != null) {
        buffer.write(c);
        if (c == quote) quote = null;
        continue;
      }
      if (depth == 0 && (c == '>' || c == '+' || c == '~')) {
        flush();
        pending = c;
        continue;
      }
      if (depth == 0 && c.trim().isEmpty) {
        if (buffer.isNotEmpty) {
          flush();
          if (pending.isEmpty) pending = ' ';
        }
        continue;
      }
      if (buffer.isEmpty && steps.isNotEmpty) {
        combinator = pending.isEmpty ? ' ' : pending;
      }
      pending = '';
      if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '(' || c == '[') {
        depth++;
      } else if (c == ')' || c == ']') {
        depth--;
      }
      buffer.write(c);
    }
    flush();
    return steps;
  }
}

class _Step {
  _Step(this.combinator, this.css, this.texts);

  /// Takes the `:contains(...)` pseudo-classes out of one compound selector.
  factory _Step.of(String combinator, String compound) {
    final texts = <String>[];
    final css = StringBuffer();
    var i = 0;
    while (i < compound.length) {
      final at = compound.indexOf(_SteppedSelector._marker, i);
      if (at < 0) {
        css.write(compound.substring(i));
        break;
      }
      css.write(compound.substring(i, at));
      var j = at + _SteppedSelector._marker.length;
      final argument = StringBuffer();
      String? quote;
      var depth = 0;
      while (j < compound.length) {
        final c = compound[j];
        if (quote != null) {
          if (c == quote) {
            quote = null;
          } else {
            argument.write(c);
          }
        } else if (c == '"' || c == "'") {
          quote = c;
        } else if (c == '(') {
          depth++;
          argument.write(c);
        } else if (c == ')') {
          if (depth == 0) break;
          depth--;
          argument.write(c);
        } else {
          argument.write(c);
        }
        j++;
      }
      texts.add(_normalise(argument.toString()));
      i = j + 1;
    }
    final rest = css.toString().trim();
    return _Step(combinator, rest.isEmpty ? '*' : rest, texts);
  }

  /// `''` for the first step, then ` `, `>`, `+` or `~`.
  final String combinator;

  /// What package:html matches: never empty.
  final String css;

  /// Texts the element must contain, normalised.
  final List<String> texts;

  bool accepts(dom.Element element) {
    if (texts.isEmpty) return true;
    final text = _normalise(element.text);
    return texts.every(text.contains);
  }

  static String _normalise(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
}
