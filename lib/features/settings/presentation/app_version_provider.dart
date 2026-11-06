import 'package:flutter_riverpod/flutter_riverpod.dart' show FutureProvider;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_version_provider.g.dart';

@riverpod
Future<String> appVersion(Ref ref) => readAppVersion();

/// The app's version for providers kept alive for the app's lifetime, such as
/// the CloudStream repository, which records the version a plugin failed to
/// load under.
///
/// [appVersionProvider] is disposed when nothing watches it, and a kept-alive
/// provider reading one of those can see it disposed while the read is still
/// pending (riverpod_lint's `only_use_keep_alive_inside_keep_alive`). This one
/// is kept alive too.
final keptAppVersionProvider = FutureProvider<String>(
  (ref) => readAppVersion(),
);

/// The version and build number, as Settings shows them: `2.9.0 +42`.
Future<String> readAppVersion() async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version} +${info.buildNumber}';
}
