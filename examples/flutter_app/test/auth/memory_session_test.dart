import 'dart:async';

import 'package:cosmos_sync_example/auth/auth_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final config = OidcConfig(
    issuer: 'https://example.ciamlogin.com/tenant/v2.0',
    clientId: 'public-spa',
    redirectUrl: 'https://app.example.test/auth-redirect.html',
    scopes: ['openid', 'api://bff/Cosmos.Sync'],
    browser: true,
  );
  late DateTime now;
  late _MemoryOidc oidc;
  late _NoCredentialStore store;
  late AuthSessionController auth;
  OidcTokens tokens({String access = 'fixture-api-token', String? refresh}) =>
      OidcTokens(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: now.add(const Duration(hours: 1)),
        scopes: ['api://bff/Cosmos.Sync'],
        tokenType: 'Bearer',
      );
  Matcher code(String value) =>
      isA<AuthException>().having((error) => error.code, 'code', value);

  setUp(() {
    now = DateTime.utc(2026, 10, 4);
    oidc = _MemoryOidc()..signInAction = (_) async => tokens();
    store = _NoCredentialStore();
    auth = AuthSessionController(
      oidc: oidc,
      tokenStore: store,
      clock: () => now,
    )..configure(config);
  });
  tearDown(() => auth.close());

  test('browser callback validation is separate from native configuration', () {
    OidcConfig callback(String uri, {required bool browser}) => OidcConfig(
      issuer: config.issuer,
      clientId: config.clientId,
      redirectUrl: uri,
      scopes: config.scopes,
      browser: browser,
    );
    expect(
      () => callback(config.redirectUrl, browser: false),
      throwsA(code('invalid_config')),
    );
    expect(
      callback(
        'http://localhost:8123/auth-redirect.html',
        browser: true,
      ).browser,
      true,
    );
    for (final value in [
      'http://public.example.test/auth-redirect.html',
      'https://app.example.test/oauthredirect',
      'https://app.example.test/auth-redirect.html?code=fixture',
      'https://app.example.test/auth-redirect.html#response',
      'com.anaregdesign.cosmossync://auth/oauthredirect',
    ]) {
      expect(
        () => callback(value, browser: true),
        throwsA(code('invalid_config')),
      );
    }
    expect(config.withBrokerCapabilities(null).browser, true);
  });

  test(
    'memory renewal is single-flight without exporting a refresh token',
    () async {
      await auth.signIn();
      final binding = auth.credentialSessionId;
      expect(auth.isSignedIn, true);
      expect(auth.hasStoredSession, false);
      expect(auth.restoredSession, false);
      expect(auth.supportsCredentialRestore, false);
      now = now.add(const Duration(hours: 2));
      final response = Completer<OidcTokens>();
      oidc.refreshAction = (_) => response.future;
      final first = auth.accessToken();
      final second = auth.accessToken();
      expect(oidc.refreshCalls, 1);
      response.complete(tokens(access: 'fixture-rotated-token'));
      expect(await Future.wait([first, second]), [
        'fixture-rotated-token',
        'fixture-rotated-token',
      ]);
      expect(auth.credentialSessionId, binding);
      expect(store.reads, 0);
      expect(store.writes, 0);
      expect(auth.hasStoredSession, false);
      await auth.signOut();
      expect(auth.isSignedIn, false);
      expect(oidc.clears, 2);
    },
  );

  test(
    'startup clears memory rather than reading a legacy credential record',
    () async {
      await auth.restore();
      expect(store.reads, 0);
      expect(store.writes, 0);
      expect(oidc.clears, 1);
      expect(auth.isSignedIn, false);
      expect(auth.restoredSession, false);
      expect(auth.state, AuthSessionState.signedOut);
    },
  );

  test(
    'terminal silent denial clears memory and the opaque cache binding',
    () async {
      await auth.signIn();
      now = now.add(const Duration(hours: 2));
      oidc.refreshAction = (_) async =>
          throw const OidcFailure(OidcFailureKind.interactionRequired);
      await expectLater(auth.accessToken(), throwsA(code('sign_in_required')));
      expect(auth.state, AuthSessionState.signedOut);
      expect(auth.credentialSessionId, null);
      expect(oidc.clears, 2);
      expect(store.writes, 0);
    },
  );

  test('logout and cancellation reject late memory callbacks', () async {
    final launched = Completer<void>();
    final signInResponse = Completer<OidcTokens>();
    oidc.signInAction = (_) {
      launched.complete();
      return signInResponse.future;
    };
    final rejected = expectLater(auth.signIn(), throwsA(code('cancelled')));
    await launched.future;
    await auth.cancelSignIn();
    signInResponse.complete(tokens());
    await rejected;
    expect(auth.isSignedIn, false);
    expect(oidc.clears, 2);
    expect(store.writes, 0);

    oidc.signInAction = (_) async => tokens();
    await auth.signIn();
    now = now.add(const Duration(hours: 2));
    final refreshResponse = Completer<OidcTokens>();
    oidc.refreshAction = (_) => refreshResponse.future;
    final lateRefresh = expectLater(
      auth.accessToken(),
      throwsA(code('cancelled')),
    );
    await auth.signOut();
    refreshResponse.complete(tokens());
    await lateRefresh;
    expect(auth.isSignedIn, false);
    expect(store.writes, 0);
  });

  test(
    'a memory client cannot leak a refresh credential into application storage',
    () async {
      oidc.signInAction = (_) async =>
          tokens(refresh: 'fixture-private-refresh');
      await expectLater(auth.signIn(), throwsA(code('invalid_token_response')));
      expect(auth.isSignedIn, false);
      expect(store.writes, 0);
      expect(oidc.clears, 2);
      expect(auth.error.toString(), isNot(contains('fixture-private-refresh')));
    },
  );

  test(
    'failed memory cleanup is visible, credentials are forgotten, and retry works',
    () async {
      await auth.signIn();
      oidc.failClear = true;
      await expectLater(auth.signOut(), throwsA(code('storage_failed')));
      expect(auth.state, AuthSessionState.error);
      expect(auth.credentialSessionId, null);
      expect(auth.error.toString(), isNot(contains('fixture-private-message')));
      oidc.failClear = false;
      await auth.signOut();
      expect(auth.state, AuthSessionState.signedOut);
    },
  );

  test(
    'closing releases browser SDK memory and rejects an outstanding renewal',
    () async {
      await auth.signIn();
      now = now.add(const Duration(hours: 2));
      final response = Completer<OidcTokens>();
      oidc.refreshAction = (_) => response.future;
      final late = expectLater(auth.accessToken(), throwsA(code('cancelled')));
      await auth.close();
      response.complete(tokens());
      await late;
      expect(auth.isSignedIn, false);
      expect(oidc.clears, 2);
      await auth.close();
      expect(oidc.clears, 2);
    },
  );
}

class _MemoryOidc implements MemoryOidcClient {
  late Future<OidcTokens> Function(OidcConfig) signInAction;
  late Future<OidcTokens> Function(OidcConfig) refreshAction;
  int refreshCalls = 0;
  int clears = 0;
  bool failClear = false;

  @override
  Future<OidcTokens> signIn(OidcConfig config) => signInAction(config);
  @override
  Future<OidcTokens> refreshCurrent(OidcConfig config) {
    refreshCalls++;
    return refreshAction(config);
  }

  @override
  Future<OidcTokens> refresh(OidcConfig config, String refreshToken) =>
      throw StateError('A browser refresh token must never be exported.');
  @override
  Future<void> clearSession() async {
    clears++;
    if (failClear) throw StateError('fixture-private-message');
  }

  @override
  Future<void> endSession(OidcConfig config, String? idToken) async {}
}

class _NoCredentialStore implements RefreshTokenStore {
  int reads = 0;
  int writes = 0;
  @override
  Future<String?> read() async {
    reads++;
    throw StateError(
      'Browser restore must not read native credential records.',
    );
  }

  @override
  Future<void> write(String value) async {
    writes++;
    throw StateError('Browser credentials must not enter application storage.');
  }

  @override
  Future<void> clear() async {}
}
