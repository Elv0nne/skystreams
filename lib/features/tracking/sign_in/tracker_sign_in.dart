import 'dart:convert';
import 'dart:math';

import '../../../core/config/sync_config.dart';
import '../data/anilist_service.dart';
import '../data/mal_service.dart';
import 'sign_in_method.dart';
import 'sign_in_runner.dart';

/// How a tracker sign-in ended.
enum SignInResult {
  signedIn,

  /// The person closed the page.
  cancelled,

  /// The provider refused, or its answer didn't check out.
  failed,
}

/// Signs in to MyAnimeList or AniList in SkyStream's own browser ([run]) and
/// saves the token the provider sends back.
class TrackerSignIn {
  TrackerSignIn({
    required this.run,
    this.malClientId = SyncConfig.malClientId,
    this.anilistClientId = SyncConfig.anilistClientId,
    Random? random,
  }) : _random = random ?? Random.secure();

  final SignInRun run;
  final String malClientId;
  final String anilistClientId;
  final Random _random;

  static final Uri _redirect = Uri.parse(SyncConfig.signInRedirect);

  /// Authorization Code with PKCE. MyAnimeList supports only the `plain`
  /// challenge, and needs the redirect again, exactly, in the token request.
  Future<SignInResult> myAnimeList(MalService service) async {
    final verifier = service.generateCodeVerifier();
    final state = _state();
    final authorize = Uri.https('myanimelist.net', '/v1/oauth2/authorize', {
      'response_type': 'code',
      'client_id': malClientId,
      'code_challenge': verifier,
      'code_challenge_method': 'plain',
      'redirect_uri': SyncConfig.signInRedirect,
      'state': state,
    });
    final answer = await run(authorize, _redirect);
    if (answer == null) return SignInResult.cancelled;
    if (!isRedirectAnswer(answer, _redirect) ||
        answer.queryParameters['state'] != state) {
      return SignInResult.failed;
    }
    final saved = await service.exchangeCodeForToken(
      answer.toString(),
      verifier,
      redirectUri: SyncConfig.signInRedirect,
    );
    return saved ? SignInResult.signedIn : SignInResult.failed;
  }

  /// Implicit grant: the token comes in the redirect's fragment, to the
  /// client's one registered redirect.
  Future<SignInResult> aniList(AniListService service) async {
    final authorize = Uri.https('anilist.co', '/api/v2/oauth/authorize', {
      'client_id': anilistClientId,
      'response_type': 'token',
    });
    final answer = await run(authorize, _redirect);
    if (answer == null) return SignInResult.cancelled;
    if (!isRedirectAnswer(answer, _redirect)) return SignInResult.failed;
    final saved = await service.saveTokenFromRedirect(answer.toString());
    return saved ? SignInResult.signedIn : SignInResult.failed;
  }

  /// A one-time value the redirect must carry back, so an answer meant for
  /// another sign-in is refused.
  String _state() => base64UrlEncode(
    List<int>.generate(24, (_) => _random.nextInt(256)),
  ).replaceAll('=', '');
}
