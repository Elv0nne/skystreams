/// Whether [url] is an answer to [redirect]: the same scheme, host, port and
/// path, compared as parsed parts rather than text, so `http://localhost`
/// can't be matched by `http://localhost.example.com`.
bool isRedirectAnswer(Uri url, Uri redirect) {
  String path(Uri u) => u.path.isEmpty ? '/' : u.path;
  return url.scheme == redirect.scheme &&
      url.host == redirect.host &&
      url.port == redirect.port &&
      path(url) == path(redirect);
}
