import 'site_keys.dart';

/// The origin a site moved to, when [reached] is another site's address that
/// [requested] got to only through permanent redirects ([codes]: 301 or 308)
/// changing nothing but the host, path and query kept. Null for anything
/// else, a temporary redirect anywhere in the chain included: sites send
/// visitors elsewhere for a while for many reasons, and only a move for good
/// is followed.
Uri? movedOrigin({
  required Uri requested,
  required Uri reached,
  required Iterable<int> codes,
  required SiteKeys keys,
}) {
  if (codes.isEmpty || codes.any((code) => code != 301 && code != 308)) {
    return null;
  }
  if (keys.siteOf(requested.host) == keys.siteOf(reached.host)) return null;
  String path(Uri uri) => uri.path.isEmpty ? '/' : uri.path;
  if (path(requested) != path(reached) || requested.query != reached.query) {
    return null;
  }
  return Uri(
    scheme: reached.scheme,
    host: reached.host,
    port: reached.hasPort ? reached.port : null,
  );
}
