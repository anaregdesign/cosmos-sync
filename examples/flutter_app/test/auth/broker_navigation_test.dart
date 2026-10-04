import 'dart:async';
import 'dart:convert';

import 'package:cosmos_sync_example/auth/auth_session_controller.dart';
import 'package:cosmos_sync_example/auth/native_oidc.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_test/flutter_test.dart';

const issuer = 'https://consumer.ciamlogin.com/tenant/v2.0';
const clientId = 'native-public-client';

EntraBrokerCapabilities capabilities([
  List<BrokerProvider> providers = const [
    BrokerProvider.google,
    BrokerProvider.apple,
  ],
]) => EntraBrokerCapabilities(
  issuer: issuer,
  clientId: clientId,
  providers: providers,
);

OidcConfig configuration({EntraBrokerCapabilities? enabled}) => OidcConfig(
  issuer: issuer,
  clientId: clientId,
  redirectUrl: 'com.anaregdesign.cosmossync://auth/oauthredirect',
  scopes: ['openid', 'offline_access', 'api://bff/Cosmos.Sync'],
  brokerCapabilities: enabled,
);

TypeMatcher<AuthException> authCode(String code) =>
    isA<AuthException>().having((error) => error.code, 'code', code);

void main() {
  test('encoded public configuration redacts decode, shape and field failures', () {
    const sentinel = 'RAW_BROKER_CONFIG_SECRET_SENTINEL';
    for (final encoded in [
      '{"$sentinel":',
      sentinel,
      '["$sentinel"]',
      '"$sentinel"',
      'null',
      '{"version":1,"issuer":"$issuer","clientId":"$clientId","providers":"$sentinel"}',
      '{"version":1,"issuer":"$issuer","clientId":"$clientId","providers":["$sentinel"]}',
      '{"version":1,"issuer":"$issuer","clientId":"$clientId","providers":["google"],"clientSecret":"$sentinel"}',
    ]) {
      expect(
        () => EntraBrokerCapabilities.fromJsonString(encoded),
        throwsA(
          authCode('invalid_broker_config').having(
            (error) => error.toString(),
            'fixed redacted message',
            isNot(contains(sentinel)),
          ),
        ),
      );
    }
    expect(
      EntraBrokerCapabilities.fromJsonString(
        '{"version":1,"issuer":"$issuer","clientId":"$clientId","providers":["google"]}',
      ).providers,
      [BrokerProvider.google],
    );
  });

  test(
    'public capabilities reject unsupported, malformed and duplicate input',
    () {
      final input = <String, Object?>{
        'version': 1,
        'issuer': issuer,
        'clientId': clientId,
        'providers': ['google', 'apple'],
      };
      final parsed = EntraBrokerCapabilities.fromJson(input);
      expect(parsed.providers, [BrokerProvider.google, BrokerProvider.apple]);
      expect(() => parsed.providers.clear(), throwsUnsupportedError);
      for (final invalid in [
        {...input, 'version': 2},
        {...input, 'issuer': 'https://login.microsoftonline.com/tenant/v2.0'},
        {...input, 'issuer': 'https://consumer.ciamlogin.com.evil.test/tenant'},
        {...input, 'issuer': 'http://consumer.ciamlogin.com/tenant'},
        {...input, 'clientId': ' native-public-client'},
        {
          ...input,
          'providers': ['google', 'google'],
        },
        {
          ...input,
          'providers': ['apple', 'untrusted-secret'],
        },
        {...input, 'providers': <String>[]},
        {...input, 'providers': 'google'},
        {...input, 'clientSecret': 'raw-secret'},
      ]) {
        expect(
          () => EntraBrokerCapabilities.fromJson(invalid),
          throwsA(
            authCode('invalid_broker_config').having(
              (error) => error.toString(),
              'redacted configuration error',
              isNot(contains('secret')),
            ),
          ),
        );
      }
    },
  );

  test(
    'capabilities bind exact issuer/client and do not establish identity',
    () {
      final config = configuration(enabled: capabilities());
      final google = config.forBrokerProvider(BrokerProvider.google);
      final apple = config.forBrokerProvider(BrokerProvider.apple);
      expect(google.storageBinding, config.storageBinding);
      expect(apple.storageBinding, config.storageBinding);
      expect(google.apiScopes, config.apiScopes);
      expect(config.brokerProvider, null);
      expect(
        () => OidcConfig(
          issuer: issuer,
          clientId: 'another-client',
          redirectUrl: config.redirectUrl,
          scopes: config.scopes,
          brokerCapabilities: capabilities(),
        ),
        throwsA(authCode('invalid_config')),
      );
      expect(
        () => configuration().forBrokerProvider(BrokerProvider.google),
        throwsA(authCode('provider_unavailable')),
      );
      expect(
        () => configuration(
          enabled: capabilities([BrokerProvider.google]),
        ).forBrokerProvider(BrokerProvider.apple),
        throwsA(authCode('provider_unavailable')),
      );
    },
  );

  group('native browser request', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
    tearDown(() => debugDefaultTargetPlatformOverride = null);
    test(
      'typed hints use the same public client, discovery and API scopes',
      () async {
        final plugin = _AppAuth();
        final native = NativeOidcClient(appAuth: plugin);
        final config = configuration(enabled: capabilities());
        await native.signIn(config);
        expect(plugin.authorization!.additionalParameters, isNull);
        for (final provider in BrokerProvider.values) {
          await native.signIn(config.forBrokerProvider(provider));
          final request = plugin.authorization!;
          expect(request.additionalParameters, {'domain_hint': provider.name});
          expect(request.clientId, config.clientId);
          expect(request.redirectUrl, config.redirectUrl);
          expect(request.discoveryUrl, config.discoveryUrl);
          expect(request.scopes, config.scopes);
          expect(request.clientSecret, null);
          expect(request.allowInsecureConnections, false);
          expect(
            request.externalUserAgent,
            ExternalUserAgent.asWebAuthenticationSession,
          );
          // Even an authorization-only copy cannot leak the hint to refresh.
          await native.refresh(
            config.forBrokerProvider(provider),
            'refresh-secret',
          );
          expect(plugin.refresh!.additionalParameters, isNull);
          expect(plugin.refresh!.scopes, config.scopes);
        }
      },
    );
    test(
      'provider cancellation and native error descriptions remain redacted',
      () async {
        final plugin = _AppAuth();
        final native = NativeOidcClient(appAuth: plugin);
        final config = configuration(
          enabled: capabilities(),
        ).forBrokerProvider(BrokerProvider.apple);
        plugin.failure = FlutterAppAuthUserCancelledException(
          code: 'cancelled',
          message: 'raw-code-secret',
          platformErrorDetails: FlutterAppAuthPlatformErrorDetails(
            error: 'access_denied',
            errorDescription: 'raw-code-secret',
          ),
        );
        await expectLater(
          native.signIn(config),
          throwsA(
            isA<OidcFailure>().having(
              (error) => error.kind,
              'kind',
              OidcFailureKind.cancelled,
            ),
          ),
        );
        plugin.failure = FlutterAppAuthPlatformException(
          code: 'auth_failed',
          message: 'raw-access-secret',
          platformErrorDetails: FlutterAppAuthPlatformErrorDetails(
            error: 'access_denied',
            errorDescription: 'raw-user-email raw-refresh-secret',
          ),
        );
        await expectLater(
          native.signIn(config),
          throwsA(
            isA<OidcFailure>()
                .having((error) => error.kind, 'kind', OidcFailureKind.failed)
                .having(
                  (error) => error.toString(),
                  'safe message',
                  isNot(contains('raw-')),
                ),
          ),
        );
      },
    );
  });

  test(
    'unavailable selection leaves credentials and lifecycle untouched',
    () async {
      final oidc = _Oidc();
      final store = _Store();
      final auth = AuthSessionController(oidc: oidc, tokenStore: store)
        ..configure(
          configuration(enabled: capabilities([BrokerProvider.google])),
        );
      await auth.signIn();
      final binding = auth.credentialSessionId;
      final stored = store.value;
      expect(
        () => auth.signIn(provider: BrokerProvider.apple),
        throwsA(authCode('provider_unavailable')),
      );
      expect(auth.credentialSessionId, binding);
      expect(store.value, stored);
      expect(oidc.signIns.length, 1);
      auth.dispose();
    },
  );

  test(
    'configuring an authorization copy does not persist its navigation intent',
    () async {
      final oidc = _Oidc();
      final store = _Store();
      final auth = AuthSessionController(oidc: oidc, tokenStore: store)
        ..configure(
          configuration(
            enabled: capabilities(),
          ).forBrokerProvider(BrokerProvider.google),
        );
      await auth.signIn();
      expect(auth.config!.brokerProvider, null);
      expect(oidc.signIns.single.brokerProvider, null);
      auth.dispose();
    },
  );

  test(
    'late provider callback after cancellation cannot reopen a cache binding',
    () async {
      final response = Completer<OidcTokens>();
      final launched = Completer<void>();
      final oidc = _Oidc()
        ..action = (_) {
          launched.complete();
          return response.future;
        };
      final store = _Store();
      final auth = AuthSessionController(oidc: oidc, tokenStore: store)
        ..configure(configuration(enabled: capabilities()));
      final signingIn = auth.signIn(provider: BrokerProvider.google);
      final cancelled = expectLater(signingIn, throwsA(authCode('cancelled')));
      await launched.future;
      expect(oidc.signIns.single.brokerProvider, BrokerProvider.google);
      await auth.cancelSignIn();
      response.complete(_tokens());
      await cancelled;
      expect(auth.state, AuthSessionState.signedOut);
      expect(auth.credentialSessionId, null);
      expect(store.value, null);
      auth.dispose();
    },
  );

  test(
    'refresh and restored secure records do not retain a provider hint',
    () async {
      final oidc = _Oidc();
      final store = _Store();
      var now = DateTime.now();
      oidc.clock = () => now;
      oidc.action = (_) async => OidcTokens(
        accessToken: 'api-access',
        refreshToken: 'refresh-secret',
        tokenType: 'Bearer',
        expiresAt: now.add(const Duration(hours: 1)),
      );
      var auth = AuthSessionController(
        oidc: oidc,
        tokenStore: store,
        clock: () => now,
      )..configure(configuration(enabled: capabilities()));
      await auth.signIn(provider: BrokerProvider.apple);
      final binding = auth.credentialSessionId;
      final record = jsonDecode(store.value!) as Map<String, Object?>;
      expect(record['config'], configuration().storageBinding);
      expect(store.value, isNot(contains('domain_hint')));
      expect(store.value, isNot(contains('apple')));
      now = now.add(const Duration(hours: 2));
      await auth.accessToken();
      expect(oidc.refreshes.single.brokerProvider, null);
      expect(auth.credentialSessionId, binding);
      auth.dispose();
      // A navigation rollout is not an identity configuration change.
      auth = AuthSessionController(oidc: oidc, tokenStore: store)
        ..configure(configuration());
      await auth.restore();
      expect(auth.credentialSessionId, binding);
      expect(auth.restoredSession, true);
      auth.dispose();
    },
  );
}

OidcTokens _tokens() => OidcTokens(
  accessToken: 'api-access',
  refreshToken: 'refresh-secret',
  tokenType: 'Bearer',
  expiresAt: DateTime.now().add(const Duration(hours: 4)),
);

class _Oidc implements OidcClient {
  DateTime Function() clock = DateTime.now;
  final signIns = <OidcConfig>[];
  final refreshes = <OidcConfig>[];
  Future<OidcTokens> Function(OidcConfig) action = (_) async => _tokens();
  @override
  Future<OidcTokens> signIn(OidcConfig config) {
    signIns.add(config);
    return action(config);
  }

  @override
  Future<OidcTokens> refresh(OidcConfig config, String refreshToken) async {
    refreshes.add(config);
    return OidcTokens(
      accessToken: 'renewed-api-access',
      refreshToken: 'rotated-refresh',
      tokenType: 'Bearer',
      expiresAt: clock().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<void> endSession(OidcConfig config, String? idToken) async {}
}

class _Store implements RefreshTokenStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
  @override
  Future<void> clear() async => value = null;
}

class _AppAuth extends FlutterAppAuth {
  AuthorizationTokenRequest? authorization;
  TokenRequest? refresh;
  Object? failure;
  @override
  Future<AuthorizationTokenResponse> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  ) async {
    if (failure != null) throw failure!;
    authorization = request;
    return AuthorizationTokenResponse(
      'api-access',
      'refresh-secret',
      DateTime.now().add(const Duration(hours: 1)),
      null,
      'Bearer',
      request.scopes,
      null,
      null,
    );
  }

  @override
  Future<TokenResponse> token(TokenRequest request) async {
    refresh = request;
    return TokenResponse(
      'api-access',
      'refresh-secret',
      DateTime.now().add(const Duration(hours: 1)),
      null,
      'Bearer',
      request.scopes,
      null,
    );
  }
}
