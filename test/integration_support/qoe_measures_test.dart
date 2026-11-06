import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/player/qoe_measures.dart';

/// Readings once a second from [from] to [to] (ms on the trace's clock): the
/// count grows by 24 a second (24 fps) up to [frozenAt], then stands still.
List<PictureSample> readings(int from, int to, {int? frozenAt}) => [
  for (var t = from; t <= to; t += 1000)
    (
      t: t,
      pos: t - 1500,
      decoded: 24 * ((frozenAt == null || t < frozenAt ? t : frozenAt) ~/ 1000),
    ),
];

TimedEvent event(
  String kind,
  int t, [
  Map<String, Object?> fields = const {},
]) => (kind: kind, t: t, fields: fields);

ServedRequest request(
  int t, {
  String method = 'GET',
  String path = '/hls/master.m3u8?qoe=drop20-hls-1',
  int status = 206,
  String range = 'bytes=0-',
}) => (t: t, method: method, path: path, status: status, range: range);

void main() {
  group('pictureMotion', () {
    test('steady playback stands still no longer than between readings', () {
      final motion = pictureMotion(readings(0, 10000), from: 3000, end: 10000);
      expect(motion.frozenMs, 1000);
      expect(motion.movingAtEnd, isTrue);
    });

    test('a picture frozen under running audio is still at the end', () {
      // Part 2's macOS drop20-hls: the picture froze 15.6 s after the cut at
      // 10 s, and the audio carried the clock to the end of the window.
      final pictures = readings(8000, 85000, frozenAt: 25000);
      final motion = pictureMotion(pictures, from: 10000, end: 85000);
      expect(motion.frozenMs, 60000);
      expect(motion.movingAtEnd, isFalse);
    });

    test('a reopened media counting from 0 again is new pictures', () {
      final pictures = [
        ...readings(8000, 32000, frozenAt: 24000),
        (t: 33000, pos: 0, decoded: 0),
        (t: 34000, pos: 22000, decoded: 12),
        (t: 35000, pos: 23000, decoded: 36),
        (t: 36000, pos: 24000, decoded: 60),
      ];
      final motion = pictureMotion(pictures, from: 10000, end: 36000);
      expect(motion.frozenMs, 10000);
      expect(motion.movingAtEnd, isTrue);
    });

    test('a backend with no counts cannot be judged', () {
      final motion = pictureMotion(
        const [(t: 9000, pos: 7500, decoded: 216)],
        from: 10000,
        end: 85000,
      );
      expect(motion.frozenMs, isNull);
      expect(motion.movingAtEnd, isNull);
    });
  });

  test('lastPicturePosition is where the picture last moved before a time', () {
    final pictures = readings(8000, 40000, frozenAt: 25000);
    expect(lastPicturePosition(pictures, before: 26000), 23500);
    expect(lastPicturePosition(pictures, before: 7000), isNull);
  });

  test('failureNoticed is the first failure, wait or check after the cut', () {
    final events = [
      event('error', 5000, {'sign': 'stalled'}),
      event('open', 26050, {'reason': 'retry'}),
      event('check', 26100, {'kind': 'network'}),
      event('wait', 26200, {'label': 'reconnecting'}),
    ];
    expect(failureNoticed(events, cut: 10000), 26100);
    expect(failureNoticed(const [], cut: 10000), isNull);
  });

  test('recoveryOf reports what recovery did after the cut', () {
    final events = [
      event('reopen', 9000, {'reason': 'step-down', 'keptPicture': true}),
      event('error', 26000, {'detail': 'x', 'sign': 'videoStarved'}),
      event('check', 26100, {'sourceIndex': 0, 'kind': 'network'}),
      event('wait', 26200, {'label': 'reconnecting', 'positionMs': 23500}),
      event('check', 32100, {
        'sourceIndex': 0,
        'kind': 'answers',
        'status': 206,
      }),
      event('waitEnd', 32100, {'ms': 5900}),
      event('reopen', 32150, {'reason': 'retry', 'keptPicture': true}),
    ];
    expect(recoveryOf(events, cut: 10000), <String, Object?>{
      'reopens': [
        {'afterCutMs': 22150, 'reason': 'retry', 'keptPicture': true},
      ],
      'waits': [
        {'afterCutMs': 16200, 'label': 'reconnecting', 'ms': 5900},
      ],
      'checks': [
        {
          'afterCutMs': 16100,
          'sourceIndex': 0,
          'kind': 'network',
          'status': null,
        },
        {
          'afterCutMs': 22100,
          'sourceIndex': 0,
          'kind': 'answers',
          'status': 206,
        },
      ],
      'failovers': <Object?>[],
      'gaveUp': null,
      'signs': ['videoStarved'],
    });
  });

  test('reopenAfterServer is the first media request the server answered', () {
    const threshold = 1030300;
    final requests = [
      request(threshold - 500),
      request(threshold + 300, range: checkRange),
      request(threshold + 400, method: 'HEAD'),
      request(threshold + 500, status: 503),
      request(threshold + 600, path: '/prog.mp4?qoe=other'),
      request(threshold + 1700, path: '/hls/v1080/seg004.ts', status: 200),
      request(threshold + 1400),
    ];
    expect(
      reopenAfterServer(requests, threshold: threshold, pathPrefix: '/hls/'),
      1400,
    );
    expect(
      reopenAfterServer(requests, threshold: threshold, pathPrefix: '/live/'),
      isNull,
    );
  });

  group('outageMeasures', () {
    // The device began the trace at 1,000,000 on its clock; the server's
    // clock reads 250 ms ahead of the device's; the cut is 10 s in.
    Map<String, Object?> measure({
      required List<PictureSample> pictures,
      required List<TimedEvent> events,
      List<ServedRequest> requests = const [],
      String media = 'hls',
      String pathPrefix = '/hls/',
    }) => outageMeasures(
      pictures: pictures,
      heldPictureSeen: true,
      statusSeen: {'reconnecting'},
      events: events,
      requests: requests,
      cut: 10000,
      end: 85000,
      traceEpochMs: 1000000,
      serverOffsetMs: 250,
      outageStartMs: 1010300,
      outageMs: 20000,
      media: media,
      pathPrefix: pathPrefix,
    );

    final recovered = [
      event('reopen', 9000, {'reason': 'step-down', 'keptPicture': true}),
      event('error', 26000, {'detail': 'x', 'sign': 'videoStarved'}),
      event('wait', 26200, {'label': 'reconnecting'}),
      event('waitEnd', 31250, {'ms': 5050}),
      event('open', 31300, {'reason': 'retry', 'startAtMs': 23000}),
      event('reopen', 31300, {'reason': 'retry', 'keptPicture': true}),
    ];

    test('times a reopen from when the server answered again', () {
      final m = measure(
        pictures: [
          ...readings(8000, 31000, frozenAt: 25000),
          ...readings(33000, 85000),
        ],
        events: recovered,
        requests: [
          request(1031000, range: checkRange),
          request(1031700),
        ],
      );
      expect(m['reopenAfterServerMs'], 1400);
      expect(m['spotOffMs'], -500);
      expect(m['pictureFrozenMs'], 8000);
      expect(m['pictureMovingAtEnd'], isTrue);
      expect(m['heldPictureSeen'], isTrue);
      expect(m['statusSeen'], ['reconnecting']);
      expect(m['stepDowns'], [-1000]);
      expect(m['media'], 'hls');
      expect(m['outageMs'], 20000);
    });

    test('times a reopen from the failure when it was noticed later', () {
      // A file plays its buffer out 51 s after the cut, long after the 20 s
      // drop ended: its reopen is timed from that false end.
      final m = measure(
        pictures: readings(8000, 85000, frozenAt: 61000),
        events: [
          event('error', 61000, {'sign': 'falseEnd'}),
          event('check', 61050, {'kind': 'answers'}),
          event('open', 62100, {'reason': 'retry', 'startAtMs': 59400}),
        ],
        requests: [request(1062550, path: '/prog.mp4?qoe=drop20-mp4-1')],
        media: 'file',
        pathPrefix: '/prog.mp4',
      );
      expect(m['reopenAfterServerMs'], 1300);
      expect(m['spotOffMs'], -100);
    });

    test('a step-down after the recovery is not the reopen judged', () {
      // The emulators' decoders step a rendition down again once the
      // recovery plays: that open starts wherever playback is by then.
      final m = measure(
        pictures: [
          ...readings(8000, 31000, frozenAt: 25000),
          ...readings(33000, 85000),
        ],
        events: [
          ...recovered,
          event('open', 45000, {'reason': 'step-down', 'startAtMs': 37000}),
          event('reopen', 45000, {'reason': 'step-down', 'keptPicture': true}),
        ],
        requests: [request(1031700)],
      );
      expect(m['spotOffMs'], -500);
      expect(m['stepDowns'], [-1000, 35000]);
    });

    test('a stall ridden out has no reopen to time and no spot', () {
      final m = measure(
        pictures: readings(8000, 85000),
        events: const [],
        requests: [request(1031700)],
      );
      expect(m['reopenAfterServerMs'], isNull);
      expect(m['spotOffMs'], isNull);
      expect(m['reopens'], isEmpty);
    });

    test('a live reopen starts at the live edge, so it has no spot', () {
      final m = measure(
        pictures: readings(8000, 85000, frozenAt: 18000),
        events: recovered,
        media: 'live',
        pathPrefix: '/live/',
      );
      expect(m['spotOffMs'], isNull);
    });
  });
}
