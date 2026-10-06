import 'dart:convert';

import 'package:cosmos_sync_example/auth/oidc.dart';
import 'package:cosmos_sync_example/data/workspace_repository.dart';
import 'package:cosmos_sync_example/ui/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  OidcConfig configuration({
    BrowserAuthAdapter adapter = BrowserAuthAdapter.oidc,
    String? callback,
    bool browser = true,
    EntraBrokerCapabilities? capabilities,
  }) => OidcConfig(
    issuer: 'https://issuer.example.test/realm',
    clientId: 'non-uuid-public-client',
    redirectUrl:
        callback ??
        'https://app.example.test/workspace/'
            '${adapter == BrowserAuthAdapter.entra ? 'auth' : 'oidc'}-redirect.html',
    scopes: ['openid', 'offline_access', 'cosmos_sync'],
    discoveryUrl: 'https://issuer.example.test/discovery',
    browser: browser,
    browserAdapter: adapter,
    brokerCapabilities: capabilities,
  );

  test('generic adapter keeps exact public configuration and its binding', () {
    final config = configuration();
    expect(config.browserAdapter, BrowserAuthAdapter.oidc);
    expect(config.clientId, 'non-uuid-public-client');
    expect(config.discoveryUrl, 'https://issuer.example.test/discovery');
    expect(config.supportsEntraNavigation, false);
    expect(
      config.withBrokerCapabilities(null).storageBinding,
      config.storageBinding,
    );
    expect(
      config.storageBinding,
      isNot(configuration(adapter: BrowserAuthAdapter.entra).storageBinding),
    );
    expect(
      () => config.forBrokerProvider(BrokerProvider.google),
      throwsA(isA<AuthException>()),
    );
  });

  test('adapter-specific bridge and native/browser boundaries fail closed', () {
    for (final callback in [
      'https://app.example.test/workspace/auth-redirect.html',
      'https://app.example.test/workspace/oidc-redirect.html?code=fixture',
      'https://app.example.test/workspace/oidc-redirect.html#response',
      'http://public.example.test/oidc-redirect.html',
    ]) {
      expect(
        () => configuration(callback: callback),
        throwsA(isA<AuthException>()),
      );
    }
    expect(
      () => configuration(
        browser: false,
        callback: 'com.anaregdesign.cosmossync://auth/oauthredirect',
      ),
      throwsA(isA<AuthException>()),
    );
    expect(
      configuration(
        callback: 'http://127.0.0.1:8123/oidc-redirect.html',
      ).browser,
      true,
    );
  });

  test(
    'saved adapter is public and old browser settings retain Entra default',
    () {
      final settings = AppSettings(
        connection: ConnectionConfig(
          bffUri: Uri.parse('https://bff.example.test'),
        ),
        oidc: configuration(),
      );
      final encoded = jsonEncode(settings.toJson());
      final restored = AppSettings.fromJson(
        (jsonDecode(encoded) as Map<String, dynamic>).cast<String, Object?>(),
      );
      expect(restored.oidc.storageBinding, settings.oidc.storageBinding);
      expect(encoded, isNot(contains('refreshToken')));
      expect(encoded, isNot(contains('idToken')));
      expect((settings.toJson()['oidc'] as Map)['browserAdapter'], 'oidc');
      final legacy = AppSettings(
        connection: settings.connection,
        oidc: configuration(adapter: BrowserAuthAdapter.entra),
      );
      expect(
        (legacy.toJson()['oidc'] as Map).containsKey('browserAdapter'),
        false,
      );
      expect(
        AppSettings.fromJson(legacy.toJson()).oidc.browserAdapter,
        BrowserAuthAdapter.entra,
      );
      final corrupted = settings.toJson();
      (corrupted['oidc'] as Map)['browserAdapter'] = 'unknown-adapter';
      expect(() => AppSettings.fromJson(corrupted), throwsArgumentError);
    },
  );
}
