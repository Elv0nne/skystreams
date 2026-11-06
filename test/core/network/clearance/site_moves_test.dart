import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/core/network/clearance/site_moves.dart';

/// A site moved when it sends its visitors to another site for good, keeping
/// everything but the host: then its requests can go there directly.
void main() {
  final keys = SiteKeys.parse(
    File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
  );
  Uri? moved(String from, String to, List<int> codes) => movedOrigin(
    requested: Uri.parse(from),
    reached: Uri.parse(to),
    codes: codes,
    keys: keys,
  );

  test('a permanent redirect to another site, the host all that changed, '
      'is a move', () {
    expect(
      moved(
        'https://www.5movierulz.pictures/search_movies?s=x',
        'https://www.5movierulz.works/search_movies?s=x',
        [301],
      ),
      Uri.parse('https://www.5movierulz.works'),
    );
  });

  test('308s, and chains of permanent redirects, are too', () {
    expect(
      moved(
        'https://www.1tamilblasters.pro/?s=x',
        'https://www.1tamilblasters.tech/?s=x',
        [301, 308],
      ),
      Uri.parse('https://www.1tamilblasters.tech'),
    );
  });

  test('a temporary redirect anywhere in the chain is not', () {
    expect(moved('https://a.com/x', 'https://b.org/x', [302]), isNull);
    expect(moved('https://a.com/x', 'https://b.org/x', [301, 307]), isNull);
  });

  test('a changed path or query is not', () {
    expect(moved('https://a.com/search?q=1', 'https://b.org/', [301]), isNull);
    expect(
      moved('https://a.com/search?q=1', 'https://b.org/search?q=2', [301]),
      isNull,
    );
  });

  test('the same site, www or not, is not', () {
    expect(moved('https://a.com/x', 'https://www.a.com/x', [301]), isNull);
  });

  test('no redirect is not', () {
    expect(moved('https://a.com/x', 'https://a.com/x', const []), isNull);
  });

  test('an empty path and a bare slash are the same', () {
    expect(
      moved('https://a.com', 'https://b.org/', [301]),
      Uri.parse('https://b.org'),
    );
  });

  test('a port the new domain names is kept', () {
    expect(
      moved('https://a.com/x', 'https://b.org:8443/x', [301]),
      Uri.parse('https://b.org:8443'),
    );
  });
}
