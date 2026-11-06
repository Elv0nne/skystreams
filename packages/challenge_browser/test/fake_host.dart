import 'dart:async';

import 'package:challenge_browser/src/messages.g.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for a platform backend at the channel level, so the generated bindings run for real.
class FakeHost {
  FakeHost() {
    for (final method in const [
      'create',
      'load',
      'evaluate',
      'addDocumentStartScript',
      'cookies',
      'deleteCookies',
      'userAgent',
      'setUserAgent',
      'setCapture',
      'setFrame',
      'focus',
      'blur',
      'dispose',
      'tap',
      'evaluateIsolated',
      'capabilities',
      'engineVersion',
      'devTools',
      'serveFolder',
      'holdDialogs',
      'answerDialog',
      'title',
    ]) {
      _messenger.setMockMessageHandler('$_prefix.PageHostApi.$method', (data) async {
        final args = codec.decodeMessage(data) as List<Object?>? ?? const [];
        calls.add((method, args));
        // Android's evaluateJavascript callback sometimes never fires.
        if (method == 'evaluate' && evaluateHangs) await Completer<void>().future;
        return codec.encodeMessage([_reply(method, args)]);
      });
    }
  }

  static const _prefix = 'dev.flutter.pigeon.challenge_browser';
  static final codec = PageHostApi.pigeonChannelCodec;
  final _messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final List<(String, List<Object?>)> calls = [];

  /// Whether `evaluate` never answers.
  bool evaluateHangs = false;

  /// What `evaluate` answers: JSON, as the engines' are.
  String evaluateReply = 'true';

  /// What `evaluateIsolated` answers: JSON, as the engines' are.
  String evaluateIsolatedReply = '"isolated"';

  /// What this backend says it can do.
  PageCapabilities capabilities = PageCapabilities(canTap: true, isolatedWorlds: true);

  String engineVersion = '';

  /// What `title` answers: the page's title as its engine has it.
  String? titleReply = 'Home';

  /// What `devTools` answers, by DevTools method: the raw result JSON.
  Map<String, String> devToolsReplies = {};
  int _nextId = 1;

  Object? _reply(String method, List<Object?> args) => switch (method) {
    'create' => _nextId++,
    'evaluate' => evaluateReply,
    'cookies' => [
      PageCookie(name: 'secret', value: '2', domain: '127.0.0.1', path: '/', httpOnly: true, secure: false),
    ],
    'userAgent' => 'Engine/1.0',
    'evaluateIsolated' => evaluateIsolatedReply,
    'capabilities' => capabilities,
    'engineVersion' => engineVersion,
    'devTools' => devToolsReplies[args[1]] ?? '{}',
    'serveFolder' => 'cbfolder://${args[1]}/',
    'title' => titleReply,
    _ => null,
  };

  List<List<Object?>> callsOf(String method) => [
    for (final (name, args) in calls)
      if (name == method) args,
  ];

  /// Sends [event] for [pageId] as a backend would.
  Future<void> emit(int pageId, PageEvent event) async {
    final data = codec.encodeMessage([pageId, event]);
    final done = Completer<void>();
    await _messenger.handlePlatformMessage('$_prefix.PageFlutterApi.onEvent', data, (_) => done.complete());
    await done.future;
  }

  Future<void> message(int pageId, String message) =>
      emit(pageId, PageEvent(kind: PageEventKind.scriptMessage, message: message));
}
