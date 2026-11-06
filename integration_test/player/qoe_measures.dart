/// What the QoE suite measures of an outage row: what the viewer saw and
/// what recovery did, worked out from the suite's records once the row ends.
/// Pure, so `test/integration_support/qoe_measures_test.dart` pins it without
/// a device.
///
/// Three clocks meet here:
/// - the trace's ([PictureSample.t], [TimedEvent.t]): milliseconds since the
///   suite began watching the player, which was `traceEpochMs` on the
///   device's clock;
/// - the device's, which the QoE log's times are mapped from;
/// - the scenario server's ([ServedRequest.t], `outageStartMs`): the Mac's
///   epoch. `serverOffsetMs` is the server's clock minus the device's, as the
///   suite reads it at every control call.
library;

import 'dart:math' as math;

import 'package:skystream/core/network/probe_answer.dart';

/// One reading of the decoder's count of video pictures, at [t] on the
/// trace's clock, with the position then.
typedef PictureSample = ({int t, int pos, int decoded});

/// One QoE log event: its kind's name, its time on the trace's clock, and
/// what it carries.
typedef TimedEvent = ({String kind, int t, Map<String, Object?> fields});

/// One request the scenario server answered, at [t] on the server's clock.
typedef ServedRequest = ({
  int t,
  String method,
  String path,
  int status,
  String range,
});

/// The range a recovery check asks for: the probe's first kilobyte
/// ([kProbeSniffBytes]). No player asks for exactly this, so it tells the
/// check's requests from a reopen's.
const String checkRange = 'bytes=0-${kProbeSniffBytes - 1}';

/// Whether [now] shows pictures decoded since [before]. A reopened media
/// counts from 0 again, so a count that falls to a new value above 0 is new
/// pictures too.
bool isNewPicture(PictureSample before, PictureSample now) =>
    now.decoded != before.decoded && now.decoded > 0;

/// How the picture moved between [from] and [end].
///
/// `frozenMs` is the longest stretch without a new picture, measured between
/// readings (about a second apart), so steady playback reads about 1000.
/// `movingAtEnd` is whether a new picture came in the last [tail]. Both are
/// null when there are fewer than two readings: a backend with no counts
/// can't be judged.
///
/// Readings from 2 s before [from] are the baseline, so a stretch that began
/// just before the cut is measured from its start.
({int? frozenMs, bool? movingAtEnd}) pictureMotion(
  List<PictureSample> pictures, {
  required int from,
  required int end,
  int tail = 5000,
}) {
  final readings = [
    for (final p in pictures)
      if (p.t >= from - 2000 && p.t <= end) p,
  ];
  if (readings.length < 2) return (frozenMs: null, movingAtEnd: null);
  var lastNew = readings.first.t;
  var longest = 0;
  var movedLately = false;
  for (var i = 1; i < readings.length; i++) {
    if (!isNewPicture(readings[i - 1], readings[i])) continue;
    longest = math.max(longest, readings[i].t - lastNew);
    lastNew = readings[i].t;
    if (readings[i].t >= end - tail) movedLately = true;
  }
  longest = math.max(longest, end - lastNew);
  return (frozenMs: longest, movingAtEnd: movedLately);
}

/// Where the picture last moved at or before [before]: the position at the
/// last reading that showed new pictures, or null when none did.
int? lastPicturePosition(List<PictureSample> pictures, {required int before}) {
  for (var i = pictures.length - 1; i > 0; i--) {
    if (pictures[i].t > before) continue;
    if (isNewPicture(pictures[i - 1], pictures[i])) return pictures[i].pos;
  }
  return null;
}

/// When recovery first noticed something at or after [cut]: its first
/// failure (`error`), wait or check. Null when it noticed nothing.
int? failureNoticed(List<TimedEvent> events, {required int cut}) {
  for (final e in events) {
    if (e.t < cut) continue;
    if (e.kind == 'error' || e.kind == 'wait' || e.kind == 'check') return e.t;
  }
  return null;
}

/// What recovery did from [cut] on, as an outage row reports it: every time
/// in ms after the cut. A wait carries its end's `ms` (null while it runs).
Map<String, Object?> recoveryOf(List<TimedEvent> events, {required int cut}) {
  final after = [
    for (final e in events)
      if (e.t >= cut) e,
  ];
  final waits = <Map<String, Object?>>[];
  for (final e in after) {
    if (e.kind == 'wait') {
      waits.add(<String, Object?>{
        'afterCutMs': e.t - cut,
        'label': e.fields['label'],
        'ms': null,
      });
    } else if (e.kind == 'waitEnd' &&
        waits.isNotEmpty &&
        waits.last['ms'] == null) {
      waits.last['ms'] = e.fields['ms'];
    }
  }
  return <String, Object?>{
    'reopens': [
      for (final e in after)
        if (e.kind == 'reopen')
          <String, Object?>{
            'afterCutMs': e.t - cut,
            'reason': e.fields['reason'],
            'keptPicture': e.fields['keptPicture'] == true,
          },
    ],
    'waits': waits,
    'checks': [
      for (final e in after)
        if (e.kind == 'check')
          <String, Object?>{
            'afterCutMs': e.t - cut,
            'sourceIndex': e.fields['sourceIndex'],
            'kind': e.fields['kind'],
            'status': e.fields['status'],
          },
    ],
    'failovers': [
      for (final e in after)
        if (e.kind == 'failover')
          <String, Object?>{
            'afterCutMs': e.t - cut,
            'to': e.fields['to'],
            'reason': e.fields['reason'],
          },
    ],
    'gaveUp': [
      for (final e in after)
        if (e.kind == 'gaveUp') e.fields['cause'],
    ].firstOrNull,
    'signs': [
      for (final e in after)
        if (e.kind == 'error' && e.fields['sign'] != null) e.fields['sign'],
    ],
  };
}

/// How long after [threshold] (the server's clock) a reopen's first request
/// reached the server: the first GET under [pathPrefix] the server answered
/// with media (200 or 206), other than a check's. Null when none came.
int? reopenAfterServer(
  List<ServedRequest> requests, {
  required int threshold,
  required String pathPrefix,
}) {
  final served = [
    for (final r in requests)
      if (r.t >= threshold &&
          r.method == 'GET' &&
          (r.status == 200 || r.status == 206) &&
          r.range != checkRange &&
          r.path.split('?').first.startsWith(pathPrefix))
        r.t,
  ]..sort();
  return served.isEmpty ? null : served.first - threshold;
}

/// Everything an outage row reports about the picture and the recovery.
///
/// - The reopen's timing (`reopenAfterServerMs`) is counted from when the
///   server was answering again and recovery had noticed the failure,
///   whichever came later: a film that plays on its buffer for 51 s after a
///   20 s drop is reopened at its false end, and that is when its 2 s start.
///   It is measured only when recovery opened something or ended a wait after
///   the cut; a stall libVLC rides out by itself has none.
/// - The spot (`spotOffMs`) is where recovery's first open after the cut
///   started, less where the picture last moved before recovery noticed the
///   failure. A step-down's open is the device's, not recovery's, so it is
///   never the one judged. A live reopen starts at the live edge, so a live
///   row has none.
/// - `stepDowns` is every step-down's time from the cut, those before it
///   too, so one that lands next to the cut shows.
Map<String, Object?> outageMeasures({
  required List<PictureSample> pictures,
  required bool heldPictureSeen,
  required Set<String> statusSeen,
  required List<TimedEvent> events,
  required List<ServedRequest> requests,
  required int cut,
  required int end,
  required int traceEpochMs,
  required int serverOffsetMs,
  required int outageStartMs,
  required int outageMs,
  required String media,
  required String pathPrefix,
}) {
  int onServer(int t) => traceEpochMs + t + serverOffsetMs;
  final motion = pictureMotion(pictures, from: cut, end: end);
  final noticed = failureNoticed(events, cut: cut);
  final outageEnd = outageStartMs + outageMs;
  final threshold = noticed == null
      ? outageEnd
      : math.max(outageEnd, onServer(noticed));
  final opens = [
    for (final e in events)
      if (e.t >= cut &&
          e.kind == 'open' &&
          e.fields['reason'] != 'first' &&
          e.fields['reason'] != 'step-down')
        e,
  ];
  final acted =
      opens.isNotEmpty || events.any((e) => e.t >= cut && e.kind == 'waitEnd');
  final reopen = opens.firstOrNull;
  final startAt = reopen?.fields['startAtMs'];
  final stoppedAt = lastPicturePosition(
    pictures,
    before: noticed ?? reopen?.t ?? end,
  );
  return <String, Object?>{
    'media': media,
    'outageMs': outageMs,
    'pictureFrozenMs': motion.frozenMs,
    'pictureMovingAtEnd': motion.movingAtEnd,
    'heldPictureSeen': heldPictureSeen,
    'statusSeen': [...statusSeen]..sort(),
    ...recoveryOf(events, cut: cut),
    'stepDowns': [
      for (final e in events)
        if (e.kind == 'reopen' && e.fields['reason'] == 'step-down') e.t - cut,
    ],
    'reopenAfterServerMs': acted
        ? reopenAfterServer(
            requests,
            threshold: threshold,
            pathPrefix: pathPrefix,
          )
        : null,
    'spotOffMs': media == 'live' || startAt is! int || stoppedAt == null
        ? null
        : startAt - stoppedAt,
  };
}
