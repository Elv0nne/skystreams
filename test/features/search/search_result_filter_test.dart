import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';

/// An extension that answers every search with [titles], in their order.
class _Plugin extends SkyStreamProvider {
  _Plugin(this.titles);

  final List<String> titles;

  /// The queries it was asked.
  final queries = <String>[];

  @override
  String get packageName => 'ext';
  @override
  String get name => 'Ext';
  @override
  String get mainUrl => 'https://ext.example';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.movie};

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    queries.add(query);
    return [
      for (final title in titles)
        MultimediaItem(title: title, url: '/$title', posterUrl: ''),
    ];
  }

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

class _Manager extends ExtensionManager {
  _Manager(this.plugin);

  final SkyStreamProvider plugin;

  @override
  List<SkyStreamProvider> build() => [plugin];
}

/// The titles search shows for [query] when [plugin] is the one extension.
Future<List<String>> _shown(_Plugin plugin, String query) async {
  final container = ProviderContainer(
    overrides: [
      extensionManagerProvider.overrideWith(() => _Manager(plugin)),
      searchQueryProvider.overrideWithValue(query),
    ],
  );
  addTearDown(container.dispose);
  final states = <SearchAggregateState>[];
  container.listen(searchResultsProvider, (_, next) {
    if (next.hasValue) states.add(next.value!);
  }, fireImmediately: true);
  await _until(() => states.isNotEmpty && !states.last.isLoading);
  return [
    for (final section in states.last.results)
      for (final item in section.results) item.title,
  ];
}

/// How search filters what an extension answers: the titles that have the
/// query's words, in the extension's order; or, when the extension answered
/// in other scripts only, everything it answered.
void main() {
  test('keeps a title with Arabic vowel marks and an article for the bare '
      'word', () async {
    final plugin = _Plugin(['رِحْلَةُ البَحْرِ', 'الطريق إلى المدرسة']);
    expect(await _shown(plugin, 'بحر'), ['رِحْلَةُ البَحْرِ']);
  });

  test('finds a query inside an unspaced Japanese title', () async {
    final plugin = _Plugin(['君の名は', '千と千尋の神隠し']);
    expect(await _shown(plugin, 'の名'), ['君の名は']);
  });

  test('finds a Traditional Chinese title by a Simplified query', () async {
    final plugin = _Plugin(['慶餘年 第二季', '甄嬛傳', '流浪地球']);
    expect(await _shown(plugin, '庆余年'), ['慶餘年 第二季']);
  });

  test('and a Simplified one by a Traditional query', () async {
    final plugin = _Plugin(['甄嬛传', '庆余年', '流浪地球']);
    expect(await _shown(plugin, '甄嬛傳'), ['甄嬛传']);
  });

  test('also when a Traditional character is Simplified too', () async {
    final plugin = _Plugin(['復仇者聯盟：終局之戰', '流浪地球']);
    expect(await _shown(plugin, '复仇者联盟'), ['復仇者聯盟：終局之戰']);
  });

  test('finds a title with a Turkish dotted İ by a plain i', () async {
    final plugin = _Plugin(['İstanbul Hatırası', 'Ankara']);
    expect(await _shown(plugin, 'istanbul'), ['İstanbul Hatırası']);
  });

  test('matches across punctuation, case and repeated spaces', () async {
    final plugin = _Plugin(['Spider-Man: Homecoming', 'Batman']);
    expect(await _shown(plugin, '  SPIDER   man '), ['Spider-Man: Homecoming']);
  });

  test(
    'keeps the extension\'s order and drops titles without the query',
    () async {
      final plugin = _Plugin([
        'بحر الرمال',
        'An unrelated recommendation',
        'أسرار البحر',
      ]);
      expect(await _shown(plugin, 'بحر'), ['بحر الرمال', 'أسرار البحر']);
    },
  );

  test('keeps a whole answer in other scripts than the query\'s, in the '
      'extension\'s order (issue #36)', () async {
    final plugin = _Plugin(['The Sea Will Overflow', 'Tasacak Bu Deniz']);
    expect(await _shown(plugin, 'هذا البحر سوف يفيض'), [
      'The Sea Will Overflow',
      'Tasacak Bu Deniz',
    ]);
  });

  test('still filters an answer with a title in the query\'s script', () async {
    final plugin = _Plugin([
      'Tasacak Bu Deniz',
      'مسلسل هذا البحر سوف يفيض الحلقة 1',
      'مسلسل الحفرة',
    ]);
    expect(await _shown(plugin, 'هذا البحر سوف يفيض'), [
      'مسلسل هذا البحر سوف يفيض الحلقة 1',
    ]);
  });

  test('a long answer, filtered off the main isolate, follows the same '
      'rules', () async {
    // 30 results or more are filtered in a background isolate.
    final latin = [for (var i = 1; i <= 40; i++) 'Tasacak Bu Deniz $i'];
    expect(await _shown(_Plugin(latin), 'هذا البحر سوف يفيض'), latin);

    final mixed = [
      for (var i = 1; i <= 20; i++) ...['مسلسل الحفرة $i', 'Çukur $i'],
    ];
    expect(await _shown(_Plugin(mixed), 'الحفره'), [
      for (var i = 1; i <= 20; i++) 'مسلسل الحفرة $i',
    ]);
  });

  test('an answer with no letter in it shows nothing for a query with '
      'letters', () async {
    // A broken extension's blank titles or bare years have none of the
    // query's words, and are in no other script either.
    expect(await _shown(_Plugin(['', '', '']), 'batman'), isEmpty);
    expect(await _shown(_Plugin(['1917', '2012']), 'batman'), isEmpty);
  });

  test('an empty answer shows nothing', () async {
    expect(await _shown(_Plugin([]), 'بحر'), isEmpty);
  });

  test('a blank query asks no extension', () async {
    final plugin = _Plugin(['Dune']);
    expect(await _shown(plugin, '  \t  '), isEmpty);
    expect(plugin.queries, isEmpty);
  });
}

/// Waits, a few milliseconds at a time, until [done].
Future<void> _until(bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
