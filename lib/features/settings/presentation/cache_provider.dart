import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/storage/settings_repository.dart';

part 'cache_provider.g.dart';

@riverpod
Future<int> cacheSize(Ref ref) {
  return ref.watch(settingsRepositoryProvider).computeImageVideoCacheBytes();
}
