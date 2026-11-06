/// An extension screen's session: windows as the engine sends them, actions in order.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_ui_session.dart';

Map<String, dynamic> _window(String text, {String id = 'w1', int root = 1}) => {
  'id': id,
  'kind': 'sheet',
  'root': {'id': root, 'kind': 'text', 'text': text},
};

/// An engine whose first screen event comes before it answers, as the real one's can.
class _FakeApi implements ExtensionUiApi {
  final controller = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <String>[];
  Object? failing;

  @override
  Stream<Map<String, dynamic>> get events => controller.stream;

  @override
  Future<int> openSettings(String plugin) async {
    controller.add({
      'event': 'ui',
      'session': 5,
      'plugin': plugin,
      'windows': [_window('Early')],
    });
    return 5;
  }

  @override
  Future<int> openPopups(String plugin) async {
    controller.add({
      'event': 'ui',
      'session': 6,
      'plugin': plugin,
      'windows': [_window('Kept')],
    });
    return 6;
  }

  @override
  Future<Map<String, dynamic>> uiAction(int session, int node, String action, [Object? value]) async {
    sent.add('$node $action $value');
    final error = failing;
    if (error != null) throw error;
    return {'done': true};
  }

  @override
  Future<void> closeUi(int session, {bool force = false}) async => sent.add('closeUi $force');
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 1));

void main() {
  const plugin = '/plugins/Test.cs3';

  test('the first windows may come before the engine answers', () async {
    final session = await ExtensionUiSession.open(_FakeApi(), plugin);
    await _settle();
    expect(session.id, 5);
    expect(session.windows.single.root.text, 'Early');
  });

  test("Support's screen opens like a settings one, its first windows heard however early", () async {
    final session = await ExtensionUiSession.openPopups(_FakeApi(), plugin);
    await _settle();
    expect(session.id, 6);
    expect(session.windows.single.root.text, 'Kept');
  });

  test('a screen the engine opened by itself is heard from when attached, and ends on uiClosed', () async {
    final api = _FakeApi();
    final session = ExtensionUiSession.attach(api, 9, plugin);
    api.controller.add({
      'event': 'ui',
      'session': 9,
      'plugin': plugin,
      'windows': [_window('Pick a server')],
    });
    await _settle();
    expect(session.windows.single.root.text, 'Pick a server');
    api.controller.add({'event': 'uiClosed', 'session': 9, 'plugin': plugin, 'reason': 'closed'});
    await session.done;
    expect(session.closed, isTrue);
  });

  test("other screens' events are left alone, and uiClosed closes this one", () async {
    final api = _FakeApi();
    final session = await ExtensionUiSession.open(api, plugin);
    api.controller.add({
      'event': 'ui',
      'session': 6,
      'windows': [_window('Other')],
    });
    await _settle();
    expect(session.windows.single.root.text, 'Early');
    api.controller.add({'event': 'uiClosed', 'session': 5, 'reason': 'error', 'error': 'NullPointerException: gone'});
    await _settle();
    expect((session.closed, session.closedReason, session.closedError), (true, 'error', 'NullPointerException: gone'));
    expect(session.windows, isEmpty);
  });

  test('text being typed reaches the extension before the next action', () async {
    final api = _FakeApi();
    final session = await ExtensionUiSession.open(api, plugin);
    session.type(4, 'abc');
    await session.act(9, 'click');
    expect(api.sent, ['4 text abc', '9 click null']);
  });

  test('text is sent once the person pauses, only the last of it', () async {
    final api = _FakeApi();
    final session = await ExtensionUiSession.open(api, plugin);
    session.type(4, 'a');
    session.type(4, 'ab');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(api.sent, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(api.sent, ['4 text ab']);
  });

  test('closing closes the top window; force closes them all', () async {
    final api = _FakeApi();
    final session = await ExtensionUiSession.open(api, plugin);
    api.controller.add({
      'event': 'ui',
      'session': 5,
      'windows': [_window('Sheet'), _window('Alert', id: 'w2', root: 11)],
    });
    await _settle();
    await session.close();
    await session.close(force: true);
    expect(api.sent, ['11 close null', 'closeUi true']);
  });

  test('a restart the extension asks for is noted', () async {
    final api = _FakeApi();
    final session = await ExtensionUiSession.open(api, plugin);
    api.controller.add({'event': 'restartRequested', 'plugin': plugin});
    await _settle();
    expect(session.restartRequested, isTrue);
  });

  test('a failed action is reported, later ones still go, and only real actions count', () async {
    final api = _FakeApi()..failing = StateError('node 3 is gone');
    final session = await ExtensionUiSession.open(api, plugin);
    await session.act(3, 'click');
    expect(session.error, isA<StateError>());
    api.failing = null;
    await session.act(4, 'check', true);
    await session.close();
    expect(api.sent, ['3 click null', '4 check true', '1 close null']);
    expect(session.actionsSent, 2);
    expect(session.error, isNull);
  });

  test("a page's focus goes to the engine uncounted, and focus leaving it comes back by node", () async {
    final api = _FakeApi();
    final session = await ExtensionUiSession.open(api, '/plugins/Test.cs3');
    final exits = <({int node, String direction})>[];
    session.pageExits.listen(exits.add);
    session.focusPage(7, forward: false);
    session.blurPage(7);
    await _settle();
    expect(api.sent, ['7 focus false', '7 blur null']);
    expect(session.actionsSent, 0);
    api.controller
      ..add({'event': 'pageFocusExit', 'session': 5, 'node': 7, 'direction': 'down'})
      ..add({'event': 'pageFocusExit', 'session': 6, 'node': 7, 'direction': 'up'});
    await _settle();
    expect(exits, [(node: 7, direction: 'down')]);
    session.dispose();
  });

  test('firstWindows waits for the first windows, the end, or its timeout', () async {
    final session = ExtensionUiSession.test(_FakeApi());
    var done = false;
    unawaited(session.firstWindows().then((_) => done = true));
    await _settle();
    expect(done, isFalse);
    session.receive({
      'event': 'ui',
      'session': 1,
      'windows': [
        {
          'id': 'w1',
          'kind': 'dialog',
          'root': {'id': 1, 'kind': 'text', 'text': 'Hi'},
        },
      ],
    });
    await _settle();
    expect(done, isTrue);
    await ExtensionUiSession.test(_FakeApi()).firstWindows(timeout: const Duration(milliseconds: 10));
  });
}
