import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/clearance/widget_tap.dart';

void main() {
  group('tapPoint', () {
    test('taps 25 px in from the left, at mid-height', () {
      final at = tapPoint(const WidgetBox(56, 304, 912, 68));
      expect((at.x, at.y), (81.0, 338.0));
    });

    test('taps 25 px in from the right for a right-to-left widget', () {
      final at = tapPoint(const WidgetBox(56, 304, 912, 68, rtl: true));
      expect((at.x, at.y), (943.0, 338.0));
    });
  });

  group('fixedWidgetBox', () {
    test("tries the language's row twice, then the other", () {
      List<double> tops({required bool raisedFirst}) => [
        for (var attempt = 0; attempt < 3; attempt++)
          fixedWidgetBox(
            rtl: true,
            raisedFirst: raisedFirst,
            attempt: attempt,
          ).top,
      ];
      expect(tops(raisedFirst: false), [304.0, 304.0, 280.0]);
      expect(tops(raisedFirst: true), [280.0, 280.0, 304.0]);
    });

    test('the raised row is where Arabic, Hebrew and Chinese put it', () {
      // Their check pages take a line less above the widget (measured 2026-10-05).
      for (final raised in [
        'ar_EG',
        'he-IL',
        'iw',
        'zh_CN',
        'zh-TW',
        'zh_Hant_TW',
        'zh',
      ]) {
        expect(widgetRaisedIn(raised), isTrue, reason: raised);
      }
      for (final other in [
        'en_US',
        'fa_IR',
        'ur_PK',
        'hi_IN',
        'de_DE',
        'ja_JP',
        'ko_KR',
        'ru_RU',
      ]) {
        expect(widgetRaisedIn(other), isFalse, reason: other);
      }
    });

    test("is where Cloudflare's interstitial puts its widget in a 1024 px viewport", () {
      final box = fixedWidgetBox(rtl: false);
      expect(
        (box.left, box.top, box.width, box.height),
        (56.0, 304.0, 912.0, 68.0),
      );
      expect(box.rtl, isFalse);
      expect(box.answered, isFalse);
      expect(fixedWidgetBox(rtl: true).rtl, isTrue);
    });
  });

  group('WidgetBox.fromJson', () {
    test("reads the isolated script's answer", () {
      final box = WidgetBox.fromJson(
        jsonDecode('[56.5, 304, 912, 68, true, false]'),
      )!;
      expect(
        (box.left, box.top, box.width, box.height),
        (56.5, 304.0, 912.0, 68.0),
      );
      expect(box.rtl, isTrue);
      expect(box.answered, isFalse);
    });

    test('a filled token field is answered', () {
      expect(
        WidgetBox.fromJson(jsonDecode('[56, 304, 912, 68, false, true]'))!
            .answered,
        isTrue,
      );
    });

    test('no widget, or an answer it can\'t read, is null', () {
      expect(WidgetBox.fromJson(null), isNull);
      expect(WidgetBox.fromJson(jsonDecode('[1, 2]')), isNull);
      expect(WidgetBox.fromJson(jsonDecode('{"left": 1}')), isNull);
      expect(
        WidgetBox.fromJson(jsonDecode('["a", 2, 3, 4, false, false]')),
        isNull,
      );
    });
  });

  test("the isolated script looks the widget up from its response field, never past four ancestors", () {
    expect(widgetBoxScript, contains('input[name="cf-turnstile-response"]'));
    expect(widgetBoxScript, contains('d < 4'));
  });

  test("the widget's direction comes from its language, not the page's", () {
    // Turnstile lays out in the browser's language unless the site sets one: on a left-to-right
    // page in an Arabic browser its checkbox is at the right (seen on a phone, 2026-10-04).
    expect(widgetBoxScript, contains('navigator.language'));
    expect(widgetBoxScript, contains("getAttribute('data-language')"));
    expect(widgetBoxScript, isNot(contains('direction')));
    // The right-to-left languages Cloudflare draws right to left: Urdu gets
    // its English page (measured 2026-10-04).
    expect(widgetBoxScript, contains('/^(ar|fa|he|iw)([-_]|\$)/i'));
  });

  test('widgetRtlIn: Arabic, Persian and Hebrew face right to left; Urdu, '
      'which Cloudflare serves in English, does not', () {
    for (final rtl in ['ar_EG', 'fa-IR', 'he_IL', 'iw']) {
      expect(widgetRtlIn(rtl), isTrue, reason: rtl);
    }
    for (final ltr in ['ur_PK', 'en_US', 'hi_IN', 'ps_AF', 'ckb']) {
      expect(widgetRtlIn(ltr), isFalse, reason: ltr);
    }
  });
}
