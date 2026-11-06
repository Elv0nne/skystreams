import '../../l10n/generated/app_localizations.dart';

/// What the launch-time extension pass changed, and the toasts that say so.
///
/// Each extension system reports on its own - SkyStream plugins, Nuvio
/// scrapers, Stremio add-ons, CloudStream extensions - and the launch merges
/// the reports. However much happened, that is at most three toasts: the
/// toast stack holds four, and a fifth pushes the oldest off before anyone
/// has read it.
class ExtensionUpdateReport {
  const ExtensionUpdateReport({
    this.updated = const <String>[],
    this.newRepositories = const <String, List<String>>{},
    this.newPlugins = const <String, List<String>>{},
  });

  /// Several reports as one, in the order given. Entries filed under the same
  /// name - two systems that each have a repository called "Stars" - are
  /// pooled.
  factory ExtensionUpdateReport.merge(Iterable<ExtensionUpdateReport> reports) {
    final updated = <String>[];
    final newRepositories = <String, List<String>>{};
    final newPlugins = <String, List<String>>{};
    for (final report in reports) {
      updated.addAll(report.updated);
      _pool(newRepositories, report.newRepositories);
      _pool(newPlugins, report.newPlugins);
    }
    return ExtensionUpdateReport(
      updated: updated,
      newRepositories: newRepositories,
      newPlugins: newPlugins,
    );
  }

  /// Names of the plugins brought up to date.
  final List<String> updated;

  /// Repositories that a collection the user follows listed for the first
  /// time, and that were added: their names, under the collection's name. A
  /// CloudStream plugin that adds repositories (MegaRepo's) counts as a
  /// collection, under the plugin's name.
  final Map<String, List<String>> newRepositories;

  /// Plugins that a repository listed for the first time: their names, under
  /// the repository's name. Offered, not installed.
  final Map<String, List<String>> newPlugins;

  bool get isEmpty =>
      updated.isEmpty && newRepositories.isEmpty && newPlugins.isEmpty;

  /// One toast per kind of news, always in this order: updates, repositories,
  /// plugins.
  ///
  /// The title carries the count and where the news came from, so both
  /// survive a list of names long enough to be cut short - see [toastNames].
  List<({String title, String message})> toasts(AppLocalizations l10n) {
    final repositories = <String>[
      for (final names in newRepositories.values) ...names,
    ];
    final plugins = <String>[for (final names in newPlugins.values) ...names];
    return <({String title, String message})>[
      if (updated.isNotEmpty)
        (
          title: l10n.extensionsUpdated(updated.length),
          message: toastNames(updated),
        ),
      if (repositories.isNotEmpty)
        (
          title: l10n.extensionsNewRepositories(
            repositories.length,
            toastNames(newRepositories.keys),
          ),
          message: toastNames(repositories),
        ),
      if (plugins.isNotEmpty)
        (
          title: l10n.extensionsNewPlugins(
            plugins.length,
            toastNames(newPlugins.keys),
          ),
          message: toastNames(plugins),
        ),
    ];
  }

  static void _pool(
    Map<String, List<String>> into,
    Map<String, List<String>> from,
  ) {
    for (final entry in from.entries) {
      (into[entry.key] ??= <String>[]).addAll(entry.value);
    }
  }
}

/// The names a toast shows.
///
/// Names are proper nouns and never translated, and the toast gives them two
/// lines, so past four the first three are named and the rest counted. Exactly
/// four are all named: "+1" says less than the name it would replace.
String toastNames(Iterable<String> names) {
  const named = 3;
  final all = names.toList();
  if (all.length <= named + 1) return all.join(', ');
  return '${all.take(named).join(', ')} +${all.length - named}';
}
