/// What the player's check of a source found, as recovery acts on it.
///
/// libVLC 3 reports no HTTP status. So after a playback failure, recovery asks
/// the source's server the health probe's question again (a ranged GET for
/// the first kilobyte, with the source's headers) and reads the answer's
/// class (spec 2, *Error handling*). Pure: the request itself is the
/// resolver's `checkSource`.
library;

import 'dart:async' show TimeoutException;
import 'dart:io' show HttpDate, SocketException, TlsException;

import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' show ClientException;

import '../../../core/domain/entity/multimedia_item.dart' show StreamResult;
import 'stream_resolver.dart' show ProbeOutcome;

/// What a check found, as recovery acts on it.
enum CheckClass {
  /// The server answered: below 400 after redirects, or 416 (an empty file).
  answers,

  /// No answer: the name didn't resolve; the connection was refused, reset
  /// or unreachable; TLS failed; or no headers came back in time.
  network,

  /// The link is expired or gone: 401, 403, 404, 410, or another 4xx the HEAD
  /// didn't overrule.
  gone,

  /// The server is there but busy: 408, 429 or 5xx.
  busy,
}

/// How a check got no answer. Every one is [CheckClass.network]; the kind is
/// for the QoE log.
enum NetworkFault { dns, refused, reset, unreachable, timeout, tls, other }

/// What one check found.
@immutable
class CheckResult {
  const CheckResult({
    required this.kind,
    required this.outcome,
    this.status,
    this.fault,
    this.retryAfter,
    this.elapsed = Duration.zero,
  });

  final CheckClass kind;

  /// The same answer as the race and the source rows read it: healthy,
  /// unseekable or notVideo for an answer, unhealthy for every other class.
  final ProbeOutcome outcome;

  /// The status the server sent, when it sent one.
  final int? status;

  /// How a [CheckClass.network] check got no answer.
  final NetworkFault? fault;

  /// A [CheckClass.busy] server's `Retry-After`, when it sent one that can be
  /// read and lies ahead.
  final Duration? retryAfter;

  /// How long the check took.
  final Duration elapsed;

  @override
  String toString() =>
      'CheckResult(${kind.name}, ${outcome.name}, status: $status, '
      'fault: ${fault?.name}, retryAfter: $retryAfter)';
}

/// Checks one source: the resolver's `checkSource`, or a test's.
typedef SourceCheck = Future<CheckResult> Function(StreamResult stream);

/// The class of an HTTP status, on its own. A 4xx other than 401, 403, 404 and
/// 410 is `gone` here; the check puts it to a HEAD before it settles.
CheckClass checkClassOfStatus(int status) {
  if (status < 400 || status == 416) return CheckClass.answers;
  if (status == 408 || status == 429 || status >= 500) return CheckClass.busy;
  return CheckClass.gone;
}

/// The statuses that settle `gone` with no HEAD: the link has expired or never
/// existed, and a HEAD would say the same.
const Set<int> kGoneStatuses = <int>{401, 403, 404, 410};

// The errno values each fault carries: macOS and iOS, then Linux and Android,
// then Windows' WSA codes.
const Set<int> _refused = <int>{61, 111, 10061};
const Set<int> _reset = <int>{54, 104, 10054};
const Set<int> _unreachable = <int>{51, 65, 101, 113, 10051, 10065};
const Set<int> _timedOut = <int>{60, 110, 10060};

/// How [error], thrown by a check's request, failed.
///
/// package:http 1.6's IOClient rethrows a SocketException as a
/// ClientException that also implements SocketException, an HttpException as
/// a plain ClientException, and lets a TLS failure through as it is.
NetworkFault networkFaultOf(Object error) {
  if (error is TimeoutException) return NetworkFault.timeout;
  if (error is TlsException) return NetworkFault.tls;
  if (error is SocketException) {
    if (error.message.startsWith('Failed host lookup')) return NetworkFault.dns;
    final code = error.osError?.errorCode;
    if (code != null) {
      if (_refused.contains(code)) return NetworkFault.refused;
      if (_reset.contains(code)) return NetworkFault.reset;
      if (_unreachable.contains(code)) return NetworkFault.unreachable;
      if (_timedOut.contains(code)) return NetworkFault.timeout;
    }
    return NetworkFault.other;
  }
  if (error is ClientException &&
      error.message.startsWith('Connection closed before full header')) {
    return NetworkFault.reset;
  }
  return NetworkFault.other;
}

/// A `Retry-After` header's wait, in delta-seconds or as an HTTP date against
/// [now]. Null for none, zero, a date that has passed, or a value that can't
/// be read.
Duration? retryAfterOf(String? header, {required DateTime now}) {
  final value = header?.trim();
  if (value == null || value.isEmpty) return null;
  final seconds = int.tryParse(value);
  if (seconds != null) return seconds > 0 ? Duration(seconds: seconds) : null;
  try {
    final wait = HttpDate.parse(value).difference(now);
    return wait > Duration.zero ? wait : null;
  } on Exception {
    return null;
  }
}
