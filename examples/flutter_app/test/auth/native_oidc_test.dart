import 'dart:convert';

import 'package:cosmos_sync_example/auth/native_oidc.dart';
import 'package:cosmos_sync_example/auth/oidc.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late CapturingAppAuth plugin;
  late NativeOidcClient native;
  late OidcConfig config;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    plugin = CapturingAppAuth();
    native = NativeOidcClient(appAuth: plugin);
    config = OidcConfig(
      issuer: 'https://issuer.example.test/tenant',
      clientId: 'public-native-client',
      redirectUrl: 'com.anaregdesign.cosmossync://auth/oauthredirect',
      scopes: ['openid', 'offline_access', 'api://bff/Cosmos.Sync'],
      postLogoutRedirectUrl: 'com.anaregdesign.cosmossync:/logout',
    );
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
    'combined code exchange uses native user agent, HTTPS discovery and no secret',
    () async {
      final result = await native.signIn(config);
      final request = plugin.authorization!;
      expect(request.clientId, 'public-native-client');
      expect(request.redirectUrl, config.redirectUrl);
      expect(request.discoveryUrl, config.discoveryUrl);
      expect(request.scopes, config.scopes);
      expect(request.clientSecret, null);
      expect(request.allowInsecureConnections, false);
      expect(request.promptValues, null);
      expect(
        request.externalUserAgent,
        ExternalUserAgent.asWebAuthenticationSession,
      );
      expect(result.accessToken, 'api-access-token');
      expect(result.idToken, 'id-token-logout-hint');
      expect(result.tokenType, 'Bearer');
    },
  );

  test(
    'explicit fresh Apple-platform sign-in requests isolated browser and login without changing trust',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final binding = config.storageBinding;
      final isolated = NativeOidcClient(
        appAuth: plugin,
        freshInteractiveSession: true,
      );
      await isolated.signIn(config);
      final request = plugin.authorization!;
      expect(request.promptValues, ['login']);
      expect(
        request.externalUserAgent,
        ExternalUserAgent.ephemeralAsWebAuthenticationSession,
      );
      expect(request.clientId, config.clientId);
      expect(request.redirectUrl, config.redirectUrl);
      expect(request.discoveryUrl, config.discoveryUrl);
      expect(request.scopes, config.scopes);
      expect(request.clientSecret, null);
      expect(request.allowInsecureConnections, false);
      expect(config.storageBinding, binding);
      await isolated.refresh(config, 'opaque-refresh-secret');
      expect(plugin.tokenRequest!.refreshToken, 'opaque-refresh-secret');
      expect(plugin.tokenRequest!.clientSecret, null);
      expect(plugin.tokenRequest!.scopes, config.scopes);
    },
  );

  test(
    'fresh Android sign-in requests login without claiming Apple ephemeral support',
    () async {
      final isolated = NativeOidcClient(
        appAuth: plugin,
        freshInteractiveSession: true,
      );
      await isolated.signIn(config);
      expect(plugin.authorization!.promptValues, ['login']);
      expect(
        plugin.authorization!.externalUserAgent,
        ExternalUserAgent.asWebAuthenticationSession,
      );
    },
  );

  test(
    'fresh proof pins server nonce and interactive auth_time without retaining refresh',
    () async {
      final proof = await native.freshIdentityProof(config, 'a' * 64);
      final request = plugin.authorization!;
      expect(request.nonce, 'a' * 64);
      expect(request.promptValues, ['login']);
      expect(request.additionalParameters!['max_age'], '0');
      expect(jsonDecode(request.additionalParameters!['claims']!), {
        'id_token': {
          'auth_time': {'essential': true},
        },
      });
      expect(request.clientId, config.clientId);
      expect(request.redirectUrl, config.redirectUrl);
      expect(request.scopes, config.scopes);
      expect(request.clientSecret, null);
      expect(request.allowInsecureConnections, false);
      expect(proof.accessToken, 'api-access-token');
      expect(proof.idToken, 'id-token-logout-hint');
      expect(proof.toJson().keys, ['accessToken', 'idToken']);
      expect(proof.toString(), isNot(contains('api-access-token')));
      expect(plugin.tokenRequest, null);
    },
  );

  test('invalid proof nonce never launches AppAuth', () async {
    await expectLater(
      native.freshIdentityProof(config, 'client-nonce'),
      throwsA(
        isA<AuthException>().having(
          (error) => error.code,
          'code',
          'invalid_identity_challenge',
        ),
      ),
    );
    expect(plugin.authorization, null);
  });

  test(
    'fresh proof requires a separate ID token and usable API scope',
    () async {
      for (final response in [
        AuthorizationTokenResponse(
          'api-token',
          'discard-refresh',
          DateTime.now().add(const Duration(hours: 1)),
          null,
          'Bearer',
          config.scopes,
          null,
          null,
        ),
        AuthorizationTokenResponse(
          'api-token',
          'discard-refresh',
          DateTime.now().add(const Duration(hours: 1)),
          'id-token',
          'Bearer',
          ['openid'],
          null,
          null,
        ),
      ]) {
        plugin.authorizationResponse = response;
        await expectLater(
          native.freshIdentityProof(config, 'a' * 64),
          throwsA(
            isA<AuthException>().having(
              (error) => error.code,
              'code',
              'invalid_proof_response',
            ),
          ),
        );
      }
    },
  );

  test(
    'refresh sends only refresh credential to public-client token endpoint',
    () async {
      await native.refresh(config, 'opaque-refresh-secret');
      final request = plugin.tokenRequest!;
      expect(request.refreshToken, 'opaque-refresh-secret');
      expect(request.clientSecret, null);
      expect(request.authorizationCode, null);
      expect(request.allowInsecureConnections, false);
      expect(request.scopes, config.scopes);
    },
  );

  test(
    'provider end-session uses separate logout hint and registered callback',
    () async {
      await native.endSession(config, 'id-token-logout-hint');
      expect(plugin.logout!.idTokenHint, 'id-token-logout-hint');
      expect(
        plugin.logout!.postLogoutRedirectUrl,
        config.postLogoutRedirectUrl,
      );
      expect(plugin.logout!.discoveryUrl, config.discoveryUrl);
    },
  );

  test(
    'native token invalid_grant is terminal without exposing secret native descriptions',
    () async {
      plugin.failure = FlutterAppAuthPlatformException(
        code: 'token_failed',
        message: 'raw-access-secret',
        platformErrorDetails: FlutterAppAuthPlatformErrorDetails(
          error: 'invalid_grant',
          errorDescription: 'raw-refresh-secret',
        ),
      );
      await expectLater(
        native.refresh(config, 'refresh-secret'),
        throwsA(
          isA<OidcFailure>()
              .having(
                (error) => error.kind,
                'kind',
                OidcFailureKind.interactionRequired,
              )
              .having(
                (error) => error.toString(),
                'message',
                isNot(contains('secret')),
              ),
        ),
      );
    },
  );

  test(
    'structured provider transient error retains distinction from denied refresh',
    () async {
      plugin.failure = FlutterAppAuthPlatformException(
        code: 'token_failed',
        message: 'raw-account-email',
        platformErrorDetails: FlutterAppAuthPlatformErrorDetails(
          error: 'temporarily_unavailable',
        ),
      );
      await expectLater(
        native.refresh(config, 'refresh-secret'),
        throwsA(
          isA<OidcFailure>().having(
            (error) => error.kind,
            'kind',
            OidcFailureKind.transient,
          ),
        ),
      );
    },
  );

  test('unrecognized native errors are redacted', () async {
    plugin.failure = Exception('raw-access-secret raw-refresh-secret');
    await expectLater(
      native.signIn(config),
      throwsA(
        isA<OidcFailure>()
            .having((error) => error.kind, 'kind', OidcFailureKind.failed)
            .having(
              (error) => error.toString(),
              'message',
              isNot(contains('secret')),
            ),
      ),
    );
  });

  test(
    'unsupported native platforms fail before launching any browser',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await expectLater(
        native.signIn(config),
        throwsA(
          isA<AuthException>().having(
            (error) => error.code,
            'code',
            'unsupported_platform',
          ),
        ),
      );
      expect(plugin.authorization, null);
    },
  );
}

class CapturingAppAuth extends FlutterAppAuth {
  AuthorizationTokenRequest? authorization;
  TokenRequest? tokenRequest;
  EndSessionRequest? logout;
  Object? failure;
  AuthorizationTokenResponse? authorizationResponse;

  @override
  Future<AuthorizationTokenResponse> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  ) async {
    if (failure != null) {
      throw failure!;
    }
    authorization = request;
    if (authorizationResponse != null) return authorizationResponse!;
    return AuthorizationTokenResponse(
      'api-access-token',
      'refresh-token',
      DateTime.now().add(const Duration(hours: 1)),
      'id-token-logout-hint',
      'Bearer',
      request.scopes,
      null,
      null,
    );
  }

  @override
  Future<TokenResponse> token(TokenRequest request) async {
    if (failure != null) {
      throw failure!;
    }
    tokenRequest = request;
    return TokenResponse(
      'new-api-access-token',
      'new-refresh-token',
      DateTime.now().add(const Duration(hours: 1)),
      null,
      'Bearer',
      request.scopes,
      null,
    );
  }

  @override
  Future<EndSessionResponse> endSession(EndSessionRequest request) async {
    if (failure != null) {
      throw failure!;
    }
    logout = request;
    return EndSessionResponse(null);
  }
}
