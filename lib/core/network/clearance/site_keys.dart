import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

/// The site a host belongs to: its registrable domain under the Public Suffix
/// List (`a.pages.dev` and `b.pages.dev` are two sites, `www.example.co.uk`
/// and `cdn.example.co.uk` one).
///
/// A Cloudflare clearance holds for one site, every subdomain included, so the
/// clearance store keys its entries by site.
class SiteKeys {
  SiteKeys._(this._rules, this._wildcards, this._exceptions);

  /// The list as bundled with the app (MPL-2.0, publicsuffix.org).
  static const asset = 'assets/clearance/public_suffix_list.dat';

  static Future<SiteKeys> load() async =>
      SiteKeys.parse(await rootBundle.loadString(asset));

  /// Parses the list's text: one rule per line, `//` comments, `*.` wildcards
  /// and `!` exceptions.
  factory SiteKeys.parse(String list) {
    final rules = <String>{};
    final wildcards = <String>{};
    final exceptions = <String>{};
    for (final raw in list.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('//')) continue;
      final rule = line.split(RegExp(r'\s')).first.toLowerCase();
      if (rule.startsWith('!')) {
        exceptions.add(rule.substring(1));
      } else if (rule.startsWith('*.')) {
        wildcards.add(rule.substring(2));
      } else {
        rules.add(rule);
      }
    }
    return SiteKeys._(rules, wildcards, exceptions);
  }

  final Set<String> _rules;

  /// Suffixes under which every single label is itself a public suffix
  /// (`*.ck`), stored without the `*.`.
  final Set<String> _wildcards;
  final Set<String> _exceptions;

  /// The site for [host]. IP addresses, `localhost` and hosts that are
  /// themselves a public suffix are their own site.
  String siteOf(String host) {
    var name = host.toLowerCase();
    if (name.endsWith('.')) name = name.substring(0, name.length - 1);
    if (name.isEmpty || InternetAddress.tryParse(name) != null) return name;
    final labels = name.split('.');
    if (labels.length < 2) return name;
    final suffix = _publicSuffixLength(labels);
    if (suffix >= labels.length) return name;
    return labels.sublist(labels.length - suffix - 1).join('.');
  }

  /// How many trailing labels of [labels] form the public suffix.
  int _publicSuffixLength(List<String> labels) {
    var longest = 1; // The default rule, `*`: the last label.
    for (var i = labels.length - 1; i >= 0; i--) {
      final candidate = labels.sublist(i).join('.');
      final count = labels.length - i;
      if (_exceptions.contains(candidate)) return count - 1;
      if (_rules.contains(candidate) && count > longest) longest = count;
      if (i > 0) {
        final parent = labels.sublist(i).join('.');
        if (_wildcards.contains(parent) && count + 1 > longest) {
          // `*.parent` covers the label before it.
          if (!_exceptions.contains(labels.sublist(i - 1).join('.'))) {
            longest = count + 1;
          }
        }
      }
    }
    return longest;
  }
}
