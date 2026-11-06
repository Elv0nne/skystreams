import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_images.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';

/// Posters from a site behind a bot check. Cloudflare answers an image request
/// that carries no clearance with its check page, so the poster never shows:
/// on 2026-10-11 the posters plugins list for anime4up, cinehdplus,
/// french-anime and funmovieslix all came back as a 403 check page to a
/// request made as the image cache makes them. The clearance a plugin's own
/// request earned for the site goes with its images too, as it goes with the
/// player's stream requests.
void main() {
  final keys = SiteKeys.parse(
    File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
  );
  const agent = 'Mozilla/5.0 (the browser that solved the check)';
  const clearance = StoredCookie(
    name: 'cf_clearance',
    value: 'v1',
    domain: '.anime4up.rest',
    secure: true,
  );
  late DateTime time;
  late ClearanceStore store;
  late _Recording inner;
  late ClearanceImageFileService images;

  setUp(() {
    time = DateTime(2026, 10, 11, 12);
    store = ClearanceStore(clock: () => time);
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      solver: ClearanceSolver(store: store, siteKeys: keys),
    );
    inner = _Recording();
    images = ClearanceImageFileService(inner: inner);
  });

  Future<Map<String, String>?> sent(
    String url, [
    Map<String, String>? headers,
  ]) async {
    await images.get(url, headers: headers);
    return inner.headers;
  }

  void solve(List<StoredCookie> cookies) => store.recordSolve(
    'anime4up.rest',
    cookies: cookies,
    agent: agent,
    url: 'https://w1.anime4up.rest/',
  );

  test('an image from a cleared site carries its clearance', () async {
    solve([clearance]);
    expect(await sent('https://w1.anime4up.rest/wp-content/uploads/a.jpg'), {
      'Cookie': 'cf_clearance=v1',
      'User-Agent': agent,
    });
  });

  test('an image from another site carries nothing', () async {
    solve([clearance]);
    expect(await sent('https://cinehdplus.org/poster.jpg'), isEmpty);
    expect(await sent('https://image.tmdb.org/t/p/w500/a.jpg'), isEmpty);
  });

  test('only the cookies whose domain and path cover the image', () async {
    solve([
      clearance,
      const StoredCookie(name: 'host', value: 'h', domain: 'www.anime4up.rest'),
      const StoredCookie(
        name: 'account',
        value: 'a',
        domain: '.anime4up.rest',
        path: '/account',
      ),
    ]);
    expect(
      (await sent('https://w1.anime4up.rest/wp-content/a.jpg'))?['Cookie'],
      'cf_clearance=v1',
    );
  });

  test('the caller\'s headers go along, its cookies merged', () async {
    solve([clearance]);
    expect(
      await sent('https://w1.anime4up.rest/a.jpg', {
        'Accept': 'image/*',
        'cookie': 'own=1; cf_clearance=old',
      }),
      {
        'Accept': 'image/*',
        'Cookie': 'own=1; cf_clearance=v1',
        'User-Agent': agent,
      },
    );
  });

  // As the site's own requests: a clearance can hold longer than the store
  // counts it fresh, and while a plugin's search still gets through with it,
  // the posters it lists should too.
  test('an image carries the clearance for as long as the site\'s requests '
      'do', () async {
    solve([clearance]);
    time = time.add(const Duration(hours: 1));
    expect(
      (await sent('https://w1.anime4up.rest/a.jpg'))?['Cookie'],
      'cf_clearance=v1',
    );
  });

  // Its requests go through a page, but a plain one still carries the
  // clearance; an image may be let through where a search isn't.
  test('a site that answers only its own pages still gets it', () async {
    solve([clearance]);
    store.markBrowserOnly('anime4up.rest');
    expect(
      (await sent('https://w1.anime4up.rest/a.jpg'))?['Cookie'],
      'cf_clearance=v1',
    );
  });

  test('fetches as many images at once as the service it wraps', () {
    inner.concurrentFetches = 6;
    expect(images.concurrentFetches, 6);
    images.concurrentFetches = 4;
    expect(inner.concurrentFetches, 4);
  });

  test('the app\'s images use it, in the cache they always had, and can '
      'still be resized', () {
    final cache = ClearanceImageCacheManager.storedIn(
      NonStoringObjectProvider(),
      MemoryCacheSystem(),
    );
    // Not read first: the default builds a cache on the device's storage,
    // and each test file has an isolate of its own anyway.
    installClearanceImageCache(cache);

    expect(CachedNetworkImageProvider.defaultCacheManager, same(cache));
    expect(cache.config.cacheKey, DefaultCacheManager.key);
    expect(cache.config.fileService, isA<ClearanceImageFileService>());
    expect(cache, isA<ImageCacheManager>());
  });
}

/// A file service that records what it was asked and answers nothing.
class _Recording extends FileService {
  Map<String, String>? headers;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    this.headers = headers ?? const {};
    return _Empty();
  }
}

class _Empty implements FileServiceResponse {
  @override
  Stream<List<int>> get content => const Stream.empty();
  @override
  int? get contentLength => 0;
  @override
  int get statusCode => 200;
  @override
  DateTime get validTill => DateTime(2026);
  @override
  String? get eTag => null;
  @override
  String get fileExtension => '.jpg';
}
