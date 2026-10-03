import 'dart:async';
import 'dart:convert';

import 'package:cosmos_sync_example/auth/auth_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 3);
  late DateTime now;
  late FakeOidc oidc;
  late MemorySecureStore store;
  late AuthSessionController auth;

  OidcConfig config({String clientId = 'native-public-client'}) => OidcConfig(
    issuer: 'https://login.example.test/tenant',
    clientId: clientId,
    redirectUrl: 'com.anaregdesign.cosmossync://auth/oauthredirect',
    scopes: ['openid', 'offline_access', 'api://bff/Cosmos.Sync'],
    postLogoutRedirectUrl: 'com.anaregdesign.cosmossync:/logout',
  );
  OidcTokens tokens({
    String? refresh = 'refresh-secret',
    String? access = 'access-secret',
    String? id = 'id-secret',
    String tokenType = 'Bearer',
    List<String>? scopes,
  }) => OidcTokens(
    accessToken: access,
    refreshToken: refresh,
    idToken: id,
    tokenType: tokenType,
    expiresAt: now.add(const Duration(hours: 1)),
    scopes: scopes,
  );
  Matcher code(String expected) =>
      isA<AuthException>().having((error) => error.code, 'code', expected);

  setUp(() {
    now = start;
    oidc = FakeOidc();
    store = MemorySecureStore();
    auth = AuthSessionController(
      oidc: oidc,
      tokenStore: store,
      clock: () => now,
    );
    auth.configure(config());
    oidc.signInAction = (_) async => tokens();
    oidc.refreshAction = (_, _) async =>
        tokens(access: 'renewed-access', refresh: 'rotated-refresh');
  });
  tearDown(() => auth.dispose());

  test(
    'uses access token and stores only refresh credential plus binding/logout hint',
    () async {
      await auth.signIn();
      expect(await auth.accessToken(), 'access-secret');
      expect(store.value, isNot(contains('access-secret')));
      final stored = jsonDecode(store.value!) as Map<String, dynamic>;
      expect(stored.keys.toSet(), {
        'version',
        'config',
        'refreshToken',
        'idToken',
        'credentialSessionId',
      });
      expect(stored['refreshToken'], 'refresh-secret');
      expect(auth.credentialSessionId, matches(r'^[A-Za-z0-9_-]{32}$'));
      expect(auth.restoredSession, false);
      expect(auth.hasStoredSession, true);
      expect(oidc.refreshCalls, 0);
    },
  );

  test('never substitutes an ID token for missing API access token', () async {
    oidc.signInAction = (_) async => tokens(access: null);
    await expectLater(auth.signIn(), throwsA(code('invalid_token_response')));
    expect(auth.isSignedIn, false);
    expect(store.value, null);
  });

  test(
    'rejects non-Bearer response and explicitly reduced API scopes',
    () async {
      oidc.signInAction = (_) async => tokens(tokenType: 'DPoP');
      await expectLater(auth.signIn(), throwsA(code('invalid_token_response')));
      oidc.signInAction = (_) async =>
          tokens(scopes: ['openid', 'offline_access']);
      await expectLater(auth.signIn(), throwsA(code('api_scope_denied')));
    },
  );

  test('rejects token responses without a trustworthy expiry', () async {
    oidc.signInAction = (_) async =>
        const OidcTokens(accessToken: 'secret', tokenType: 'Bearer');
    await expectLater(auth.signIn(), throwsA(code('invalid_token_response')));
  });

  test(
    'restore is offline and retains opaque binding without decoding token claims',
    () async {
      await auth.signIn();
      final binding = auth.credentialSessionId;
      auth.dispose();
      auth = AuthSessionController(
        oidc: oidc,
        tokenStore: store,
        clock: () => now,
      )..configure(config());
      oidc.refreshAction = (_, _) async =>
          throw const OidcFailure(OidcFailureKind.transient);
      await auth.restore();
      expect(oidc.refreshCalls, 0);
      expect(auth.state, AuthSessionState.ready);
      expect(auth.restoredSession, true);
      expect(auth.credentialSessionId, binding);
      await expectLater(auth.accessToken(), throwsA(code('refresh_failed')));
      expect(auth.credentialSessionId, binding);
      expect(auth.hasStoredSession, true);
      expect(store.value, isNotNull);
    },
  );

  test(
    'provider/client configuration change cannot restore prior credentials',
    () async {
      await auth.signIn();
      auth.dispose();
      auth = AuthSessionController(oidc: oidc, tokenStore: store)
        ..configure(config(clientId: 'different-client'));
      await auth.restore();
      expect(auth.credentialSessionId, null);
      expect(store.value, null);
      expect(oidc.refreshCalls, 0);
    },
  );

  test(
    'corrupt credential record is removed without returning its raw contents',
    () async {
      store.value = '{refresh-secret-that-must-never-be-logged';
      await auth.restore();
      expect(store.value, null);
      expect(auth.state, AuthSessionState.signedOut);
      expect(auth.error, null);
    },
  );

  test(
    'concurrent refreshes share one request and persist rotation before returning',
    () async {
      await auth.signIn();
      final binding = auth.credentialSessionId;
      now = now.add(const Duration(hours: 2));
      final response = Completer<OidcTokens>();
      oidc.refreshAction = (_, old) {
        expect(old, 'refresh-secret');
        return response.future;
      };
      final first = auth.accessToken();
      final second = auth.accessToken();
      expect(oidc.refreshCalls, 1);
      response.complete(
        tokens(access: 'renewed-access', refresh: 'new-refresh'),
      );
      expect(await Future.wait([first, second]), [
        'renewed-access',
        'renewed-access',
      ]);
      expect(store.value, contains('new-refresh'));
      expect(store.value, isNot(contains('renewed-access')));
      expect(auth.credentialSessionId, binding);
    },
  );

  test(
    'refreshing notification reentry joins one refresh with a rotating token',
    () async {
      await auth.signIn();
      now = now.add(const Duration(hours: 2));
      final response = Completer<OidcTokens>();
      oidc.refreshAction = (_, old) {
        expect(old, 'refresh-secret');
        return response.future;
      };
      Future<String>? fromListener;
      bool handled = false;
      auth.addListener(() {
        if (auth.state == AuthSessionState.refreshing && !handled) {
          handled = true;
          fromListener = auth.accessToken();
        }
      });
      final first = auth.accessToken();
      expect(oidc.refreshCalls, 1);
      response.complete(
        tokens(access: 'renewed-access', refresh: 'rotated-refresh'),
      );
      expect(await Future.wait([first, fromListener!]), [
        'renewed-access',
        'renewed-access',
      ]);
      expect(oidc.refreshCalls, 1);
      expect(
        (jsonDecode(store.value!) as Map)['refreshToken'],
        'rotated-refresh',
      );
    },
  );

  test(
    'authorizing notification reentry rejects a second sign-in without cancelling the first',
    () async {
      Future<void>? rejected;
      bool handled = false;
      auth.addListener(() {
        if (auth.state == AuthSessionState.authorizing && !handled) {
          handled = true;
          rejected = expectLater(auth.signIn(), throwsA(code('auth_busy')));
        }
      });
      await auth.signIn();
      await rejected;
      expect(oidc.signInCalls, 1);
      expect(auth.isSignedIn, true);
      expect(await auth.accessToken(), 'access-secret');
      await auth.signOut();
      await auth.signIn();
      expect(oidc.signInCalls, 2);
    },
  );

  test(
    'refreshing notification logout cancels before sending a refresh request',
    () async {
      await auth.signIn();
      now = now.add(const Duration(hours: 2));
      Future<void>? signedOut;
      auth.addListener(() {
        if (auth.state == AuthSessionState.refreshing) {
          signedOut = auth.signOut();
        }
      });
      await expectLater(auth.accessToken(), throwsA(code('cancelled')));
      await signedOut;
      expect(oidc.refreshCalls, 0);
      expect(store.value, null);
      expect(auth.isSignedIn, false);
    },
  );

  test(
    'terminal refresh notification cannot restore a credential pending deletion',
    () async {
      await auth.signIn();
      now = now.add(const Duration(hours: 2));
      oidc.refreshAction = (_, _) async =>
          throw const OidcFailure(OidcFailureKind.interactionRequired);
      Future<void>? rejected;
      bool handled = false;
      auth.addListener(() {
        if (auth.state == AuthSessionState.signedOut && !handled) {
          handled = true;
          rejected = expectLater(auth.restore(), throwsA(code('auth_busy')));
        }
      });
      await expectLater(auth.accessToken(), throwsA(code('sign_in_required')));
      await rejected;
      expect(store.value, null);
      expect(auth.isSignedIn, false);
      expect(auth.state, AuthSessionState.signedOut);
      await auth.restore();
      expect(auth.isSignedIn, false);
    },
  );

  test(
    'refresh response without rotated refresh token preserves existing token',
    () async {
      await auth.signIn();
      now = now.add(const Duration(hours: 2));
      oidc.refreshAction = (_, _) async => tokens(refresh: null);
      await auth.accessToken();
      expect(
        (jsonDecode(store.value!) as Map)['refreshToken'],
        'refresh-secret',
      );
    },
  );

  test(
    'explicit API scope reduction during refresh removes offline credential binding',
    () async {
      await auth.signIn();
      now = now.add(const Duration(hours: 2));
      oidc.refreshAction = (_, _) async =>
          tokens(scopes: ['openid', 'offline_access']);
      await expectLater(auth.accessToken(), throwsA(code('api_scope_denied')));
      expect(auth.isSignedIn, false);
      expect(auth.credentialSessionId, null);
      expect(store.value, null);
      expect(auth.state, AuthSessionState.signedOut);
    },
  );

  test(
    'terminal refresh failure immediately drops cache binding and removes credentials',
    () async {
      await auth.signIn();
      now = now.add(const Duration(hours: 2));
      oidc.refreshAction = (_, _) async =>
          throw const OidcFailure(OidcFailureKind.interactionRequired);
      bool observedDroppedBinding = false;
      auth.addListener(() {
        if (auth.state == AuthSessionState.signedOut) {
          observedDroppedBinding = !auth.isSignedIn;
        }
      });
      await expectLater(auth.accessToken(), throwsA(code('sign_in_required')));
      expect(observedDroppedBinding, true);
      expect(store.value, null);
      expect(auth.hasStoredSession, false);
    },
  );

  test(
    'late browser callback after local signout cannot resurrect credentials',
    () async {
      final response = Completer<OidcTokens>();
      final launched = Completer<void>();
      oidc.signInAction = (_) {
        launched.complete();
        return response.future;
      };
      final signingIn = auth.signIn();
      final failed = expectLater(signingIn, throwsA(code('cancelled')));
      await launched.future;
      await auth.signOut();
      response.complete(tokens());
      await failed;
      expect(store.value, null);
      expect(auth.credentialSessionId, null);
      expect(auth.state, AuthSessionState.signedOut);
    },
  );

  test(
    'cancellation drains and removes a concurrently committing secure write',
    () async {
      final writeEntered = Completer<void>();
      final writeReleased = Completer<void>();
      store.beforeWrite = () {
        writeEntered.complete();
        return writeReleased.future;
      };
      final signingIn = auth.signIn();
      final failed = expectLater(signingIn, throwsA(code('cancelled')));
      await writeEntered.future;
      final cancelling = auth.cancelSignIn();
      expect(auth.isSignedIn, false);
      writeReleased.complete();
      await cancelling;
      await failed;
      expect(store.value, null);
      expect(auth.state, AuthSessionState.signedOut);
    },
  );

  test(
    'native user cancellation is handled without exposing native error text',
    () async {
      oidc.signInAction = (_) async =>
          throw const OidcFailure(OidcFailureKind.cancelled);
      await expectLater(auth.signIn(), throwsA(code('cancelled')));
      expect(auth.state, AuthSessionState.signedOut);
      expect(auth.error, null);
    },
  );

  test(
    'late refresh after signout cannot return or store refreshed credentials',
    () async {
      await auth.signIn();
      now = now.add(const Duration(hours: 2));
      final response = Completer<OidcTokens>();
      oidc.refreshAction = (_, _) => response.future;
      final refreshing = auth.accessToken();
      final failed = expectLater(refreshing, throwsA(code('cancelled')));
      await auth.signOut();
      response.complete(tokens(refresh: 'late-refresh'));
      await failed;
      expect(store.value, null);
      expect(auth.isSignedIn, false);
    },
  );

  test(
    'fresh interactive sign-in always rotates offline cache binding',
    () async {
      await auth.signIn();
      final first = auth.credentialSessionId;
      await auth.signOut();
      await auth.signIn();
      expect(auth.credentialSessionId, isNot(first));
    },
  );

  test(
    'secure deletion failure is explicit despite memory being signed out',
    () async {
      await auth.signIn();
      store.failClear = true;
      await expectLater(auth.signOut(), throwsA(code('storage_failed')));
      expect(auth.isSignedIn, false);
      expect(auth.error!.message, isNot(contains('refresh-secret')));
      expect(store.value, isNotNull);
      store.failClear = false;
      await auth.signOut();
      expect(store.value, null);
    },
  );

  test(
    'provider logout failure does not undo local credential deletion',
    () async {
      await auth.signIn();
      oidc.logoutAction = (_, hint) async {
        expect(hint, 'id-secret');
        expect(store.value, null);
        throw Exception('secret-token-in-provider-native-description');
      };
      await expectLater(
        auth.signOut(endProviderSession: true),
        throwsA(code('provider_logout_failed')),
      );
      expect(auth.isSignedIn, false);
      expect(store.value, null);
      expect(auth.error.toString(), isNot(contains('secret-token')));
    },
  );

  test('raw provider exception descriptions are redacted', () async {
    oidc.signInAction = (_) async =>
        throw Exception('access-secret refresh-secret id-secret');
    await expectLater(auth.signIn(), throwsA(code('sign_in_failed')));
    expect(auth.error.toString(), isNot(contains('secret')));
    expect(tokens().toString(), 'OidcTokens([redacted])');
  });

  test('config cannot change during an active credential session', () async {
    await auth.signIn();
    expect(
      () => auth.configure(config(clientId: 'other')),
      throwsA(code('auth_busy')),
    );
  });

  test('configuration validates HTTPS, private callback and API scope', () {
    OidcConfig make(String issuer, String redirect, List<String> scopes) =>
        OidcConfig(
          issuer: issuer,
          clientId: 'client',
          redirectUrl: redirect,
          scopes: scopes,
        );
    expect(
      () => make('http://issuer.test', 'com.example:/callback', [
        'openid',
        'api',
      ]),
      throwsA(code('invalid_config')),
    );
    expect(
      () => make('https://secret@issuer.test', 'com.example:/callback', [
        'openid',
        'api',
      ]),
      throwsA(code('invalid_config')),
    );
    expect(
      () => make('https://issuer.test', 'https://app.test/callback', [
        'openid',
        'api',
      ]),
      throwsA(code('invalid_config')),
    );
    expect(
      () => make('https://issuer.test', 'com.example:/callback', [
        'openid',
        'profile',
        'offline_access',
      ]),
      throwsA(code('invalid_config')),
    );
    final scopes = ['openid', 'api'];
    final validated = make(
      'https://issuer.test',
      'com.example:/callback',
      scopes,
    );
    scopes.clear();
    expect(validated.scopes, ['openid', 'api']);
    expect(() => validated.scopes.add('secret'), throwsUnsupportedError);
  });
}

class FakeOidc implements OidcClient {
  late Future<OidcTokens> Function(OidcConfig) signInAction;
  late Future<OidcTokens> Function(OidcConfig, String) refreshAction;
  Future<void> Function(OidcConfig, String?) logoutAction = (_, _) async {};
  int signInCalls = 0;
  int refreshCalls = 0;
  @override
  Future<OidcTokens> signIn(OidcConfig config) {
    signInCalls++;
    return signInAction(config);
  }

  @override
  Future<OidcTokens> refresh(OidcConfig config, String refreshToken) {
    refreshCalls++;
    return refreshAction(config, refreshToken);
  }

  @override
  Future<void> endSession(OidcConfig config, String? idToken) =>
      logoutAction(config, idToken);
}

class MemorySecureStore implements RefreshTokenStore {
  String? value;
  Future<void> Function()? beforeWrite;
  bool failClear = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String newValue) async {
    await beforeWrite?.call();
    value = newValue;
  }

  @override
  Future<void> clear() async {
    if (failClear) throw Exception('raw-refresh-secret');
    value = null;
  }
}
