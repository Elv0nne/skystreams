/// The subtitle appearance editor, back where it can be reached.
///
/// `subtitle_style.dart` has always translated [PlayerSettings.subtitleSize],
/// [PlayerSettings.subtitleColor], [PlayerSettings.subtitleBackgroundColor] and
/// [PlayerSettings.subtitleBackgroundOpacity] into the libVLC options the
/// engine honours — but the only screen that ever wrote those four fields left
/// with the media_kit player, so every user has been pinned to the defaults.
/// The outline, the lift, bold, the font, the text opacity and the encoding
/// joined them with the player's Subtitle style page, which edits the same
/// settings while a video plays.
///
/// The preview is built from `subtitleStyleFrom` rather than from the raw
/// settings, so it cannot drift from what the engine is told. It reproduces
/// VLC's own sizing rule: the rendered glyph height is the video height divided
/// by the relative font size, which is why a *smaller* number means *bigger*
/// text and why the preview scales with the screen instead of with the slider.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import '../../../../shared/widgets/custom_widgets.dart';
import '../../../player/domain/subtitle_code_pages.dart';
import '../../../player/domain/subtitle_style.dart';
import '../player_settings_provider.dart';
import 'settings_widgets.dart';

/// The caption colours worth offering, in the order broadcast captioning has
/// used them for decades: white first, then the high-contrast pair that stays
/// legible over bright scenes.
///
/// Bare ARGB rather than a name-keyed map: the names are translated, and a
/// translated key is not a stable identity for a stored colour.
/// [subtitleColorLabel] is the one place that names them.
const List<int> kSubtitleTextColors = <int>[
  0xFFFFFFFF,
  0xFFFFEB3B,
  0xFF4DD0E1,
  0xFF81C784,
  0xFFE040FB,
  0xFFEF5350,
  0xFF000000,
];

/// Box colours. The *alpha* of the stored value is never used —
/// `subtitleStyleFrom` replaces it with [PlayerSettings.subtitleBackgroundOpacity]
/// — so these are opaque and the opacity slider owns transparency outright.
const List<int> kSubtitleBackgroundColors = <int>[
  0xFF000000,
  0xFF303030,
  0xFFFFFFFF,
];

/// Name of [argb] if it is one of the offered colours, otherwise its hex.
///
/// A value can be off-list: older installs stored whatever the deleted dialog
/// wrote, and a settings row that says nothing at all is worse than one that
/// says `#FF8800`.
String subtitleColorLabel(AppLocalizations l10n, int argb) => switch (argb) {
  0xFFFFFFFF => l10n.colorWhite,
  0xFFFFEB3B => l10n.colorYellow,
  0xFF4DD0E1 => l10n.colorCyan,
  0xFF81C784 => l10n.colorGreen,
  0xFFE040FB => l10n.colorMagenta,
  0xFFEF5350 => l10n.colorRed,
  0xFF000000 => l10n.colorBlack,
  0xFF303030 => l10n.colorDarkGrey,
  _ => '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
};

/// The offered box colour with the red, green and blue of [argb], or [argb]
/// itself when none has them.
///
/// The box's stored alpha is never drawn - the opacity is - so a fresh
/// install's transparent black is the Black box.
int subtitleBackgroundColorOf(int argb) {
  for (final offered in kSubtitleBackgroundColors) {
    if ((offered & 0xFFFFFF) == (argb & 0xFFFFFF)) return offered;
  }
  return argb;
}

/// Every encoding the player offers: Auto, then each code page there is a
/// table for, in code page order.
final List<String> kSubtitleEncodings = <String>['', ...subtitleCodePages.keys];

String subtitleOutlineLabel(AppLocalizations l10n, SubtitleOutline outline) =>
    switch (outline) {
      SubtitleOutline.none => l10n.subtitleOutlineNone,
      SubtitleOutline.thin => l10n.subtitleOutlineThin,
      SubtitleOutline.normal => l10n.subtitleOutlineNormal,
      SubtitleOutline.thick => l10n.subtitleOutlineThick,
    };

/// Bottom for no lift, and the lift as a share of the picture otherwise.
String subtitlePositionLabel(AppLocalizations l10n, double raise) {
  final percent = (raise * 100).round();
  return percent == 0
      ? l10n.subtitlePositionBottom
      : l10n.subtitlePositionRaised(percent);
}

String subtitleFontLabel(AppLocalizations l10n, SubtitleFont font) =>
    switch (font) {
      SubtitleFont.standard => l10n.subtitleFontDefault,
      SubtitleFont.serif => l10n.subtitleFontSerif,
      SubtitleFont.monospace => l10n.subtitleFontMonospace,
    };

String subtitleOpacityLabel(AppLocalizations l10n, double opacity) =>
    l10n.subtitlePercent((opacity * 100).round());

/// A code page by the languages it is for, which is how people know them;
/// its own name for one this build does not offer.
String subtitleEncodingLabel(AppLocalizations l10n, String encoding) =>
    switch (encoding) {
      '' => l10n.subtitleEncodingAuto,
      'Windows-1250' => l10n.subtitleEncodingCentralEuropean,
      'Windows-1251' => l10n.subtitleEncodingCyrillic,
      'Windows-1252' => l10n.subtitleEncodingWestern,
      'Windows-1253' => l10n.subtitleEncodingGreek,
      'Windows-1254' => l10n.subtitleEncodingTurkish,
      'Windows-1255' => l10n.subtitleEncodingHebrew,
      'Windows-1256' => l10n.subtitleEncodingArabic,
      'Windows-1257' => l10n.subtitleEncodingBaltic,
      'Windows-1258' => l10n.subtitleEncodingVietnamese,
      _ => encoding,
    };

/// One-line summary of the background box.
///
/// Zero opacity is the only way to get no box at all — `subtitleStyleFrom`
/// drops the background when the resulting alpha is zero — so it is spelled
/// out as "Off" rather than as "0%".
String subtitleBackgroundLabel(AppLocalizations l10n, PlayerSettings settings) {
  final percent = (settings.subtitleBackgroundOpacity.clamp(0.0, 1.0) * 100)
      .round();
  if (percent == 0) return l10n.off;
  return l10n.subtitleBackgroundSummary(
    subtitleColorLabel(
      l10n,
      subtitleBackgroundColorOf(settings.subtitleBackgroundColor),
    ),
    percent,
  );
}

/// The one of [choices] closest to [value], so a stored value between them -
/// from a build that offered other steps - still has a place in the list.
double nearestSubtitleChoice(List<double> choices, double value) =>
    choices.reduce(
      (best, choice) =>
          (choice - value).abs() < (best - value).abs() ? choice : best,
    );

/// Subtitle appearance rows, styled like every other section on the screen.
class SubtitleAppearanceGroup extends ConsumerWidget {
  const SubtitleAppearanceGroup({required this.settings, super.key});

  final PlayerSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    return SettingsGroup(
      title: l10n.subtitleSettings,
      children: [
        // Not a SettingsTile: there is nothing to activate here, and a
        // focusable row that does nothing is a D-pad dead end.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: SubtitlePreview(
            settings: settings,
            sample: l10n.subtitlePreviewSample,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            l10n.subtitleAppearanceNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SettingsTile(
          icon: Icons.format_size_rounded,
          title: l10n.textSize,
          subtitle: '${settings.subtitleSize.round()}',
          onTap: () => showSubtitleSizeDialog(context, ref, settings),
        ),
        SettingsTile(
          icon: Icons.palette_outlined,
          title: l10n.subtitleTextColour,
          subtitle: subtitleColorLabel(l10n, settings.subtitleColor),
          trailing: _Swatch(color: Color(settings.subtitleColor)),
          onTap: () => showSubtitleColorDialog(context, ref, settings),
        ),
        SettingsTile(
          icon: Icons.format_color_fill_rounded,
          title: l10n.background,
          subtitle: subtitleBackgroundLabel(l10n, settings),
          onTap: () => showSubtitleBackgroundDialog(context, ref, settings),
        ),
        SettingsTile(
          icon: Icons.border_style_rounded,
          title: l10n.subtitleOutline,
          subtitle: subtitleOutlineLabel(l10n, settings.subtitleOutline),
          onTap: () => _showChoiceDialog<SubtitleOutline>(
            context,
            title: l10n.subtitleOutline,
            choices: SubtitleOutline.values,
            current: settings.subtitleOutline,
            name: (outline) => subtitleOutlineLabel(l10n, outline),
            choose: _notifier(ref).setSubtitleOutline,
          ),
        ),
        SettingsTile(
          icon: Icons.vertical_align_bottom_rounded,
          title: l10n.subtitlePosition,
          subtitle: subtitlePositionLabel(l10n, settings.subtitleRaise),
          onTap: () => _showChoiceDialog<double>(
            context,
            title: l10n.subtitlePosition,
            choices: kSubtitleRaises,
            current: nearestSubtitleChoice(
              kSubtitleRaises,
              settings.subtitleRaise,
            ),
            name: (raise) => subtitlePositionLabel(l10n, raise),
            choose: _notifier(ref).setSubtitleRaise,
          ),
        ),
        // libVLC takes these four only when a player is created, so they are
        // set apart, under the same note the player's Subtitle style page
        // gives them.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            l10n.subtitleNextTimeNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SettingsTile(
          icon: Icons.format_bold_rounded,
          title: l10n.subtitleBold,
          subtitle: settings.subtitleBold ? l10n.on : l10n.off,
          onTap: () => _showChoiceDialog<bool>(
            context,
            title: l10n.subtitleBold,
            choices: const <bool>[false, true],
            current: settings.subtitleBold,
            name: (bold) => bold ? l10n.on : l10n.off,
            choose: _notifier(ref).setSubtitleBold,
          ),
        ),
        SettingsTile(
          icon: Icons.font_download_outlined,
          title: l10n.subtitleFont,
          subtitle: subtitleFontLabel(l10n, settings.subtitleFont),
          onTap: () => _showChoiceDialog<SubtitleFont>(
            context,
            title: l10n.subtitleFont,
            choices: SubtitleFont.values,
            current: settings.subtitleFont,
            name: (font) => subtitleFontLabel(l10n, font),
            choose: _notifier(ref).setSubtitleFont,
          ),
        ),
        SettingsTile(
          icon: Icons.opacity_rounded,
          title: l10n.subtitleTextOpacity,
          subtitle: subtitleOpacityLabel(l10n, settings.subtitleTextOpacity),
          onTap: () => _showChoiceDialog<double>(
            context,
            title: l10n.subtitleTextOpacity,
            choices: kSubtitleTextOpacities,
            current: nearestSubtitleChoice(
              kSubtitleTextOpacities,
              settings.subtitleTextOpacity,
            ),
            name: (opacity) => subtitleOpacityLabel(l10n, opacity),
            choose: _notifier(ref).setSubtitleTextOpacity,
          ),
        ),
        SettingsTile(
          icon: Icons.translate_rounded,
          title: l10n.subtitleEncoding,
          subtitle: subtitleEncodingLabel(l10n, settings.subtitleEncoding),
          onTap: () => _showChoiceDialog<String>(
            context,
            title: l10n.subtitleEncoding,
            choices: kSubtitleEncodings,
            current: settings.subtitleEncoding,
            name: (encoding) => subtitleEncodingLabel(l10n, encoding),
            choose: _notifier(ref).setSubtitleEncoding,
          ),
        ),
        SettingsTile(
          icon: Icons.restart_alt_rounded,
          title: l10n.resetSubtitleAppearance,
          subtitle: l10n.resetSubtitleAppearanceSubtitle,
          isLast: true,
          onTap: () =>
              ref.read(playerSettingsProvider.notifier).resetSubtitleSettings(),
        ),
      ],
    );
  }
}

PlayerSettingsNotifier _notifier(WidgetRef ref) =>
    ref.read(playerSettingsProvider.notifier);

/// One of [choices], applied on selection like the other option lists here.
///
/// The choice in force is focused and on screen as the list opens, so a
/// remote starts on it rather than outside the dialog or below its edge.
void _showChoiceDialog<T>(
  BuildContext context, {
  required String title,
  required List<T> choices,
  required T current,
  required String Function(T value) name,
  required Future<void> Function(T value) choose,
}) {
  showDialog<void>(
    context: context,
    builder: (ctx) {
      void pick(T value) {
        unawaited(choose(value));
        Navigator.pop<void>(ctx);
      }

      return AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: Text(title),
        content: RadioGroup<T>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) pick(value);
          },
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final choice in choices)
                  currentOption(
                    isCurrent: choice == current,
                    child: ListTile(
                      autofocus: choice == current,
                      leading: Radio<T>(value: choice),
                      title: Text(name(choice)),
                      onTap: () => pick(choice),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// A sample caption drawn the way the player will draw it: libVLC for a
/// track inside the video, SkyStream itself for a subtitle file - both at
/// [subtitleFontSize].
class SubtitlePreview extends StatelessWidget {
  const SubtitlePreview({
    required this.settings,
    required this.sample,
    super.key,
  });

  final PlayerSettings settings;

  /// Supplied rather than defaulted, so the phrase is the caller's translated
  /// one. A preview whose sample is in the wrong script says nothing useful
  /// about how the reader's own subtitles will look.
  final String sample;

  @override
  Widget build(BuildContext context) {
    final style = subtitleStyleFrom(settings);
    final fontSize = subtitleFontSize(settings, MediaQuery.sizeOf(context));
    final outline = subtitleOutlineWidth(settings.subtitleOutline);
    final weight = settings.subtitleBold ? FontWeight.w800 : FontWeight.w600;
    // Tracks the text so the preview reads as a frame rather than a label,
    // and stops growing before it takes over the screen it is describing.
    final height = (fontSize * 1.9 + 24).clamp(72.0, 160.0);

    return Container(
      height: height,
      alignment: Alignment.bottomCenter,
      // The lift as the player draws it: a share of the frame, the preview
      // standing in for the picture.
      padding: EdgeInsets.fromLTRB(
        8,
        8,
        8,
        8 + settings.subtitleRaise.clamp(0.0, 0.5) * height,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFF37474F), Color(0xFF11171A)],
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        color: style.backgroundColor,
        child: Stack(
          children: [
            // VLC outlines the glyphs; a plain Text cannot, so the stroke is a
            // second copy underneath. Without it white-on-bright is the exact
            // illegibility the outline exists to prevent.
            if (outline > 0)
              Text(
                sample,
                maxLines: 1,
                style: TextStyle(
                  fontSize: fontSize,
                  fontFamily: style.fontFamily,
                  fontWeight: weight,
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = outline
                    ..color = style.outlineColor ?? const Color(0xFF000000),
                ),
              ),
            Text(
              sample,
              maxLines: 1,
              style: TextStyle(
                fontSize: fontSize,
                fontFamily: style.fontFamily,
                fontWeight: weight,
                color: style.color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Text size, previewed while it is dragged.
void showSubtitleSizeDialog(
  BuildContext context,
  WidgetRef ref,
  PlayerSettings settings,
) {
  final l10n = AppLocalizations.of(context)!;
  var size = settings.subtitleSize;

  showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: Text(l10n.textSize),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SubtitlePreview(
              settings: settings.copyWith(subtitleSize: size),
              sample: l10n.subtitlePreviewSample,
            ),
            const SizedBox(height: 12),
            Text(l10n.size(size.round())),
            CustomSlider(
              value: size,
              min: 10,
              max: 80,
              divisions: 70,
              onChanged: (value) => setState(() => size = value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop<void>(ctx),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              ref
                  .read(playerSettingsProvider.notifier)
                  .setSubtitleSettings(
                    size,
                    settings.subtitleColor,
                    settings.subtitleBackgroundColor,
                    settings.subtitleBackgroundOpacity,
                  );
              Navigator.pop<void>(ctx);
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    ),
  );
}

/// Text colour. Applied on selection, like the other option lists here.
void showSubtitleColorDialog(
  BuildContext context,
  WidgetRef ref,
  PlayerSettings settings,
) {
  final l10n = AppLocalizations.of(context)!;
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(l10n.subtitleTextColour),
      content: RadioGroup<int>(
        groupValue: settings.subtitleColor,
        onChanged: (value) {
          if (value == null) return;
          ref
              .read(playerSettingsProvider.notifier)
              .setSubtitleSettings(
                settings.subtitleSize,
                value,
                settings.subtitleBackgroundColor,
                settings.subtitleBackgroundOpacity,
              );
          Navigator.pop<void>(ctx);
        },
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final argb in kSubtitleTextColors)
                ListTile(
                  leading: Radio<int>(value: argb),
                  title: Text(subtitleColorLabel(l10n, argb)),
                  trailing: _Swatch(color: Color(argb)),
                  onTap: () {
                    ref
                        .read(playerSettingsProvider.notifier)
                        .setSubtitleSettings(
                          settings.subtitleSize,
                          argb,
                          settings.subtitleBackgroundColor,
                          settings.subtitleBackgroundOpacity,
                        );
                    Navigator.pop<void>(ctx);
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Background colour and opacity together, because neither means anything on
/// its own: zero opacity is what "no box" is, whatever the colour says.
void showSubtitleBackgroundDialog(
  BuildContext context,
  WidgetRef ref,
  PlayerSettings settings,
) {
  final l10n = AppLocalizations.of(context)!;
  var color = settings.subtitleBackgroundColor;
  var opacity = settings.subtitleBackgroundOpacity.clamp(0.0, 1.0);

  showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final preview = settings.copyWith(
          subtitleBackgroundColor: color,
          subtitleBackgroundOpacity: opacity,
        );
        return AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(l10n.background),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SubtitlePreview(
                  settings: preview,
                  sample: l10n.subtitlePreviewSample,
                ),
                const SizedBox(height: 12),
                RadioGroup<int>(
                  groupValue: color,
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      color = value;
                      // Picking a colour while the box is off obviously means
                      // "switch it on", so give it something to show.
                      if (opacity == 0) opacity = 0.5;
                    });
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final argb in kSubtitleBackgroundColors)
                        ListTile(
                          dense: true,
                          leading: Radio<int>(value: argb),
                          title: Text(subtitleColorLabel(l10n, argb)),
                          trailing: _Swatch(color: Color(argb)),
                          onTap: () => setState(() {
                            color = argb;
                            if (opacity == 0) opacity = 0.5;
                          }),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  opacity == 0
                      ? l10n.opacityOff
                      : l10n.opacityPercent((opacity * 100).round()),
                ),
                CustomSlider(
                  value: opacity,
                  max: 1,
                  divisions: 20,
                  step: 0.05,
                  onChanged: (value) => setState(() => opacity = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop<void>(ctx),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                ref
                    .read(playerSettingsProvider.notifier)
                    .setSubtitleSettings(
                      settings.subtitleSize,
                      settings.subtitleColor,
                      color,
                      opacity,
                    );
                Navigator.pop<void>(ctx);
              },
              child: Text(l10n.save),
            ),
          ],
        );
      },
    ),
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
    );
  }
}
