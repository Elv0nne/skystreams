/// Bot checks as Nuvio's worker isolates see them: the clearances a run starts
/// with, the main isolate it asks when a site wants a check, and the run's
/// clock. Plain Dart, with no plugin or root-isolate state, so it runs in the
/// workers.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

/// A site's clearance, handed to a run: the cookies Cloudflare issued, and the
/// agent they were issued to, which every request carrying them must send.
class NuvioGrant {
  const NuvioGrant({
    required this.site,
    required this.cookies,
    required this.agent,
    this.browserOnly = false,
  });

  /// The registrable domain it clears, subdomains included.
  final String site;
  final Map<String, String> cookies;
  final String agent;

  /// The site refuses requests from outside the browser even with it: they
  /// go through one of its pages.
  final bool browserOnly;

  bool covers(String host) => host == site || host.endsWith('.$site');

  Map<String, Object?> toMap() => {
    'site': site,
    'cookies': cookies,
    'userAgent': agent,
    if (browserOnly) 'browserOnly': true,
  };

  /// One of the app's live clearances (`Clearance.liveClearances`), or null
  /// when it isn't one.
  static NuvioGrant? fromMap(Map<dynamic, dynamic> map) {
    final site = map['site'];
    final agent = map['userAgent'];
    final cookies = map['cookies'];
    if (site is! String || agent is! String || cookies is! Map) return null;
    return NuvioGrant(
      site: site,
      cookies: {
        for (final e in cookies.entries) e.key.toString(): e.value.toString(),
      },
      agent: agent,
      browserOnly: map['browserOnly'] == true,
    );
  }
}

/// The main isolate's answer for a request a site met with a check: a grant
/// to send it again with, a response taken from a page on the site
/// (`{status, url, headers, body}`), or neither, when the challenge is the
/// answer.
class NuvioAnswer {
  const NuvioAnswer({this.grant, this.response});

  final NuvioGrant? grant;
  final Map<String, dynamic>? response;

  Map<String, Object?> toMap() => {
    if (grant != null) 'grant': grant!.toMap(),
    if (response != null) 'response': response,
  };

  static NuvioAnswer fromMap(Map<dynamic, dynamic> map) {
    final grant = map['grant'];
    final response = map['response'];
    return NuvioAnswer(
      grant: grant is Map ? NuvioGrant.fromMap(grant) : null,
      response: response is Map ? Map<String, dynamic>.from(response) : null,
    );
  }
}

/// How a run reaches the main isolate, where the browser is. A request is
/// `{url, method, headers, body}`.
abstract interface class NuvioClearanceChannel {
  /// [request] met a check. [retried]: it had been sent again with a
  /// clearance already.
  Future<NuvioAnswer> challengedRequest(
    Map<String, dynamic> request, {
    required bool retried,
  });

  /// [request] sent from inside a page on its site, which lets only the
  /// browser through.
  Future<NuvioAnswer> fromPage(Map<String, dynamic> request);

  /// The clearance for [url]'s site, solved if need be: `Cloudflare.solve`.
  Future<NuvioGrant?> solve(String url);
}

/// A run's running time, which stops while the run waits on the main isolate
/// (a check being cleared isn't the scraper's time), as CloudStream's call
/// timeout does.
class NuvioRunClock {
  final Stopwatch _watch = Stopwatch()..start();
  var _paused = 0;

  bool get isPaused => _paused > 0;

  Duration get running => _watch.elapsed;

  /// Waits nest: the clock runs again when the last one ends.
  void pause() {
    if (_paused++ == 0) _watch.stop();
  }

  void resume() {
    if (_paused == 0) return;
    if (--_paused == 0) _watch.start();
  }

  /// Completes once the running time reaches [budget].
  Future<void> expires(
    Duration budget, {
    Duration every = const Duration(milliseconds: 250),
  }) async {
    while (true) {
      final left = budget - _watch.elapsed;
      if (!isPaused && left <= Duration.zero) return;
      await Future<void>.delayed(isPaused || left > every ? every : left);
    }
  }
}

/// How the main isolate answers a run's call (`{op, source, personWaiting,
/// ...}`, op `challenged`, `fromPage` or `solve`): a [NuvioAnswer]'s map.
typedef NuvioBrokerHandler = Future<Map<String, Object?>> Function(
  Map<dynamic, dynamic> call,
);

/// A run's calls to the main isolate as plain maps, sent by [_send]: over a
/// worker's ports, or straight to the handler when the run has no worker.
class NuvioCallChannel implements NuvioClearanceChannel {
  NuvioCallChannel(
    this._send, {
    required this.source,
    required this.personWaiting,
  });

  final Future<Map<String, dynamic>> Function(Map<String, Object?> message)
  _send;

  /// What the checks the run meets are filed under.
  final String source;
  final bool personWaiting;

  Map<String, Object?> _call(String op, Map<String, Object?> rest) => {
    'op': op,
    'source': source,
    'personWaiting': personWaiting,
    ...rest,
  };

  @override
  Future<NuvioAnswer> challengedRequest(
    Map<String, dynamic> request, {
    required bool retried,
  }) async => NuvioAnswer.fromMap(
    await _send(_call('challenged', {'request': request, 'retried': retried})),
  );

  @override
  Future<NuvioAnswer> fromPage(Map<String, dynamic> request) async =>
      NuvioAnswer.fromMap(await _send(_call('fromPage', {'request': request})));

  @override
  Future<NuvioGrant?> solve(String url) async =>
      NuvioAnswer.fromMap(await _send(_call('solve', {'url': url}))).grant;
}

/// A worker's end of its calls to the main isolate, over the port its job
/// results go back on.
class NuvioWorkerLink {
  NuvioWorkerLink(this._toMain);

  final SendPort _toMain;
  final Map<int, Completer<Map<String, dynamic>>> _open = {};
  var _next = 0;

  /// Sends [message] for [job] and waits for the main isolate's answer.
  Future<Map<String, dynamic>> call(int job, Map<String, Object?> message) {
    final id = _next++;
    final done = Completer<Map<String, dynamic>>();
    _open[id] = done;
    _toMain.send({...message, 'broker': true, 'call': id, 'job': job});
    return done.future;
  }

  /// A message from the main isolate: true when it answered a call.
  bool handle(dynamic message) {
    if (message is! Map || message['brokerReply'] is! int) return false;
    final done = _open.remove(message['brokerReply']);
    final answer = message['answer'];
    done?.complete(
      answer is Map ? Map<String, dynamic>.from(answer) : const {},
    );
    return true;
  }
}

/// The main isolate's end of the workers' calls: answers them with a
/// handler, and keeps each job's backstop from running while one of its
/// calls is open.
class NuvioMainLink {
  NuvioMainLink(this._handler);

  final NuvioBrokerHandler _handler;
  final Map<int, NuvioRunClock> _clocks = {};

  NuvioRunClock _clock(int job) => _clocks.putIfAbsent(job, NuvioRunClock.new);

  /// [message] from a worker: true when it was a call, whose answer goes
  /// back through [reply].
  bool handle(
    dynamic message, {
    required void Function(Map<String, Object?> answer) reply,
  }) {
    if (message is! Map || message['broker'] != true) return false;
    final job = message['job'];
    final clock = job is int ? _clock(job) : null;
    clock?.pause();
    unawaited(() async {
      var answer = const <String, Object?>{};
      try {
        answer = await _handler(message);
      } catch (_) {
        // Answered with nothing: the run gets the check's response.
      } finally {
        clock?.resume();
      }
      reply({'brokerReply': message['call'], 'answer': answer});
    }());
    return true;
  }

  /// [result] of [job], or the backstop's answer once [budget] of the job's
  /// time has passed, not counting its open calls.
  Future<String> guard(int job, Future<String> result, Duration budget) async {
    final clock = _clock(job);
    try {
      return await Future.any([
        result,
        clock
            .expires(budget)
            .then((_) => jsonEncode({'error': 'Plugin worker did not answer'})),
      ]);
    } finally {
      _clocks.remove(job);
    }
  }
}
