/// Runs one CloudStream extension as the extension survey did, for the device tests that go
/// through a group of them (own_webview_probe_test.dart, app_classes_test.dart).
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_provider.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/network/http_defaults.dart';

import 'resolver_group.dart' show ResolverExtension;

/// Installs [extension] and goes as far as its links, noting what happened
/// in [report].
Future<void> runExtension(
  ResolverExtension extension,
  Map<String, Object?> report,
  WidgetTester tester,
  ProviderContainer container,
  CloudStreamEngineHost host,
) async {
  // Not ensureInstalled: an install that fails inside its runAsync fails the
  // whole test, and some repositories list files that are gone.
  final notifier = container.read(cloudStreamRepositoryProvider.notifier);
  var installed = false;
  await tester.runAsync(() async {
    try {
      final repo = await notifier.addRepository(extension.repository);
      final listed = repo.plugins.firstWhere(
        (p) => p.internalName == extension.name,
      );
      // One that failed to load before is installed again: this engine may run it.
      final current = container
          .read(cloudStreamRepositoryProvider)
          .installedFor(listed);
      if (current == null || current.loadError != null) {
        await notifier.install(listed);
      }
      installed = true;
    } catch (e) {
      report['error'] = 'install: ${_short(e)}';
    }
  });
  if (!installed) return;
  final plugin = container
      .read(cloudStreamRepositoryProvider)
      .installed
      .where((p) => p.info.internalName == extension.name)
      .firstOrNull;
  if (plugin == null || plugin.providers.isEmpty) {
    report['error'] = 'not loaded';
    return;
  }
  final provider = CloudStreamProvider(
    plugin: plugin,
    pluginKey: CloudStreamRepository.keyOf(plugin.info),
    info: plugin.providers.first,
    host: host,
  );
  await tester.runAsync(() async {
    try {
      await () async {
        final query = extension.query;
        final found = query == null
            ? const <MultimediaItem>[]
            : await provider.search(query);
        report['results'] = found.length;
        // The survey's words were a title on that day's home page: the home
        // page now has today's.
        final candidates = [...found, ...await _home(provider)];
        for (final item in candidates.take(3)) {
          final MultimediaItem details;
          try {
            details = await provider.getDetails(item.url);
          } catch (_) {
            continue;
          }
          final episode = details.episodes?.firstOrNull;
          if (episode == null) continue;
          report['title'] = details.title;
          final streams = await provider.loadStreams(episode.url);
          report['links'] = streams.length;
          if (streams.isNotEmpty) report['probe'] = await _probe(streams.first);
          return;
        }
      }().timeout(const Duration(minutes: 4));
    } catch (e) {
      report['error'] = _short(e);
    }
  });
}

/// The titles of [provider]'s home page; none when it has none, or fails.
Future<List<MultimediaItem>> _home(CloudStreamProvider provider) async {
  try {
    return [for (final row in (await provider.getHome()).values) ...row];
  } catch (_) {
    return const [];
  }
}

/// What [stream]'s address answers when asked as the player asks it: with the link's own headers,
/// and the player's default agent when the link names none. A status code, or the error.
Future<String> _probe(StreamResult stream) async {
  final url = Uri.tryParse(stream.url);
  if (url == null || !url.isScheme('http') && !url.isScheme('https')) {
    return 'not http';
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client
        .getUrl(url)
        .timeout(const Duration(seconds: 15));
    final headers = {
      for (final e in (stream.headers ?? const <String, String>{}).entries)
        e.key.toLowerCase(): e.value,
    };
    request.headers.set(
      'user-agent',
      headers['user-agent'] ?? kDefaultBrowserUserAgent,
    );
    for (final e in headers.entries) {
      if (e.key != 'user-agent') request.headers.set(e.key, e.value);
    }
    request.headers.set('range', 'bytes=0-1023');
    final response = await request.close().timeout(const Duration(seconds: 15));
    await response.drain<void>();
    return '${response.statusCode}';
  } catch (e) {
    return 'error: ${_short(e)}';
  } finally {
    client.close(force: true);
  }
}

String _short(Object error) {
  final text = '$error'.replaceAll('\n', ' ');
  return text.length > 200 ? text.substring(0, 200) : text;
}
