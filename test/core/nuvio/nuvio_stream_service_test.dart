import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/nuvio/data/nuvio_repository.dart';
import 'package:skystream/core/nuvio/data/nuvio_runtime.dart';
import 'package:skystream/core/nuvio/data/nuvio_stream_service.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';

class _Repo extends NuvioRepository {
  @override
  NuvioState build() => NuvioState(
    isLoading: false,
    repos: [
      NuvioRepo(
        manifestUrl: 'https://repo.test/manifest.json',
        addedAt: DateTime(2026),
        manifest: const NuvioManifest(
          name: 'Repo',
          version: '1',
          scrapers: [
            NuvioScraperInfo(
              id: 'a',
              name: 'A',
              version: '1',
              filename: 'a.js',
            ),
            NuvioScraperInfo(
              id: 'b',
              name: 'B',
              version: '1',
              filename: 'b.js',
            ),
          ],
        ),
      ),
    ],
  );

  @override
  Future<String> codeFor(NuvioRepo repo, NuvioScraperInfo scraper) async =>
      'code';
}

/// Notes each scraper run instead of running it.
class _Runtime extends NuvioRuntime {
  _Runtime() : super(() => '');

  final runs = <({String id, String source, bool personWaiting})>[];

  @override
  Future<List<NuvioStreamResult>> run({
    required String code,
    required String scraperId,
    required String scraperName,
    required String tmdbId,
    required String mediaType,
    int? season,
    int? episode,
    Map<String, dynamic> settings = const {},
    Duration timeout = NuvioRuntime.defaultTimeout,
    String source = '',
    bool personWaiting = false,
  }) async {
    runs.add((id: scraperId, source: source, personWaiting: personWaiting));
    return const [];
  }
}

void main() {
  test('scrapers run with their check source and person; some run again past the cache', () async {
    final runtime = _Runtime();
    final container = ProviderContainer(
      overrides: [
        nuvioRepositoryProvider.overrideWith(_Repo.new),
        nuvioRuntimeProvider.overrideWithValue(runtime),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(nuvioStreamServiceProvider);

    await service
        .resolve(tmdbId: '603', mediaType: 'movie', personWaiting: true)
        .last;
    expect({for (final r in runtime.runs) r.id}, {'a', 'b'});
    expect({for (final r in runtime.runs) r.source}, {'nuvio:a', 'nuvio:b'});
    expect(runtime.runs.every((r) => r.personWaiting), isTrue);

    // A check B met cleared: B alone runs again, its cached answer skipped.
    await service
        .resolve(tmdbId: '603', mediaType: 'movie', only: {'b'}, fresh: true)
        .last;
    expect(runtime.runs, hasLength(3));
    expect(runtime.runs.last.id, 'b');

    // Without fresh, the cache answers.
    await service.resolve(tmdbId: '603', mediaType: 'movie', only: {'b'}).last;
    expect(runtime.runs, hasLength(3));
  });
}
