import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/ended_card.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// The card on its own, with no engine anywhere near it - which is the point
/// of it taking every value in. What the *screen* does with it (when it goes
/// up, what it unmounts, where Back goes) is screen_ended_test's.
Widget _host(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [child]),
    ),
  );
}

/// A 1080p television at the density Android TV actually reports: 960x540
/// logical dp, the same budget vlc_screen_harness.dart spends. Set as the real
/// window rather than as a MediaQuery override, so the card is measured at the
/// size it is told it has.
void _television(WidgetTester tester) {
  tester.view.physicalSize = const Size(960, 540);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

String? get _focusLabel => FocusManager.instance.primaryFocus?.debugLabel;

Future<AppLocalizations> _english() =>
    AppLocalizations.delegate.load(const Locale('en'));

/// A game controller's Select. Android is the only platform whose tables carry
/// BUTTON_A, and it is the platform that matters: a Shield remote, an Xbox or
/// PlayStation pad, and any Android TV device reporting DPAD_CENTER as
/// BUTTON_A all arrive here.
Future<void> _sendGameButtonA(WidgetTester tester) => tester.sendKeyEvent(
  LogicalKeyboardKey.gameButtonA,
  platform: 'android',
  physicalKey: PhysicalKeyboardKey.gameButtonA,
);

void main() {
  group('EndedCard', () {
    testWidgets('a finished film offers Start Over and Close, and no more', (
      tester,
    ) async {
      final l10n = await _english();
      await tester.pumpWidget(
        _host(
          EndedCard(
            key: endedCardKey,
            title: 'The Matrix',
            kind: EndedKind.finished,
            onStartOver: () {},
            onClose: () {},
          ),
        ),
      );

      expect(find.byKey(endedCardKey), findsOneWidget);
      expect(find.text(l10n.playerFinished('The Matrix')), findsOneWidget);
      expect(find.text(l10n.startOver), findsOneWidget);
      expect(find.text(l10n.close), findsOneWidget);
      expect(
        find.text(l10n.next),
        findsNothing,
        reason: 'nothing follows a film; offering Next would be a dead button',
      );
    });

    testWidgets('a declined episode is offered back, named', (tester) async {
      final l10n = await _english();
      await tester.pumpWidget(
        _host(
          EndedCard(
            key: endedCardKey,
            title: 'Ep 01',
            kind: EndedKind.declinedNext,
            nextLabel: l10n.playEpisode(l10n.next, 1, 2),
            onNextEpisode: () {},
            onStartOver: () {},
            onClose: () {},
          ),
        ),
      );

      expect(
        find.text(l10n.playEpisode(l10n.next, 1, 2)),
        findsOneWidget,
        reason:
            'owner decision 2: the refusal is honoured, so the binge has to '
            'stay one press away',
      );
      expect(find.text(l10n.startOver), findsOneWidget);
      expect(find.text(l10n.close), findsOneWidget);
      expect(
        find.text(l10n.playerFinished('Ep 01')),
        findsOneWidget,
        reason:
            'the episode finished, not the series - the screen hands the '
            'episode name in for exactly this',
      );
    });

    testWidgets('the label falls back to a plain Next with no numbers', (
      tester,
    ) async {
      final l10n = await _english();
      await tester.pumpWidget(
        _host(
          EndedCard(
            key: endedCardKey,
            title: 'Ep 01',
            kind: EndedKind.declinedNext,
            onNextEpisode: () {},
            onStartOver: () {},
            onClose: () {},
          ),
        ),
      );

      expect(find.text(l10n.next), findsOneWidget);
    });

    testWidgets('every action reports exactly once, and only its own', (
      tester,
    ) async {
      final l10n = await _english();
      var next = 0;
      var startOver = 0;
      var close = 0;
      await tester.pumpWidget(
        _host(
          EndedCard(
            key: endedCardKey,
            title: 'Ep 01',
            kind: EndedKind.declinedNext,
            onNextEpisode: () => next++,
            onStartOver: () => startOver++,
            onClose: () => close++,
          ),
        ),
      );

      await tester.tap(find.text(l10n.next));
      await tester.pump();
      expect([next, startOver, close], [1, 0, 0]);

      await tester.tap(find.text(l10n.startOver));
      await tester.pump();
      expect([next, startOver, close], [1, 1, 0]);

      await tester.tap(find.text(l10n.close));
      await tester.pump();
      expect([next, startOver, close], [1, 1, 1]);
    });

    group('on a television', () {
      testWidgets(
        'exactly one node autofocuses, and it is the primary action',
        (tester) async {
          _television(tester);
          await tester.pumpWidget(
            _host(
              EndedCard(
                key: endedCardKey,
                title: 'The Matrix',
                kind: EndedKind.finished,
                isTv: true,
                onStartOver: () {},
                onClose: () {},
              ),
            ),
          );
          await tester.pump();

          expect(
            _focusLabel,
            kEndedStartOverFocusLabel,
            reason:
                'with nothing following, Start Over is the action the remote '
                'should already be on',
          );

          final autofocusing = tester
              .widgetList<Focus>(
                find.descendant(
                  of: find.byKey(endedCardKey),
                  matching: find.byType(Focus),
                ),
              )
              .where((focus) => focus.autofocus);
          expect(
            autofocusing,
            hasLength(1),
            reason:
                'two autofocus nodes resolving into one scope is a framework '
                'assertion, not a race',
          );
        },
      );

      testWidgets('a declined episode takes the remote instead', (
        tester,
      ) async {
        _television(tester);
        await tester.pumpWidget(
          _host(
            EndedCard(
              key: endedCardKey,
              title: 'Ep 01',
              kind: EndedKind.declinedNext,
              isTv: true,
              onNextEpisode: () {},
              onStartOver: () {},
              onClose: () {},
            ),
          ),
        );
        await tester.pump();

        expect(_focusLabel, kEndedNextFocusLabel);
      });

      testWidgets('every action is one focus stop, reached by the D-pad', (
        tester,
      ) async {
        _television(tester);
        await tester.pumpWidget(
          _host(
            EndedCard(
              key: endedCardKey,
              title: 'Ep 01',
              kind: EndedKind.declinedNext,
              isTv: true,
              onNextEpisode: () {},
              onStartOver: () {},
              onClose: () {},
            ),
          ),
        );
        await tester.pump();
        expect(_focusLabel, kEndedNextFocusLabel);

        // One press per control, with nothing in between. A button whose
        // InkWell is left focusable is two stops at identical geometry, and
        // the second answers no keys - a press that visibly does nothing.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(_focusLabel, kEndedStartOverFocusLabel);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(_focusLabel, kEndedCloseFocusLabel);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(_focusLabel, kEndedStartOverFocusLabel);
      });

      testWidgets('a game controller A activates the focused action', (
        tester,
      ) async {
        var startOver = 0;
        _television(tester);
        await tester.pumpWidget(
          _host(
            EndedCard(
              key: endedCardKey,
              title: 'The Matrix',
              kind: EndedKind.finished,
              isTv: true,
              onStartOver: () => startOver++,
              onClose: () {},
            ),
          ),
        );
        await tester.pump();
        expect(_focusLabel, kEndedStartOverFocusLabel);

        await _sendGameButtonA(tester);
        await tester.pump();
        expect(
          startOver,
          1,
          reason:
              'every Android TV device reporting DPAD_CENTER as BUTTON_A '
              'presses this button',
        );
      });

      testWidgets('Back is left to the route, not swallowed by the card', (
        tester,
      ) async {
        var closed = 0;
        _television(tester);
        await tester.pumpWidget(
          _host(
            EndedCard(
              key: endedCardKey,
              title: 'The Matrix',
              kind: EndedKind.finished,
              isTv: true,
              onStartOver: () {},
              onClose: () => closed++,
            ),
          ),
        );
        await tester.pump();

        await tester.sendKeyEvent(
          LogicalKeyboardKey.goBack,
          platform: 'android',
          physicalKey: PhysicalKeyboardKey.escape,
        );
        await tester.pump();

        expect(
          closed,
          0,
          reason:
              'unlike the up-next card there is nothing here to cancel: Back '
              'falls through to the screen\'s PopScope, which pops. A handler '
              'here would answer the press twice',
        );
      });

      testWidgets('the overscan band is kept clear', (tester) async {
        _television(tester);
        await tester.pumpWidget(
          _host(
            EndedCard(
              key: endedCardKey,
              title: 'The Matrix',
              kind: EndedKind.finished,
              isTv: true,
              onStartOver: () {},
              onClose: () {},
            ),
          ),
        );
        await tester.pump();

        // Owner decision 5: 48 dp of title-safe area, honoured on the one
        // surface that is full-bleed by construction.
        final card = tester.getRect(find.byKey(endedCardKey));
        final headline = tester.getRect(find.byType(Text).first);
        expect(headline.top, greaterThanOrEqualTo(card.top + 48));
        expect(headline.left, greaterThanOrEqualTo(card.left + 48));
        expect(headline.right, lessThanOrEqualTo(card.right - 48));
      });
    });

    testWidgets('the backdrop is a paint, not an effect layer', (tester) async {
      _television(tester);
      await tester.pumpWidget(
        _host(
          EndedCard(
            key: endedCardKey,
            title: 'The Matrix',
            kind: EndedKind.finished,
            isTv: true,
            onStartOver: () {},
            onClose: () {},
          ),
        ),
      );

      // The card is full-bleed by design, so any effect layer in it is
      // window-sized - which over a platform view is re-surfaced on every
      // show/hide and is what black-framed macOS and iOS. controls_layer_
      // shape_test holds the same line from the other end; this says it in
      // the card's own file so the reason travels with the widget.
      final layers = <String>[];
      void visit(RenderObject node) {
        if (node is RenderOpacity ||
            node is RenderAnimatedOpacity ||
            node is RenderBackdropFilter ||
            node is RenderShaderMask) {
          layers.add(node.runtimeType.toString());
        }
        node.visitChildren(visit);
      }

      visit(tester.renderObject(find.byKey(endedCardKey)));
      expect(layers, isEmpty);
      expect(
        find.byType(ColoredBox),
        findsWidgets,
        reason: 'the dimming is a paint into the layer that is already there',
      );
    });
  });
}
