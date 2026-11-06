/// The panel's Subtitle style page: every setting of how subtitles look,
/// stepped in place while the video plays.
///
/// Both renderers follow it. SkyStream's own subtitle files restyle at once.
/// libVLC's lines inside the video take the size, the colours, the box, the
/// outline and the lift from their next line - the screen hands it each
/// change, see `subtitleLookFrom` - and bold, the font, the text opacity and
/// the encoding only when the player next opens, which the page says under a
/// heading of their own.
///
/// Every value is a [PanelStepperRow]: Left/Right on a remote, -/+ under a
/// thumb, Select or the row's reset button for its default. A change is the
/// viewer's setting from then on, written through [PlayerSettingsNotifier]
/// like any other, so the next video starts with it too.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../../../settings/presentation/player_settings_provider.dart';
import '../../../../settings/presentation/widgets/subtitle_appearance_settings.dart';
import 'player_panel_metrics.dart';
import 'player_panel_row.dart';

/// The viewer's subtitle settings as the Subtitle style page reads and writes
/// them.
///
/// Handed in by the screen like the panel's other callbacks: the panel is a
/// route of its own and reads no providers.
@immutable
class SubtitleStyleBinding {
  const SubtitleStyleBinding({required this.settings, required this.notifier});

  /// The settings as they stand, republished by the screen on every change.
  final ValueListenable<PlayerSettings> settings;

  /// What a change goes through. Asked at each change rather than held:
  /// Riverpod makes a new notifier whenever the provider is built again.
  final PlayerSettingsNotifier Function() notifier;
}

/// What a fresh install has, which is what each row resets to.
const PlayerSettings _fresh = PlayerSettings();

/// The page's body, under the panel's title and Back.
class SubtitleStylePage extends StatelessWidget {
  const SubtitleStylePage({required this.style, super.key});

  final SubtitleStyleBinding style;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final metrics = PlayerPanelMetrics.of(context);
    return ValueListenableBuilder<PlayerSettings>(
      valueListenable: style.settings,
      // Every row keyed, so a row coming or going - the box's opacity, as
      // the box goes off or comes back - moves the others' elements with
      // them, and focus stays on the row that had it.
      builder: (context, settings, _) => ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: <Widget>[
          ..._live(l10n, settings),
          PanelSubheader(
            key: const ValueKey<String>('nextTime'),
            title: l10n.subtitleNextTime,
          ),
          Padding(
            key: const ValueKey<String>('nextTimeNote'),
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
            child: Text(
              l10n.subtitleNextTimeNote,
              style: TextStyle(
                color: metrics.mutedText,
                fontSize: metrics.rowDetailSize,
              ),
            ),
          ),
          ..._nextTime(l10n, settings),
          PanelRow(
            key: const ValueKey<String>('reset'),
            label: l10n.resetSubtitleStyle,
            icon: Icons.restart_alt_rounded,
            onTap: () => _write((notifier) => notifier.resetSubtitleSettings()),
          ),
        ],
      ),
    );
  }

  /// A row's handler has nowhere to hand a future, so the write runs on its
  /// own; the row moves when the settings come back changed.
  void _write(Future<void> Function(PlayerSettingsNotifier notifier) change) =>
      unawaited(change(style.notifier()));

  /// What libVLC also restyles while the video plays.
  List<Widget> _live(AppLocalizations l10n, PlayerSettings settings) {
    final size = settings.subtitleSize.round();
    void resize(int to) {
      final next = to.clamp(10, 80);
      if (next != size) {
        _write((notifier) => notifier.setSubtitleSize(next.toDouble()));
      }
    }

    // Zero opacity is what "no box" is, so Off is a place in the list of box
    // colours rather than a switch of its own.
    final box = settings.subtitleBackgroundOpacity > 0
        ? subtitleBackgroundColorOf(settings.subtitleBackgroundColor)
        : null;
    final opacity = (settings.subtitleBackgroundOpacity * 100).round();
    void setOpacity(int percent) => _write(
      (notifier) => notifier.setSubtitleBackgroundOpacity(percent / 100),
    );
    // Tens, from a tenth to opaque: none at all is Off, a row up.
    final moreOpaque = math.min(100, (opacity ~/ 10 + 1) * 10);
    final lessOpaque = math.max(10, ((opacity - 1) ~/ 10) * 10);

    final raise = nearestSubtitleChoice(
      kSubtitleRaises,
      settings.subtitleRaise,
    );

    return <Widget>[
      PanelStepperRow(
        key: const ValueKey<String>('size'),
        label: l10n.textSize,
        value: '$size',
        increasedValue: size < 80 ? '${size + 1}' : null,
        decreasedValue: size > 10 ? '${size - 1}' : null,
        autofocus: true,
        resetTooltip: l10n.resetToDefault,
        onDecrease: (step) => resize(size - _sizeStep(step)),
        onIncrease: (step) => resize(size + _sizeStep(step)),
        onReset: size == _fresh.subtitleSize.round()
            ? null
            : () => resize(_fresh.subtitleSize.round()),
      ),
      _choice<int>(
        l10n,
        key: const ValueKey<String>('textColour'),
        label: l10n.subtitleTextColour,
        choices: kSubtitleTextColors,
        current: settings.subtitleColor,
        name: (argb) => subtitleColorLabel(l10n, argb),
        wraps: true,
        choose: (argb) => _write((notifier) => notifier.setSubtitleColor(argb)),
        rest: _fresh.subtitleColor,
      ),
      _choice<int?>(
        l10n,
        key: const ValueKey<String>('background'),
        label: l10n.background,
        choices: <int?>[null, ...kSubtitleBackgroundColors],
        current: box,
        name: (argb) =>
            argb == null ? l10n.off : subtitleColorLabel(l10n, argb),
        wraps: true,
        // A colour picked while the box is off means "a box, please", so it
        // comes with something to show; otherwise the opacity stays.
        choose: (argb) => _write(
          (notifier) => argb == null
              ? notifier.setSubtitleBackgroundOpacity(0)
              : notifier.setSubtitleBackground(
                  argb,
                  box == null
                      ? _fresh.subtitleBackgroundOpacity
                      : settings.subtitleBackgroundOpacity,
                ),
        ),
        rest: subtitleBackgroundColorOf(_fresh.subtitleBackgroundColor),
        // Back to the box a fresh install draws, its opacity too.
        reset: () => _write(
          (notifier) => notifier.setSubtitleBackground(
            _fresh.subtitleBackgroundColor,
            _fresh.subtitleBackgroundOpacity,
          ),
        ),
      ),
      if (box != null)
        PanelStepperRow(
          key: const ValueKey<String>('backgroundOpacity'),
          label: l10n.subtitleBackgroundOpacity,
          value: l10n.subtitlePercent(opacity),
          increasedValue: moreOpaque > opacity
              ? l10n.subtitlePercent(moreOpaque)
              : null,
          decreasedValue: lessOpaque < opacity
              ? l10n.subtitlePercent(lessOpaque)
              : null,
          resetTooltip: l10n.resetToDefault,
          onDecrease: (_) {
            if (lessOpaque < opacity) setOpacity(lessOpaque);
          },
          onIncrease: (_) {
            if (moreOpaque > opacity) setOpacity(moreOpaque);
          },
          onReset:
              settings.subtitleBackgroundOpacity ==
                  _fresh.subtitleBackgroundOpacity
              ? null
              : () => setOpacity(
                  (_fresh.subtitleBackgroundOpacity * 100).round(),
                ),
        ),
      _choice<SubtitleOutline>(
        l10n,
        key: const ValueKey<String>('outline'),
        label: l10n.subtitleOutline,
        choices: SubtitleOutline.values,
        current: settings.subtitleOutline,
        name: (outline) => subtitleOutlineLabel(l10n, outline),
        choose: (outline) =>
            _write((notifier) => notifier.setSubtitleOutline(outline)),
        rest: _fresh.subtitleOutline,
      ),
      _choice<double>(
        l10n,
        key: const ValueKey<String>('position'),
        label: l10n.subtitlePosition,
        choices: kSubtitleRaises,
        current: raise,
        name: (lift) => subtitlePositionLabel(l10n, lift),
        choose: (lift) => _write((notifier) => notifier.setSubtitleRaise(lift)),
        rest: _fresh.subtitleRaise,
      ),
    ];
  }

  /// What libVLC takes only when a player is created; subtitle files follow
  /// them at once.
  List<Widget> _nextTime(AppLocalizations l10n, PlayerSettings settings) {
    return <Widget>[
      _choice<bool>(
        l10n,
        key: const ValueKey<String>('bold'),
        label: l10n.subtitleBold,
        choices: const <bool>[false, true],
        current: settings.subtitleBold,
        name: (bold) => bold ? l10n.on : l10n.off,
        wraps: true,
        choose: (bold) => _write((notifier) => notifier.setSubtitleBold(bold)),
        rest: _fresh.subtitleBold,
      ),
      _choice<SubtitleFont>(
        l10n,
        key: const ValueKey<String>('font'),
        label: l10n.subtitleFont,
        choices: SubtitleFont.values,
        current: settings.subtitleFont,
        name: (font) => subtitleFontLabel(l10n, font),
        wraps: true,
        choose: (font) => _write((notifier) => notifier.setSubtitleFont(font)),
        rest: _fresh.subtitleFont,
      ),
      // Faintest first, so Right is more of it, as on the box's opacity.
      _choice<double>(
        l10n,
        key: const ValueKey<String>('textOpacity'),
        label: l10n.subtitleTextOpacity,
        choices: kSubtitleTextOpacities.reversed.toList(growable: false),
        current: nearestSubtitleChoice(
          kSubtitleTextOpacities,
          settings.subtitleTextOpacity,
        ),
        name: (opacity) => subtitleOpacityLabel(l10n, opacity),
        choose: (opacity) =>
            _write((notifier) => notifier.setSubtitleTextOpacity(opacity)),
        rest: _fresh.subtitleTextOpacity,
      ),
      _choice<String>(
        l10n,
        key: const ValueKey<String>('encoding'),
        label: l10n.subtitleEncoding,
        choices: kSubtitleEncodings,
        current: settings.subtitleEncoding,
        name: (encoding) => subtitleEncodingLabel(l10n, encoding),
        wraps: true,
        choose: (encoding) =>
            _write((notifier) => notifier.setSubtitleEncoding(encoding)),
        rest: _fresh.subtitleEncoding,
      ),
    ];
  }

  /// A row stepping through [choices], with Select back to [rest] whenever it
  /// is elsewhere - by choosing [rest], or by [reset] where going back is
  /// more than that.
  ///
  /// A list with an order, a scale, stops at either end; one without, like
  /// the colours, goes round. [current] can be off the list - a colour an
  /// older build stored - and is then named as it is, and the first step lands
  /// on the list.
  Widget _choice<T>(
    AppLocalizations l10n, {
    required Key key,
    required String label,
    required List<T> choices,
    required T current,
    required String Function(T value) name,
    required void Function(T value) choose,
    required T rest,
    bool wraps = false,
    VoidCallback? reset,
  }) {
    final at = choices.indexOf(current);
    // Where a step [by] lands, or null where it would not move.
    int? to(int by) {
      final int next;
      if (at < 0) {
        next = by > 0 ? 0 : choices.length - 1;
      } else if (wraps) {
        next = (at + by) % choices.length;
      } else {
        next = (at + by).clamp(0, choices.length - 1);
      }
      return next == at ? null : next;
    }

    void step(int by) {
      final next = to(by);
      if (next != null) choose(choices[next]);
    }

    String? said(int by) {
      final next = to(by);
      return next == null ? null : name(choices[next]);
    }

    return PanelStepperRow(
      key: key,
      label: label,
      value: name(current),
      increasedValue: said(1),
      decreasedValue: said(-1),
      resetTooltip: l10n.resetToDefault,
      onDecrease: (_) => step(-1),
      onIncrease: (_) => step(1),
      onReset: current == rest ? null : (reset ?? () => choose(rest)),
    );
  }
}

/// A press moves the size one; a held key four at a time.
int _sizeStep(PanelStep step) => switch (step) {
  PanelStep.fine => 1,
  PanelStep.coarse => 4,
};
