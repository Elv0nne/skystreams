import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/features/player/domain/playback_recovery.dart'
    show kFirstFrameDeadline;
import 'package:skystream/features/player/presentation/vlc/player_startup_view.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_screen.dart';
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

/// The one view the player shows before there is a video: getting links,
/// checking them, opening one - and the source list that is its only control.
///
/// What is pinned here is what only the whole screen can show. Back is where
/// the controls will put it, so it does not jump when the first frame hands
/// the screen over to them. On a desktop a double-click toggles full screen,
/// as it does over the video, without making a click on Back wait out the
/// double-click window. The view survives the hand-over from checking to
/// opening as one widget. And the list's rows are live: a pick during the
/// check is honoured, and failover walks past a row the check found dead.
///
/// `_fullscreenAvailable` asks dart:io's Platform, so on every host these
/// tests run on (macOS, Linux, Windows) the double-click layer is present.
const MethodChannel _window = MethodChannel('window_manager');

void main() {
  /// Every `setFullScreen` the window was asked for, in order.
  late List<bool> fullScreenRequests;

  setUp(() {
    installEngineMocks();
    fullScreenRequests = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_window, (call) async {
          switch (call.method) {
            case 'isFullScreen':
              return false;
            case 'setFullScreen':
              fullScreenRequests.add(
                (call.arguments as Map)['isFullScreen'] as bool,
              );
          }
          return null;
        });
  });

  tearDown(() {
    removeEngineMocks();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_window, null);
  });

  /// Stands the player up on a plugin that has not answered `loadStreams`
  /// yet, which holds the screen on the resolving frame until [streams]
  /// completes.
  Future<void> pumpResolving(
    WidgetTester tester, {
    required Future<List<StreamResult>> streams,
    bool isTv = false,
    bool pushed = false,
  }) => pumpPlayer(
    tester,
    isTv: isTv,
    pushed: pushed,
    item: MultimediaItem(
      title: 'A Film',
      url: 'https://example.com/film',
      posterUrl: '',
      provider: _HeldPlugin.package,
    ),
    // The plugin's token, not a URL, so nothing short-circuits the plugin.
    videoUrl: 'film-token',
    overrides: [
      extensionManagerProvider.overrideWith(
        () => _OnePlugin(_HeldPlugin(streams)),
      ),
    ],
  );

  /// Three candidates the probe has to go to the network for, so the check
  /// lasts for as long as the test's HTTP client holds its answers.
  const probed = <StreamResult>[
    StreamResult(url: 'https://cdn.test/zero.mkv', source: 'Zero'),
    StreamResult(url: 'https://cdn.test/one.mkv', source: 'One'),
    StreamResult(url: 'https://cdn.test/two.mkv', source: 'Two'),
  ];

  String? openedUri(FakeVlcEngine engine) {
    final calls = engine.callsTo('setSource');
    if (calls.isEmpty) return null;
    return (calls.last.arguments as Map)['uri'] as String?;
  }

  /// Two clicks inside the double-click window, then long enough for the
  /// recogniser's timers to lapse so none is left pending.
  Future<void> doubleClickAt(WidgetTester tester, Offset at) async {
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await tester.pump(kDoubleTapTimeout);
  }

  for (final isTv in <bool>[false, true]) {
    testWidgets(
      'Back does not move from resolving, to opening, to playing '
      '(${isTv ? 'television' : 'phone and desktop'})',
      variant: texturePlatform,
      (tester) async {
        final streams = Completer<List<StreamResult>>();
        await pumpResolving(tester, streams: streams.future, isTv: isTv);

        expect(
          find.byType(VlcPlayer),
          findsNothing,
          reason: 'the plugin has not answered, so this is the resolving frame',
        );
        if (isTv) {
          expect(
            FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<PlayerBackButton>(),
            isNotNull,
            reason: 'with nothing else on the frame, Back takes the remote',
          );
        }
        // The top-left corner rather than the whole rect: a focused button
        // wears a 2px ring that grows its box, and Back is focused here on a
        // television while play/pause is once the controls are up.
        final resolving = tester.getTopLeft(find.byType(PlayerBackButton));

        // A bare path: one candidate, so there is no health probe to answer.
        streams.complete(const <StreamResult>[
          StreamResult(url: '/sources/film.mkv', source: '1080p'),
        ]);
        await settle(tester);

        expect(find.byKey(openingOverlayKey), findsOneWidget);
        final opening = tester.getTopLeft(
          find.descendant(
            of: find.byKey(openingOverlayKey),
            matching: find.byType(PlayerBackButton),
          ),
        );

        await sendFirstFrame(tester);

        expect(find.byKey(openingOverlayKey), findsNothing);
        final playing = tester.getTopLeft(
          find.descendant(
            of: find.byType(PlayerTopBar),
            matching: find.byType(PlayerBackButton),
          ),
        );

        expect(
          resolving,
          playing,
          reason: 'Back jumped when the controls took over from resolving',
        );
        expect(
          opening,
          playing,
          reason: 'Back jumped when the controls took over from opening',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'a double-click on the resolving frame toggles full screen, even on the '
    'spinner, and a single click does not',
    variant: texturePlatform,
    (tester) async {
      await pumpResolving(
        tester,
        streams: Completer<List<StreamResult>>().future,
      );
      final spinner = tester.getCenter(find.byType(CircularProgressIndicator));

      await tester.tapAt(spinner);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      expect(fullScreenRequests, isEmpty, reason: 'one click is not two');

      await doubleClickAt(tester, spinner);
      expect(
        fullScreenRequests,
        <bool>[true],
        reason:
            'the spinner and the status line are read-only and must let the '
            'double-click through to the layer beneath them',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a double-click on the opening overlay toggles full screen',
    variant: texturePlatform,
    (tester) async {
      await pumpPlayer(tester, isTv: false);
      expect(find.byKey(openingOverlayKey), findsOneWidget);

      await doubleClickAt(
        tester,
        tester.getCenter(
          find.descendant(
            of: find.byKey(openingOverlayKey),
            matching: find.text('Channel One'),
          ),
        ),
      );

      expect(fullScreenRequests, <bool>[true]);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Back on the resolving frame answers the first click, not the end of the '
    'double-click window',
    variant: texturePlatform,
    (tester) async {
      await pumpResolving(
        tester,
        streams: Completer<List<StreamResult>>().future,
        pushed: true,
      );
      final route = ModalRoute.of(
        tester.element(find.byType(VlcPlayerScreen)),
      )!;
      expect(route.isCurrent, isTrue);

      await tester.tap(find.byType(PlayerBackButton));
      await tester.pump();

      expect(
        route.isCurrent,
        isFalse,
        reason:
            'a double-click recogniser above Back holds the gesture arena, '
            'which delays every click on it by the double-click timeout',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'while the plugin is answering, the view says which plugin it is asking',
    variant: texturePlatform,
    (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await pumpResolving(
        tester,
        streams: Completer<List<StreamResult>>().future,
      );

      expect(find.text(l10n.playerGettingLinks('Held Plugin')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  PlayerStartupView startupView(WidgetTester tester) =>
      tester.widget<PlayerStartupView>(find.byType(PlayerStartupView));

  // With the list up, its rows already say Checking… and Opening…; a status
  // line repeating them was noise. It is kept for what rows cannot say.
  testWidgets(
    'once the list is up, the rows say what is happening, not a status line',
    variant: texturePlatform,
    (tester) async {
      final held = Completer<void>();
      final client = MockClient((request) async {
        await held.future;
        return http.Response('', 200);
      });

      await http.runWithClient(() async {
        final streams = Completer<List<StreamResult>>();
        await pumpResolving(tester, streams: streams.future);
        expect(startupView(tester).status, isNotNull, reason: 'no list yet');

        streams.complete(probed);
        await settle(tester);
        expect(startupView(tester).status, isNull, reason: 'checking');

        held.complete();
        await settle(tester);
        expect(startupView(tester).status, isNull, reason: 'opening');

        await tester.pumpWidget(const SizedBox());
      }, () => client);
    },
  );

  // Plugins file a film as a one-episode show, and the view printed
  // "S1 E1 · Full Movie" over it.
  testWidgets(
    'a film has no episode line, even filed as one episode',
    variant: texturePlatform,
    (tester) async {
      final only = Episode(
        name: 'Full Movie',
        url: 'https://example.com/film.mp4',
        season: 1,
        episode: 1,
      );
      await pumpPlayer(
        tester,
        item: MultimediaItem(
          title: 'A Film',
          url: 'https://example.com/film',
          posterUrl: '',
          provider: 'Remote',
          episodes: [only],
        ),
        episode: only,
        videoUrl: only.url,
      );

      expect(startupView(tester).episodeLine, isNull);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('an episode of a series says which', variant: texturePlatform, (
    tester,
  ) async {
    final pilot = Episode(
      name: 'Pilot',
      url: 'https://example.com/s1e1.mp4',
      season: 1,
      episode: 1,
    );
    await pumpPlayer(
      tester,
      item: MultimediaItem(
        title: 'A Show',
        url: 'https://example.com/show',
        posterUrl: '',
        provider: 'Remote',
        contentType: MultimediaContentType.series,
        episodes: [pilot],
      ),
      episode: pilot,
      videoUrl: pilot.url,
    );

    expect(startupView(tester).episodeLine, 'S1 E1 · Pilot');

    await tester.pumpWidget(const SizedBox());
  });

  // The video surface is inserted beneath the view when opening starts. As a
  // new widget the list would jump back to its top and the spinner restart at
  // exactly the moment the viewer is watching it.
  testWidgets(
    'the view is one widget from checking to opening',
    variant: texturePlatform,
    (tester) async {
      final held = Completer<void>();
      final client = MockClient((request) async {
        await held.future;
        return http.Response('', 200);
      });

      await http.runWithClient(() async {
        final streams = Completer<List<StreamResult>>();
        await pumpResolving(tester, streams: streams.future);
        streams.complete(probed);
        await settle(tester);

        expect(find.byType(VlcPlayer), findsNothing, reason: 'still checking');
        final checking = tester.state(find.byType(PlayerStartupView));

        held.complete();
        await settle(tester);

        expect(find.byType(VlcPlayer), findsOneWidget, reason: 'now opening');
        expect(
          identical(tester.state(find.byType(PlayerStartupView)), checking),
          isTrue,
        );

        await tester.pumpWidget(const SizedBox());
      }, () => client);
    },
  );

  // Spec 1.8: libVLC and its output are created while the route animates
  // and the links resolve, not after them.
  testWidgets(
    'the native player is created while the links resolve, offstage until '
    'the media is handed over',
    variant: texturePlatform,
    (tester) async {
      final engine = FakeVlcEngine();
      installEngineMocks(engine: engine);
      final client = MockClient((request) async => http.Response('', 200));

      await http.runWithClient(() async {
        final streams = Completer<List<StreamResult>>();
        await pumpResolving(tester, streams: streams.future);

        expect(engine.callsTo('create'), hasLength(1));
        expect(engine.callsTo('setSource'), isEmpty);
        expect(find.byType(VlcPlayer, skipOffstage: false), findsOneWidget);
        expect(find.byType(VlcPlayer), findsNothing, reason: 'offstage');

        streams.complete(probed);
        await settle(tester);

        expect(openedUri(engine), 'https://cdn.test/zero.mkv');
        expect(
          engine.callsTo('create'),
          hasLength(1),
          reason: 'the player made early is the one that opens the media',
        );
        expect(find.byType(VlcPlayer), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      }, () => client);
    },
  );

  testWidgets(
    'a row selected while the check runs is the row that opens',
    variant: texturePlatform,
    (tester) async {
      final engine = FakeVlcEngine();
      installEngineMocks(engine: engine);
      final held = Completer<void>();
      final client = MockClient((request) async {
        await held.future;
        return http.Response('', 200);
      });

      await http.runWithClient(() async {
        final streams = Completer<List<StreamResult>>();
        await pumpResolving(tester, streams: streams.future);
        streams.complete(probed);
        await settle(tester);
        expect(openedUri(engine), isNull, reason: 'the check is still out');

        await tester.tap(find.byKey(PlayerStartupView.rowKey(2)));
        await settle(tester);

        expect(
          openedUri(engine),
          'https://cdn.test/two.mkv',
          reason: 'the check would have opened Zero; the viewer chose Two',
        );

        held.complete();
        await settle(tester);
        await tester.pumpWidget(const SizedBox());
      }, () => client);
    },
  );

  // The race only checks the top three. A row picked from past them used to
  // open with its reachability column blank for good; now it is checked
  // while it opens, without holding the open up.
  testWidgets(
    'a row picked from past the top three is checked while it opens',
    variant: texturePlatform,
    (tester) async {
      final engine = FakeVlcEngine();
      installEngineMocks(engine: engine);
      final fourAnswers = Completer<void>();
      // Answers the way a media server does, serving the probe's range: a
      // plain 200 would say the server ignores ranges, which the row calls
      // "Can't seek" rather than "Reachable".
      final client = MockClient((request) async {
        if (request.url.path == '/four.mkv') await fourAnswers.future;
        return http.Response(
          '',
          206,
          headers: {
            'content-type': 'video/x-matroska',
            'content-range': 'bytes 0-1023/1048576',
          },
        );
      });

      await http.runWithClient(() async {
        final l10n = await AppLocalizations.delegate.load(const Locale('en'));
        final streams = Completer<List<StreamResult>>();
        await pumpResolving(tester, streams: streams.future);
        streams.complete(const <StreamResult>[
          ...probed,
          StreamResult(url: 'https://cdn.test/three.mkv', source: 'Three'),
          StreamResult(url: 'https://cdn.test/four.mkv', source: 'Four'),
        ]);
        await settle(tester);
        Finder inRow(int index, String text) => find.descendant(
          of: find.byKey(PlayerStartupView.rowKey(index)),
          matching: find.text(text),
        );
        expect(
          inRow(4, l10n.playerSourceChecking),
          findsNothing,
          reason: 'past the top three, so the race never asked',
        );

        await tester.tap(find.byKey(PlayerStartupView.rowKey(4)));
        await settle(tester);

        expect(
          openedUri(engine),
          'https://cdn.test/four.mkv',
          reason: 'the check runs alongside the open, not in front of it',
        );
        expect(inRow(4, l10n.playerSourceChecking), findsOneWidget);
        expect(inRow(4, l10n.playerSourceOpening), findsOneWidget);

        fourAnswers.complete();
        await settle(tester);

        expect(inRow(4, l10n.playerSourceReachable), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      }, () => client);
    },
  );

  /// Zero to Two answer the race; Three and Four are past it. Four refuses
  /// both of the probe's requests unless [fourHeld] is given, in which case
  /// it refuses only once that completes.
  MockClient refusingFour({Future<void>? fourHeld}) =>
      MockClient((request) async {
        if (request.url.path == '/four.mkv') {
          if (fourHeld != null) await fourHeld;
          if (request.method == 'HEAD') return http.Response('', 404);
          throw http.ClientException('refused', request.url);
        }
        return http.Response('', 200);
      });

  Future<void> pumpFive(WidgetTester tester) async {
    final streams = Completer<List<StreamResult>>();
    await pumpResolving(tester, streams: streams.future);
    streams.complete(const <StreamResult>[
      ...probed,
      StreamResult(url: 'https://cdn.test/three.mkv', source: 'Three'),
      StreamResult(url: 'https://cdn.test/four.mkv', source: 'Four'),
    ]);
    await settle(tester);
  }

  Finder rowText(int index, String text) => find.descendant(
    of: find.byKey(PlayerStartupView.rowKey(index)),
    matching: find.text(text),
  );

  testWidgets(
    'a picked row the check finds unreachable is abandoned for one it '
    'vouched for',
    variant: texturePlatform,
    (tester) async {
      final engine = FakeVlcEngine();
      installEngineMocks(engine: engine);

      await http.runWithClient(() async {
        final l10n = await AppLocalizations.delegate.load(const Locale('en'));
        await pumpFive(tester);
        expect(openedUri(engine), 'https://cdn.test/zero.mkv');

        await tester.tap(find.byKey(PlayerStartupView.rowKey(4)));
        await settle(tester);

        expect(
          openedUri(engine),
          'https://cdn.test/zero.mkv',
          reason: 'back to a source the check vouched for, not on to Three',
        );
        expect(rowText(4, l10n.unknown), findsOneWidget);
        expect(rowText(4, l10n.playerSourceUnplayable), findsOneWidget);
        expect(
          find.text('Four · ${l10n.playerReasonNoAnswer}'),
          findsOneWidget,
        );

        // Picked again, it opens: the check has had its say once, and a slow
        // host it wrongly failed has to stay playable.
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.byKey(PlayerStartupView.rowKey(4)));
        await settle(tester);

        expect(openedUri(engine), 'https://cdn.test/four.mkv');
        expect(rowText(4, l10n.playerSourceOpening), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      }, refusingFour);
    },
  );

  testWidgets(
    'a picture before the check answers keeps the source',
    variant: texturePlatform,
    (tester) async {
      final engine = FakeVlcEngine();
      installEngineMocks(engine: engine);
      final fourAnswers = Completer<void>();

      await http.runWithClient(() async {
        await pumpFive(tester);
        await tester.tap(find.byKey(PlayerStartupView.rowKey(4)));
        await settle(tester);
        expect(openedUri(engine), 'https://cdn.test/four.mkv');
        await sendFirstFrame(tester);
        final opens = engine.callsTo('setSource').length;

        fourAnswers.complete();
        await settle(tester);

        expect(
          engine.callsTo('setSource'),
          hasLength(opens),
          reason: 'a source on screen was reached, whatever the probe says',
        );

        await tester.pumpWidget(const SizedBox());
      }, () => refusingFour(fourHeld: fourAnswers.future));
    },
  );

  testWidgets(
    'with nowhere vouched for to go, the only source keeps opening',
    variant: texturePlatform,
    (tester) async {
      final engine = FakeVlcEngine();
      installEngineMocks(engine: engine);
      final client = MockClient((request) async {
        if (request.method == 'HEAD') return http.Response('', 404);
        throw http.ClientException('refused', request.url);
      });

      await http.runWithClient(() async {
        final l10n = await AppLocalizations.delegate.load(const Locale('en'));
        final streams = Completer<List<StreamResult>>();
        await pumpResolving(tester, streams: streams.future);
        streams.complete(const <StreamResult>[
          StreamResult(url: 'https://cdn.test/only.mkv', source: 'Only'),
        ]);
        await settle(tester);

        expect(openedUri(engine), 'https://cdn.test/only.mkv');
        expect(engine.callsTo('setSource'), hasLength(1));
        expect(
          find.text(l10n.retry),
          findsNothing,
          reason:
              'the probe alone does not end the only hope - it is wrong '
              'about slow hosts',
        );

        await tester.pumpWidget(const SizedBox());
      }, () => client);
    },
  );

  // A link can answer the check and still never produce a frame - libVLC
  // parked on a stream it cannot start reports neither an error nor an end.
  // Each link gets [kFirstFrameDeadline] from the moment it starts opening.
  Future<FakeVlcEngine> pumpStuckThenNext(WidgetTester tester) async {
    final engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
    await pumpPlayer(
      tester,
      preloadedStreams: const <StreamResult>[
        StreamResult(url: '/sources/stuck.mkv', source: 'Stuck'),
        StreamResult(url: '/sources/next.mkv', source: 'Next'),
      ],
    );
    expect(openedUri(engine), endsWith('stuck.mkv'));
    return engine;
  }

  Future<void> waitSeconds(WidgetTester tester, int seconds) async {
    for (var i = 0; i < seconds; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  for (final state in <String>['buffering', 'opening', 'stopped', 'paused']) {
    testWidgets(
      'a link that never starts is given up on after the deadline, even '
      'reported $state',
      variant: texturePlatform,
      (tester) async {
        final engine = await pumpStuckThenNext(tester);
        final l10n = await AppLocalizations.delegate.load(const Locale('en'));

        await sendEvent(tester, snapshot(state: state, position: 0));
        await waitSeconds(tester, kFirstFrameDeadline.inSeconds - 3);
        expect(
          openedUri(engine),
          endsWith('stuck.mkv'),
          reason: 'still inside the deadline',
        );

        await waitSeconds(tester, 4);
        expect(openedUri(engine), endsWith('next.mkv'));
        expect(
          find.textContaining(l10n.playerReasonSourceNeverStarted),
          findsOneWidget,
        );

        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'a picture before the deadline keeps the link',
    variant: texturePlatform,
    (tester) async {
      final engine = await pumpStuckThenNext(tester);
      await sendFirstFrame(tester);
      await waitSeconds(tester, kFirstFrameDeadline.inSeconds + 2);

      expect(openedUri(engine), endsWith('stuck.mkv'));

      await sendEvent(tester, snapshot(state: 'paused'));
      await tester.pumpWidget(const SizedBox());
    },
  );

  // A resume opens the source at its saved place, and libVLC reports the
  // position as zero until the new media has played anything. The drop from
  // the saved place to zero counted as the position moving - the only proof
  // of a picture the screen accepts - so the loading screen gave way to a
  // black screen and the controls before anything had been drawn.
  testWidgets(
    'a resumed source reporting zero while it opens has not drawn a picture',
    variant: texturePlatform,
    (tester) async {
      await pumpPlayer(
        tester,
        preloadedStreams: const <StreamResult>[
          StreamResult(url: '/sources/film.mkv', source: '1080p'),
        ],
        overrides: [
          historyRepositoryProvider.overrideWithValue(_ResumeAtTenMinutes()),
        ],
      );
      expect(find.byKey(openingOverlayKey), findsOneWidget);

      await sendEvent(tester, snapshot(state: 'opening', position: 0));
      expect(
        find.byKey(openingOverlayKey),
        findsOneWidget,
        reason: 'zero is the engine saying nothing has played yet',
      );

      await sendEvent(tester, snapshot(position: 600250, duration: 1200000));
      expect(find.byKey(openingOverlayKey), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  // Resuming, a row picked on the loading screen while the first source was
  // still opening: the pick reopens at the saved place, and the engine, on
  // its way into the new source, reports zero. That counted as a picture, so
  // the loading screen went, and the new source's first moments - playing,
  // with no length yet and nothing to seek in, which libVLC calls live - read
  // as LIVE over a black screen.
  testWidgets(
    'a row picked while a resumed source opens keeps the loading screen up',
    variant: texturePlatform,
    (tester) async {
      final engine = FakeVlcEngine();
      installEngineMocks(engine: engine);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await pumpPlayer(
        tester,
        preloadedStreams: const <StreamResult>[
          StreamResult(url: '/sources/one.mkv', source: 'One'),
          StreamResult(url: '/sources/two.mkv', source: 'Two'),
          StreamResult(url: '/sources/three.mkv', source: 'Three'),
        ],
        overrides: [
          historyRepositoryProvider.overrideWithValue(_ResumeAtTenMinutes()),
        ],
      );
      expect(openedUri(engine), endsWith('one.mkv'));

      await tester.tap(find.byKey(PlayerStartupView.rowKey(2)));
      await settle(tester);
      expect(openedUri(engine), endsWith('three.mkv'));

      await sendEvent(tester, <String, Object?>{
        ...snapshot(position: 0),
        'isSeekable': false,
        'isLive': true,
      });

      expect(find.byKey(openingOverlayKey), findsOneWidget);
      expect(find.text(l10n.live), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failover walks past a row the check found unreachable',
    variant: texturePlatform,
    (tester) async {
      final engine = FakeVlcEngine();
      installEngineMocks(engine: engine);
      // Zero and Two answer; One refuses both the HEAD and the ranged GET.
      final client = MockClient((request) async {
        if (request.url.path == '/one.mkv') {
          if (request.method == 'HEAD') return http.Response('', 404);
          throw http.ClientException('refused', request.url);
        }
        return http.Response('', 200);
      });

      await http.runWithClient(() async {
        final l10n = await AppLocalizations.delegate.load(const Locale('en'));
        final streams = Completer<List<StreamResult>>();
        await pumpResolving(tester, streams: streams.future);
        streams.complete(probed);
        await settle(tester);
        expect(openedUri(engine), 'https://cdn.test/zero.mkv');

        // Zero dies before it ever plays.
        await sendEvent(tester, snapshot(state: 'error'));
        await settle(tester);

        expect(
          openedUri(engine),
          'https://cdn.test/two.mkv',
          reason:
              'One is next in line, but the check already found it dead, and '
              'a dead source that hangs costs the full stall deadline',
        );
        expect(find.textContaining(l10n.sourceAttempt(3, 3)), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      }, () => client);
    },
  );
}

/// Ten minutes into a twenty-minute film, so the screen opens its source at a
/// saved place.
class _ResumeAtTenMinutes extends NoHistory {
  @override
  int getPosition(String url) => 600000;

  @override
  int getDuration(String url) => 1200000;
}

/// A plugin whose `loadStreams` answers when the test says so.
class _HeldPlugin extends SkyStreamProvider {
  _HeldPlugin(this.streams);

  static const String package = 'held.plugin';

  final Future<List<StreamResult>> streams;

  @override
  String get packageName => package;
  @override
  String get name => 'Held Plugin';
  @override
  String get mainUrl => 'https://example.com';
  @override
  String get version => '1.0.0';
  @override
  List<String> get languages => const <String>['en'];
  @override
  Set<ProviderType> get supportedTypes => <ProviderType>{ProviderType.movie};

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) => throw UnimplementedError();
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();

  @override
  Future<List<StreamResult>> loadStreams(String url) => streams;
}

/// The extension manager with one plugin in it and no JS engine behind it.
class _OnePlugin extends ExtensionManager {
  _OnePlugin(this.plugin);

  final SkyStreamProvider plugin;

  @override
  List<SkyStreamProvider> build() => <SkyStreamProvider>[plugin];
}
