import 'dart:async';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_pages.dart';

/// A page that loads nothing: it records what it was asked, and its events are the test's.
class FakePageBrowser implements ExtensionPageBrowser {
  final controller = StreamController<BrowserEvent>.broadcast();
  final scripts = <String>[];
  final loads = <({String url, Map<String, String> headers})>[];
  final evaluated = <String>[];
  String? agent;

  /// What a script in the page reads as `document.title`: JSON, as [evaluate]'s answers are.
  String documentTitle = '"Sign in"';

  /// The page's title as the browser has it ([title]): no script runs in the page for it.
  String? pageTitle = 'Sign in';

  /// Whether the page runs no script now, as when it waits in a held dialog: [evaluate] answers nothing until then.
  bool scriptsWait = false;

  /// Set while the page waits in a dialog: [evaluate] waits until [answerDialog] answers it (or the page goes), as a
  /// held page runs no script until then.
  Completer<void>? held;

  /// What the page does as a dialog is answered, before it runs on: a test opens its next dialog here (setting [held]
  /// again and adding the dialog), as a page that goes straight from one dialog to the next.
  void Function(int id)? afterAnswer;

  /// What [evaluate] answers for any script but the title's.
  String answer = '"done"';
  List<({String name, String value, String domain})> jar = const [];
  bool disposed = false;

  /// The folders it was asked to serve, and whether it can (Android's browser reads files itself).
  final served = <({String name, String folder})>[];
  bool servesFolders = true;

  /// A served folder's base: WebKit's and WebKitGTK's shape by default, WebView2's `https://<name>.example/` when set.
  String Function(String name) servedBase = (name) => 'cbfolder://$name/';

  @override
  Future<String> serveFolder(String name, String folder) async {
    if (!servesFolders) throw UnsupportedError("This browser reads an extension's files itself");
    served.add((name: name, folder: folder));
    return servedBase(name);
  }

  /// Whether it holds its page's dialogs, and the answers it was given.
  bool holding = false;
  final answered = <({int id, bool accept, String? text})>[];

  /// Answers tried after it was disposed: they throw, as a disposed page's do.
  int lateAnswers = 0;

  @override
  Future<void> holdDialogs() async => holding = true;

  @override
  Future<void> answerDialog(int id, {required bool accept, String? text}) async {
    if (disposed) {
      lateAnswers++;
      throw StateError('The page was disposed');
    }
    answered.add((id: id, accept: accept, text: text));
    final page = held;
    held = null;
    afterAnswer?.call(id);
    if (page != null && !page.isCompleted) page.complete();
  }

  void _letGo() {
    final page = held;
    held = null;
    if (page != null && !page.isCompleted) page.complete();
  }

  @override
  ChallengeBrowser? get challenge => null;

  @override
  Stream<BrowserEvent> get events => controller.stream;

  @override
  String get postScript => 'POST';

  @override
  Future<void> setUserAgent(String agent) async => this.agent = agent;

  @override
  Future<void> addDocumentStartScript(String script) async => scripts.add(script);

  @override
  Future<void> load(String url, {Map<String, String> headers = const {}}) async =>
      loads.add((url: url, headers: headers));

  @override
  Future<String> evaluate(String script) async {
    evaluated.add(script);
    if (scriptsWait) await Completer<void>().future;
    for (var page = held; page != null && !page.isCompleted; page = held) {
      await page.future;
    }
    return script == 'document.title' ? documentTitle : answer;
  }

  @override
  Future<String?> title() async => pageTitle;

  @override
  Future<List<({String name, String value, String domain})>> cookies(String url) async => jar;

  @override
  Future<void> dispose() async {
    disposed = true;
    _letGo();
    await controller.close();
  }
}

/// What the pages told the engine, in order, and what the engine answers, by type: an answering call's value, a page
/// dialog's answer (Phase 7c). Every other report answers nothing.
class PageReports {
  final reports = <({int rid, String type, Map<String, Object?> fields})>[];
  final answers = <String, Map<String, dynamic>>{};

  /// Reports whose answer waits, by type: as an extension's chrome client that holds a dialog's result a while.
  final waits = <String, Future<void>>{};

  Future<Map<String, dynamic>> call(int rid, String type, Map<String, Object?> fields) async {
    reports.add((rid: rid, type: type, fields: fields));
    await waits[type];
    return answers[type] ?? const {};
  }

  List<String> get types => [for (final r in reports) r.type];
}
