import 'dart:async';
import 'dart:convert';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/material.dart';

import 'test_site.dart';

/// A harness for the plugin on a real engine: drive a page against the local test site, show it,
/// and move in and out of it with the keyboard or a D-pad. Every event is logged, and printed with
/// a `CB-HARNESS` prefix for tests that watch from outside.
void main() => runApp(const HarnessApp());

const _strings = ChallengeSheetStrings(
  note: 'The site checks that you are a person. Tick the box to continue.',
  retry: 'Retry',
  fullScreen: 'Full screen',
  exitFullScreen: 'Exit full screen',
  close: 'Close',
  done: 'Done',
  verified: 'Verified',
);

class HarnessApp extends StatelessWidget {
  const HarnessApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Challenge browser',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
    home: const Harness(),
  );
}

class Harness extends StatefulWidget {
  const Harness({super.key});

  @override
  State<Harness> createState() => _HarnessState();
}

class _HarnessState extends State<Harness> {
  TestSite? _site;
  ChallengeBrowser? _browser;
  StreamSubscription<BrowserEvent>? _events;
  bool _shown = false;
  bool _capturing = false;
  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    TestSite.start().then((site) {
      if (mounted) setState(() => _site = site);
    });
    FocusManager.instance.addListener(_logFocus);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_logFocus);
    _events?.cancel();
    _browser?.dispose();
    _site?.close();
    super.dispose();
  }

  void _note(String line) {
    debugPrint('CB-HARNESS $line');
    if (!mounted) return;
    setState(() {
      _log.insert(0, line);
      if (_log.length > 60) _log.removeLast();
    });
  }

  void _logFocus() => _note('focus ${_label(FocusManager.instance.primaryFocus)}');

  /// The focused control's text, "page" for a shown page, or its focus node's label.
  static String _label(FocusNode? node) {
    if (node == null) return '-';
    final context = node.context;
    if (context != null && context.findAncestorWidgetOfExactType<ChallengeBrowserView>() != null) return 'page';
    String? text;
    void visit(Element element) {
      if (text != null) return;
      final widget = element.widget;
      if (widget is Text) {
        text = widget.data;
        return;
      }
      element.visitChildren(visit);
    }

    if (context is Element) visit(context);
    return text ?? node.debugLabel ?? '-';
  }

  Future<void> _run(String label, Future<String?> Function(ChallengeBrowser browser) action) async {
    final browser = _browser;
    if (browser == null) return _note('$label: create a page first');
    try {
      final result = await action(browser);
      _note(result == null ? label : '$label: $result');
    } catch (error) {
      _note('$label failed: $error');
    }
  }

  Future<void> _create() async {
    await _dispose();
    final browser = await ChallengeBrowser.create();
    _events = browser.events.listen((event) => _note(_describe(event)));
    setState(() => _browser = browser);
    _note('created page ${browser.id}');
  }

  Future<void> _dispose() async {
    final browser = _browser;
    if (browser == null) return;
    setState(() {
      _browser = null;
      _shown = false;
      _capturing = false;
    });
    await _events?.cancel();
    await browser.dispose();
    _note('disposed page ${browser.id}');
  }

  String _describe(BrowserEvent event) => switch (event) {
    PageStarted(:final url) => 'started ${url.path}',
    PageFinished(:final url) => 'finished ${url.path}',
    PageError(:final url, :final code, :final text) => 'error $code $text (${url?.path})',
    PageProgress(:final value) => 'progress ${(value * 100).round()}%',
    RendererGone(:final crashed) => 'renderer gone (crashed: $crashed)',
    ScriptMessage(:final message) => 'message $message',
    CapturedRequest(:final url, :final method) => 'captured ${method ?? '?'} ${url.path}',
    FocusExit(:final direction) => 'focus exit ${direction.name}',
    PageFocused() => 'page took focus',
    PageBlurred() => 'page lost focus',
    NavigationStopped(:final url) => 'stopped at $url',
    PageDialog(:final kind, :final message) => 'dialog ${kind.name}: $message',
  };

  @override
  Widget build(BuildContext context) {
    final site = _site;
    final browser = _browser;
    final actions = <(String, VoidCallback?)>[
      ('Create', site == null ? null : _create),
      ('Load home', () => _run('load /', (b) async => b.load(site!.url('/')).then((_) => null))),
      ('Load check', () => _run('load /check', (b) async => b.load(site!.url('/check')).then((_) => null))),
      ('Load media', () => _run('load /media', (b) async => b.load(site!.url('/media')).then((_) => null))),
      ('Title', () => _run('title', (b) => b.evaluate('document.title'))),
      ('Cookies', () => _run('cookies', (b) async => (await b.cookies(site!.url('/'))).map((c) => '$c').join(' | '))),
      (
        'Delete secret',
        () => _run('delete secret', (b) => b.deleteCookies(site!.url('/'), name: 'secret').then((_) => null)),
      ),
      (
        'Fetch echo',
        () => _run('fetch /echo', (b) async {
          final reply = await b.fetchInPage(InPageRequest(site!.url('/echo'), method: 'POST', body: 'hi'));
          return '${reply.status} ${reply.body.replaceAll('\n', ' / ')}';
        }),
      ),
      (
        _capturing ? 'Capture off' : 'Capture on',
        () => _run('capture', (b) async {
          await b.setCapture(!_capturing);
          setState(() => _capturing = !_capturing);
          return _capturing ? 'on' : 'off';
        }),
      ),
      ('User agent', () => _run('agent', (b) => b.userAgent)),
      ('Post message', () => _run('post', (b) => b.evaluate('(${b.postScript})(${jsonEncode('hello')})'))),
      for (final (label, tv) in const [('Sheet', false), ('TV sheet', true)])
        (
          label,
          () => _run('sheet', (b) async {
            // The check page goes home once ticked.
            final cleared = b.events.firstWhere((e) => e is PageFinished && e.url.path == '/');
            final result = await showChallengeSheet(context, browser: b, strings: _strings, cleared: cleared, tv: tv);
            return result.name;
          }),
        ),
      (_shown ? 'Hide page' : 'Show page', browser == null ? null : () => setState(() => _shown = !_shown)),
      ('Dispose', browser == null ? null : _dispose),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(site == null ? 'Starting the test site…' : 'Challenge browser · ${site.origin}')),
      body: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (label, onPressed) in actions)
                    FilledButton.tonal(
                      style: const ButtonStyle(visualDensity: VisualDensity.compact),
                      onPressed: onPressed,
                      child: Text(label),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                flex: 4,
                child: browser != null && _shown
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          OutlinedButton(onPressed: () => _note('before pressed'), child: const Text('Before')),
                          const SizedBox(height: 8),
                          Expanded(
                            child: DecoratedBox(
                              decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor)),
                              child: ChallengeBrowserView(browser: browser),
                            ),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(onPressed: () => _note('after pressed'), child: const Text('After')),
                        ],
                      )
                    : const Center(child: Text('Create a page, load something, then show it.')),
              ),
              const Divider(),
              Expanded(
                flex: 2,
                child: ListView(
                  children: [
                    for (final line in _log) Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
