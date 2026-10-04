@TestOn('browser')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:cosmos_sync_example/auth/oidc.dart';
import 'package:cosmos_sync_example/auth/web_oidc.dart';
import 'package:flutter_test/flutter_test.dart';

@JS()
external JSObject get globalThis;

void main() {
  final config = OidcConfig(
    issuer:
        'https://example.ciamlogin.com/11111111-1111-4111-8111-111111111111/v2.0',
    clientId: '22222222-2222-4222-8222-222222222222',
    redirectUrl: 'https://app.example.test/auth-redirect.html',
    scopes: ['openid', 'offline_access', 'api://bff/Cosmos.Sync'],
    browser: true,
  );
  late WebOidcClient client;
  late Map<String, dynamic> lastConfig;
  late String response;
  late JSAny? previous;
  var clears = 0;
  var renewals = 0;

  setUp(() {
    previous = globalThis.getProperty<JSAny?>('cosmosSyncAuth'.toJS);
    clears = 0;
    renewals = 0;
    response = jsonEncode({
      'ok': true,
      'accessToken': 'fixture-api-token',
      'tokenType': 'Bearer',
      'scopes': ['api://bff/Cosmos.Sync'],
      'expiresAt': DateTime.now()
          .add(const Duration(hours: 1))
          .toIso8601String(),
      'refreshToken': 'fixture-private-refresh-must-not-be-exported',
      'idToken': 'fixture-id-must-not-be-an-api-token',
    });
    final bridge = JSObject();
    JSPromise<JSString> result(JSString value) {
      lastConfig = jsonDecode(value.toDart) as Map<String, dynamic>;
      return Future<JSString>.value(response.toJS).toJS;
    }

    bridge.setProperty('signIn'.toJS, result.toJS);
    bridge.setProperty(
      'refresh'.toJS,
      ((JSString value) {
        renewals++;
        return result(value);
      }).toJS,
    );
    bridge.setProperty(
      'clear'.toJS,
      (() {
        clears++;
        return Future<JSString>.value('{"ok":true}'.toJS).toJS;
      }).toJS,
    );
    bridge.setProperty('endSession'.toJS, result.toJS);
    globalThis.setProperty('cosmosSyncAuth'.toJS, bridge);
    client = WebOidcClient();
  });
  tearDown(() => globalThis.setProperty('cosmosSyncAuth'.toJS, previous));

  test(
    'actual JavaScript interop exports only the API access credential',
    () async {
      final tokens = await client.signIn(config);
      expect(tokens.accessToken, 'fixture-api-token');
      expect(tokens.refreshToken, null);
      expect(tokens.idToken, null);
      expect(tokens.scopes, ['api://bff/Cosmos.Sync']);
      expect(lastConfig['clientId'], config.clientId);
      expect(lastConfig['redirectUrl'], config.redirectUrl);
      expect(lastConfig['discoveryUrl'], config.discoveryUrl);
      await client.refreshCurrent(config);
      expect(renewals, 1);
      await client.clearSession();
      expect(clears, 1);
      await expectLater(
        client.refresh(config, 'never-export-a-refresh-token'),
        throwsA(isA<AuthException>()),
      );
    },
  );

  test(
    'denied, malformed and oversized responses expose fixed failures only',
    () async {
      for (final value in [
        '{"ok":false,"kind":"interactionRequired","message":"fixture-private-detail"}',
        'fixture-private-malformed-response',
        '{"ok":true,"accessToken":"fixture","expiresAt":"invalid"}',
        'x' * 65537,
      ]) {
        response = value;
        try {
          await client.signIn(config);
          fail('Invalid bridge response must fail.');
        } on OidcFailure catch (error) {
          expect(error.toString(), isNot(contains('fixture-private')));
        }
      }
    },
  );

  test(
    'native configuration and persistent refresh storage fail explicitly',
    () async {
      final native = OidcConfig(
        issuer: config.issuer,
        clientId: config.clientId,
        redirectUrl: 'com.anaregdesign.cosmossync://auth/oauthredirect',
        scopes: config.scopes,
      );
      await expectLater(client.signIn(native), throwsA(isA<AuthException>()));
      final store = MemoryRefreshTokenStore();
      expect(await store.read(), null);
      await expectLater(
        store.write('fixture-private-token'),
        throwsA(isA<AuthException>()),
      );
      await store.clear();
    },
  );
}
