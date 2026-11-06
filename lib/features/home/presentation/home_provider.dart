import 'dart:async';
import 'dart:io';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../core/extensions/base_provider.dart';
import '../../../../core/network/clearance/clearance.dart';
import '../../../../core/network/clearance/site_checks.dart';

import './home_state.dart';

part 'home_provider.g.dart';

@riverpod
class HomeData extends _$HomeData {
  /// Retires superseded fetches. The notifier instance outlives a rebuild, so
  /// bumping this in [build] also cancels a fetch that is still in flight for
  /// the provider the user just switched away from — otherwise its late result
  /// lands on top of the grid the user is already looking at.
  int _fetchToken = 0;

  // ignore: riverpod_lint/avoid_public_notifier_properties
  /// When the current fetch began: the checks Home's plugin met since are
  /// Home's to show.
  ///
  /// Outside the state on purpose: Home's screen reads it once, as it builds
  /// the wait, and it moves with every fetch, so as state it would rebuild
  /// Home for a value nothing on screen shows.
  DateTime? fetchStartedAt;

  StreamSubscription<void>? _checks;

  @override
  HomeState build() {
    _fetchToken++;
    final activeProvider = ref.watch(activeProviderProvider);
    if (activeProvider == null) {
      return const HomeNoProvider();
    }
    _watchChecks(activeProvider);

    // Start initial fetch. The screen reads the start as it builds the wait,
    // before the fetch runs.
    fetchStartedAt = _now();
    Future.microtask(() => fetch());
    return const HomeLoading();
  }

  Future<void> fetch() async {
    final token = ++_fetchToken;
    fetchStartedAt = _now();
    state = const HomeLoading();

    final activeProvider = ref.read(activeProviderProvider);
    if (activeProvider == null) {
      state = const HomeNoProvider();
      return;
    }

    // No reachability probe runs ahead of this: the request is the only honest
    // signal, it reports its own failure a moment later, and a hardcoded public
    // resolver is simply unreachable on networks that block one.
    try {
      final items = await activeProvider.getHome();
      if (!_isCurrent(token)) return;
      // Nothing but empty rows while the site's check isn't cleared: the
      // plugin turned the failure into nothing. Home shows the check instead,
      // and fetches again once it clears.
      final check = _unclearedCheck(activeProvider);
      if (check != null && items.values.every((rows) => rows.isEmpty)) {
        state = HomeError('${check.site} needs a check');
        return;
      }
      state = HomeSuccess(items);
    } catch (e) {
      if (!_isCurrent(token)) return;
      // A dead network must still reach the localized offline page rather than
      // a raw exception string, which is all the probe used to buy us.
      state = _looksOffline(e) ? const HomeOffline() : HomeError(e.toString());
    }
  }

  DateTime _now() {
    final clearance = Clearance.instance;
    return clearance.isReady ? clearance.checks.now : DateTime.now();
  }

  /// The check [provider] met during this fetch, while it isn't cleared.
  SiteCheck? _unclearedCheck(SkyStreamProvider provider) {
    final clearance = Clearance.instance;
    final started = fetchStartedAt;
    if (!clearance.isReady || started == null) return null;
    final check = clearance.checks.latestFor(
      provider.checkSource,
      since: started,
    );
    return check == null || check.state == CheckState.cleared ? null : check;
  }

  /// Fetches again when the site Home's plugin waits on clears after the
  /// fetch gave up on it: Verify, or a kept page that cleared later.
  void _watchChecks(SkyStreamProvider provider) {
    unawaited(_checks?.cancel());
    final clearance = Clearance.instance;
    final source = provider.checkSource;
    if (!clearance.isReady || source == null) return;
    _checks = clearance.checks.changes.listen((_) {
      final started = fetchStartedAt;
      if (started == null || state is! HomeError) return;
      final check = clearance.checks.latestFor(source, since: started);
      if (check?.state == CheckState.cleared) unawaited(fetch());
    });
    ref.onDispose(() => unawaited(_checks?.cancel()));
  }

  /// False once this fetch has been superseded, or once the provider has been
  /// disposed — a post-dispose `state =` throws `UnmountedRefException` on
  /// Riverpod 3.
  bool _isCurrent(int token) => token == _fetchToken && ref.mounted;

  /// The scraper wraps its failures in a plain `Exception`, so the type is
  /// often gone by the time it reaches here; match on the text too.
  static bool _looksOffline(Object error) {
    if (error is SocketException ||
        error is HandshakeException ||
        error is TimeoutException) {
      return true;
    }
    final text = error.toString();
    return text.contains('SocketException') ||
        text.contains('HandshakeException') ||
        text.contains('TimeoutException') ||
        text.contains('Failed host lookup') ||
        text.contains('Network is unreachable') ||
        text.contains('Connection refused') ||
        text.contains('Connection reset') ||
        text.contains('Connection timed out') ||
        text.contains('connectionError');
  }
}

@riverpod
class HomeFilter extends _$HomeFilter {
  @override
  ProviderType? build() {
    final storage = ref.read(storageServiceProvider);
    final saved = storage.getHomeCategory();
    if (saved != null) {
      try {
        return ProviderType.values.firstWhere((e) => e.name == saved);
      } catch (_) {}
    }
    return null;
  }

  Future<void> setFilter(ProviderType? type) async {
    state = type;
    final storage = ref.read(storageServiceProvider);
    await storage.setHomeCategory(type?.name);
  }
}
