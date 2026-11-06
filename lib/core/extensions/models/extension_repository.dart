import 'dart:convert';
import 'package:crypto/crypto.dart';

class ExtensionRepository {
  final String name;
  final String url;
  final String? description;
  final String? iconUrl;
  final int manifestVersion;
  final List<String> pluginLists;
  final List<String> includedRepos;
  final String? _explicitId;

  /// The short link a code entered as [url] was found at. A repository the
  /// user adds by its code is kept as this, so that only that code is looked
  /// up again - not the other spellings a typed code is tried in.
  final String? shortLink;

  ExtensionRepository({
    required this.name,
    required this.url,
    required this.pluginLists,
    this.includedRepos = const [],
    this.description,
    this.iconUrl,
    this.manifestVersion = 1,
    String? explicitId,
    this.shortLink,
  }) : _explicitId = explicitId;

  /// The Package Namespace.
  /// Returns explicit Package Name or falls back to Hash(Url).
  String get packageName =>
      _explicitId ??
      sha256.convert(utf8.encode(url)).toString().substring(0, 10);

  /// This repository, kept as [url]. Without an id of its own, its id
  /// follows its address.
  ExtensionRepository withUrl(String url) => ExtensionRepository(
    name: name,
    url: url,
    pluginLists: pluginLists,
    includedRepos: includedRepos,
    description: description,
    iconUrl: iconUrl,
    manifestVersion: manifestVersion,
    explicitId: _explicitId,
  );

  /// Factory constructor to parse from JSON
  factory ExtensionRepository.fromJson(
    Map<String, dynamic> json,
    String url, {
    String? shortLink,
  }) {
    return ExtensionRepository(
      name: json['name'] as String? ?? 'Unknown Repository',
      url: url,
      pluginLists:
          (json['pluginLists'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      includedRepos:
          (json['repos'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      description: json['description'] as String?,
      iconUrl: json['iconUrl'] as String?,
      manifestVersion: json['manifestVersion'] as int? ?? 1,
      explicitId: json['packageName'] as String?,
      shortLink: shortLink,
    );
  }
}
