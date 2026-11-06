import 'package:flutter/foundation.dart';

/// Where Cloudflare's Turnstile widget is on a page, in CSS pixels from the
/// page's top left: the box around its checkbox.
@immutable
class WidgetBox {
  const WidgetBox(
    this.left,
    this.top,
    this.width,
    this.height, {
    this.rtl = false,
    this.answered = false,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  /// The widget lays out right to left (Arabic, Hebrew, Persian…): its
  /// checkbox is at its right end.
  final bool rtl;

  /// Its token field is filled already: the check passed, and a tap would
  /// only disturb it.
  final bool answered;

  /// [widgetBoxScript]'s answer: `[left, top, width, height, rtl, answered]`,
  /// or null when there is no widget or the answer can't be read.
  static WidgetBox? fromJson(Object? json) {
    if (json is! List || json.length != 6) return null;
    final [left, top, width, height, rtl, answered] = json;
    if (left is! num || top is! num || width is! num || height is! num) {
      return null;
    }
    return WidgetBox(
      left.toDouble(),
      top.toDouble(),
      width.toDouble(),
      height.toDouble(),
      rtl: rtl == true,
      answered: answered == true,
    );
  }
}

/// Where a person would tap [box]'s checkbox: 25 px in from the widget's
/// start edge, at its middle.
({double x, double y}) tapPoint(WidgetBox box) => (
  x: box.rtl ? box.left + box.width - 25 : box.left + 25,
  y: box.top + box.height / 2,
);

/// Where Cloudflare's interstitial puts its widget in a hidden page, whose
/// viewport is 1024×768 CSS pixels on every device: for Android, where no
/// script may look the widget up while the check runs (it would loop).
///
/// Its row follows the text above it: y 304 in most languages, 24 px higher
/// where that text takes a line less (Arabic, Hebrew and Chinese, of 41
/// languages measured on 2026-10-04 and -05). The first two tries
/// ([attempt]) go to the language's row, the raised one when [raisedFirst]
/// ([widgetRaisedIn]) — some checks want a second tap — and the third to
/// the other.
///
/// Android's pages keep the device's language: its browser takes a language
/// only per request, and a language on the first request alone made
/// Cloudflare check again after every clearance (2026-10-05).
WidgetBox fixedWidgetBox({
  required bool rtl,
  bool raisedFirst = false,
  int attempt = 0,
}) => (attempt < 2) == raisedFirst
    ? WidgetBox(56, 280, 912, 69, rtl: rtl)
    : WidgetBox(56, 304, 912, 68, rtl: rtl);

/// Whether Cloudflare draws its widget right to left in [locale]'s language:
/// Arabic, Persian and Hebrew. Not every right-to-left language: Urdu gets
/// Cloudflare's English page (measured 2026-10-04).
bool widgetRtlIn(String locale) => const {
  'ar',
  'fa',
  'he',
  'iw',
}.contains(locale.split(RegExp('[-_]')).first.toLowerCase());

/// Whether Cloudflare's interstitial puts its widget on the raised row in
/// [locale]'s language ([fixedWidgetBox]): Arabic, Hebrew and Chinese
/// (Simplified and Traditional).
bool widgetRaisedIn(String locale) => const {
  'ar',
  'he',
  'iw',
  'zh',
}.contains(locale.split(RegExp('[-_]')).first.toLowerCase());

/// Finds Turnstile's widget from its response field: the nearest ancestor,
/// at most four up, sized like a widget. On a check page, run only in an
/// isolated world, where the check's own scripts can't see it look; an
/// ordinary page's widget doesn't notice a look from the page itself
/// (`solveCaptcha` on Android).
///
/// The widget faces the way of its own language, not the page's: Turnstile
/// uses the browser's unless the site sets one (`data-language`), so on a
/// left-to-right page in an Arabic browser its checkbox is at the right.
/// Right to left in the languages [widgetRtlIn] names.
const widgetBoxScript = '''
(function(){
  var inputs = document.querySelectorAll('input[name="cf-turnstile-response"]');
  for (var i = 0; i < inputs.length; i++) {
    var input = inputs[i], el = input, lang = '';
    for (var d = 0; d < 4 && el; d++) {
      el = el.parentElement;
      if (!el) break;
      lang = lang || el.getAttribute('data-language') || '';
      var r = el.getBoundingClientRect();
      if (r.width > 40 && r.height > 20 && r.height < 120) {
        if (!lang || lang === 'auto') lang = navigator.language || '';
        return [r.left, r.top, r.width, r.height,
          /^(ar|fa|he|iw)([-_]|\$)/i.test(lang),
          !!input.value];
      }
    }
  }
  return null;
})()''';
