import 'dart:async';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/widget_tap.dart';

/// One look at a scripted page: what [FakePage.glance] answers, and the
/// cookies it holds then.
class Step {
  const Step(
    this.title, {
    this.ready = 'complete',
    this.cloudflare = false,
    this.clearance,
    this.href,
    this.cookies = const [],
    this.awsWaf = false,
  });

  /// The challenge page.
  const Step.check({this.clearance})
    : title = 'Just a moment...',
      ready = 'complete',
      cloudflare = true,
      href = null,
      cookies = const [],
      awsWaf = false;

  /// The empty page a new page shows until its first load commits.
  const Step.blank()
    : title = '',
      ready = 'complete',
      cloudflare = false,
      clearance = null,
      href = 'about:blank',
      cookies = const [],
      awsWaf = false;

  final String title;

  /// The page's address, when not the one loaded.
  final String? href;
  final String ready;
  final bool cloudflare;

  /// The `cf_clearance` value at this step, if any.
  final String? clearance;

  /// Other cookies the page holds at this step: another vendor's check's.
  final List<StoredCookie> cookies;

  /// AWS WAF's challenge script is on the page (`window.gokuProps`).
  final bool awsWaf;
}

/// A page that plays [steps], one per [glance]; the last repeats.
class FakePage implements CheckPage {
  FakePage(
    this.steps, {
    this.onFetch,
    this.onEvaluate,
    this.agent = 'Engine/1.0',
    this.hangs = false,
    this.clearsAfter,
    this.cookieDomain = '.example.com',
    this.alsoHolds = const [],
    this.widget,
    this.clearsAfterTaps,
    this.loopsOnTap = false,
    this.onWidgetBox,
    this.clearsOnReload = false,
    this.timedCheck = const Step.check(),
    this.timeline,
  });

  /// What the page shows by time since [load]: each step from its time on.
  /// Takes the place of [steps].
  final List<(Duration, Step)>? timeline;

  Step get _timelineStep {
    final since = DateTime.now().difference(_loadedAt ?? DateTime.now());
    return timeline!
        .lastWhere((e) => e.$1 <= since, orElse: () => timeline!.first)
        .$2;
  }

  /// What shows until [clearsAfter]: Cloudflare's check unless another's.
  final Step timedCheck;

  /// Loaded a second time (the loop guard's fresh start), the check clears.
  final bool clearsOnReload;

  /// How many times it was loaded.
  int loads = 0;

  /// The cookies deleted from it, by URL and name.
  final List<({String url, String? name})> deleted = [];

  /// What [widgetBox] answers: where Turnstile's widget is, or null.
  final WidgetBox? widget;

  /// The check clears after this many taps: the site, with a fresh clearance.
  final int? clearsAfterTaps;

  /// Each tap mints a new clearance, but the check comes back: a loop.
  final bool loopsOnTap;

  /// Runs when the solver asks where the widget is, just before it taps.
  final void Function(FakePage page)? onWidgetBox;

  /// The taps the solver sent, with when, from [load].
  final List<({double x, double y, Duration at})> taps = [];

  /// When [widgetBox] was last asked.
  final List<Duration> widgetAsked = [];
  bool _clearedNow = false;

  /// Clears the check now, as the site would by itself.
  void clearNow() => _clearedNow = true;

  bool get _clearedByTap =>
      _clearedNow ||
      clearsAfterTaps != null && taps.length >= clearsAfterTaps! ||
      clearsOnReload && loads >= 2;

  final List<Step> steps;
  final String agent;

  /// The domain its cookies are set for.
  final String cookieDomain;

  /// The site's other cookies in the browser: a sign-in's, say.
  final List<StoredCookie> alsoHolds;

  /// Its browser stops answering: every call after [load] never completes,
  /// as Android's `evaluateJavascript` callback sometimes never fires.
  final bool hangs;

  /// Shows the check until this long after [load], then the site with a
  /// fresh clearance; [steps] are ignored. For checks timed by the clock.
  final Duration? clearsAfter;
  DateTime? _loadedAt;
  final Future<InPageResponse> Function(InPageRequest request)? onFetch;

  /// What [evaluate] answers; `null` when not given.
  final Future<String> Function(String script)? onEvaluate;
  int _at = -1;
  String? loaded;
  Map<String, String>? loadedHeaders;
  bool disposed = false;
  bool capturing = false;
  final List<InPageRequest> fetched = [];
  final List<String> evaluated = [];
  final _events = StreamController<BrowserEvent>.broadcast();

  /// Plays [event] as the page's own: a request it made, or its renderer ending.
  void emit(BrowserEvent event) => _events.add(event);

  Step get _step => steps[_at.clamp(0, steps.length - 1)];

  @override
  Future<void> load(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    loaded = url;
    loadedHeaders = headers;
    _loadedAt = DateTime.now();
    loads++;
  }

  @override
  Future<void> deleteCookies(String url, {String? name}) async =>
      deleted.add((url: url, name: name));

  bool get _timedClear =>
      clearsAfter != null &&
      _loadedAt != null &&
      DateTime.now().difference(_loadedAt!) >= clearsAfter!;

  @override
  Future<PageGlance?> glance() async {
    if (hangs) return Completer<PageGlance?>().future;
    _at++;
    final step = _clearedByTap
        ? const Step('Example', clearance: 'tapped')
        : timeline != null
        ? _timelineStep
        : clearsAfter == null
        ? _step
        : _timedClear
        ? const Step('Example', clearance: 'timed')
        : timedCheck;
    return PageGlance(
      title: step.title,
      href: step.href ?? loaded ?? '',
      ready: step.ready,
      cloudflare: step.cloudflare,
      awsWaf: step.awsWaf,
    );
  }

  @override
  Future<List<StoredCookie>> cookies(String url) async {
    if (hangs && loaded != null) {
      return Completer<List<StoredCookie>>().future;
    }
    final value = _clearedByTap
        ? 'tapped'
        : timeline != null
        ? _timelineStep.clearance
        : loopsOnTap && taps.isNotEmpty
        ? 'loop${taps.length}'
        : clearsAfter != null
        ? (_timedClear ? 'timed' : null)
        : _at < 0
        ? steps.first.clearance
        : _step.clearance;
    return [
      if (value != null)
        StoredCookie(name: 'cf_clearance', value: value, domain: cookieDomain),
      if (timeline != null && !_clearedByTap)
        ..._timelineStep.cookies
      else if (_at >= 0 && !_clearedByTap && clearsAfter == null)
        ..._step.cookies,
      ...alsoHolds,
    ];
  }

  @override
  Future<String> userAgent() async => agent;

  @override
  Future<InPageResponse> fetch(InPageRequest request) async {
    fetched.add(request);
    final answer = onFetch;
    if (answer == null) throw StateError('no in-page fetch');
    return answer(request);
  }

  @override
  Stream<BrowserEvent> get events => _events.stream;

  @override
  Future<void> setCapture(bool enabled) async => capturing = enabled;

  @override
  Future<String> evaluate(String script) async {
    evaluated.add(script);
    final answer = onEvaluate;
    return answer == null ? 'null' : answer(script);
  }

  @override
  Future<void> tap(double x, double y) async =>
      taps.add((x: x, y: y, at: DateTime.now().difference(_loadedAt!)));

  @override
  Future<WidgetBox?> widgetBox() async {
    widgetAsked.add(DateTime.now().difference(_loadedAt!));
    onWidgetBox?.call(this);
    return widget;
  }

  @override
  ChallengeBrowser? get browser => null;

  @override
  Future<void> dispose() async => disposed = true;
}

/// Opens [pages] in turn, recording how many were open at once.
class PageFactory {
  PageFactory(this.pages);

  final List<FakePage> pages;
  int opened = 0;
  int open = 0;
  int mostOpen = 0;

  /// Holds each open until released, to observe concurrency.
  Completer<void>? gate;

  Future<CheckPage> call() async {
    final page = pages[opened.clamp(0, pages.length - 1)];
    opened++;
    open++;
    if (open > mostOpen) mostOpen = open;
    final g = gate;
    if (g != null) await g.future;
    return _Counted(page, this);
  }
}

class _Counted implements CheckPage {
  _Counted(this._page, this._factory);

  final FakePage _page;
  final PageFactory _factory;

  @override
  Future<void> load(String url, {Map<String, String> headers = const {}}) =>
      _page.load(url, headers: headers);

  @override
  Stream<BrowserEvent> get events => _page.events;

  @override
  Future<void> setCapture(bool enabled) => _page.setCapture(enabled);

  @override
  Future<String> evaluate(String script) => _page.evaluate(script);

  @override
  Future<PageGlance?> glance() => _page.glance();

  @override
  Future<List<StoredCookie>> cookies(String url) => _page.cookies(url);

  @override
  Future<String> userAgent() => _page.userAgent();

  @override
  Future<InPageResponse> fetch(InPageRequest request) => _page.fetch(request);

  @override
  Future<void> tap(double x, double y) => _page.tap(x, y);

  @override
  Future<void> deleteCookies(String url, {String? name}) =>
      _page.deleteCookies(url, name: name);

  @override
  Future<WidgetBox?> widgetBox() => _page.widgetBox();

  @override
  ChallengeBrowser? get browser => null;

  @override
  Future<void> dispose() async {
    if (_page.disposed) return;
    _factory.open--;
    await _page.dispose();
  }
}
