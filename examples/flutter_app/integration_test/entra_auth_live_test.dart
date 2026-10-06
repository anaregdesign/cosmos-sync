import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:cosmos_sync_example/auth/auth_session_controller.dart';
import 'package:cosmos_sync_example/auth/native_oidc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/owner_auth_binding.dart';
import 'support/owner_auth_gate.dart';

/// Owner-assisted actual-provider target, separate from ordinary application UI.
/// Only public configuration and a capability-bound loopback URL are supplied by
/// the host runner. No token, tenant account, or secret enters a dart-define.
void main() {
  const manualStart = bool.fromEnvironment('COSMOS_SYNC_ENTRA_MANUAL_START');
  configureOwnerAuthBinding(
    IntegrationTestWidgetsFlutterBinding.ensureInitialized(),
    manualStart: manualStart,
  );
  testWidgets(
    'owner-assisted Entra PKCE, secure restore, refresh and local signout',
    (tester) async {
      const endpoint = String.fromEnvironment('COSMOS_SYNC_ENTRA_CONTROL_URL');
      const isolatedSignIn = bool.fromEnvironment(
        'COSMOS_SYNC_ENTRA_ISOLATED_SIGN_IN',
      );
      final control = _Control(Uri.parse(endpoint));
      final ownerReady = Completer<void>();
      await tester.pumpWidget(
        manualStart
            ? OwnerAuthGate(onStart: ownerReady.complete)
            : const MaterialApp(
                home: Scaffold(
                  body: Center(
                    child: Text(
                      'Microsoft sign-in validation\n'
                      'Use your own system browser window.\n'
                      'Approve only Cosmos Sync document access.\n'
                      'Credentials stay with Microsoft; no token is shown here.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
      );
      var completed = false;
      await tester.runAsync(() async {
        final settings = await control.configuration();
        final config = OidcConfig(
          issuer: settings['issuer'] as String,
          clientId: settings['clientId'] as String,
          redirectUrl: settings['redirectUrl'] as String,
          scopes: (settings['scopes'] as List).cast<String>(),
          discoveryUrl: settings['discoveryUrl'] as String?,
        );
        final store = NativeRefreshTokenStore(key: control.storeKey);
        AuthSessionController? current;
        try {
          // This isolated key is unrelated to ordinary app credentials.
          await store.clear();
          current = AuthSessionController(
            oidc: NativeOidcClient(freshInteractiveSession: isolatedSignIn),
            tokenStore: store,
          );
          current.configure(config);
          if (manualStart) {
            await control.stage('owner_start_ready');
            await ownerReady.future;
            _require(
              WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed,
            );
          }
          await control.stage('browser_request_started');
          debugPrint('COSMOS_SYNC_ENTRA_BROWSER_REQUEST_STARTED');
          await current.signIn();
          await control.stage('native_callback_received');
          final binding = current.credentialSessionId;
          _require(current.hasStoredSession && binding != null);
          await control.capture('initial', await current.accessToken());
          if (control.directoryProof) {
            final challenge = await control.challenge();
            await control.stage('directory_challenge_received');
            _require(
              WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed,
            );
            final saved = await store.read();
            await control.stage('fresh_browser_request_started');
            final proof = await current.freshIdentityProof(challenge);
            await control.stage('fresh_callback_received');
            _require(
              current.credentialSessionId == binding &&
                  await store.read() == saved,
            );
            await control.proof(proof);
            await control.stage('fresh_proof_verified');
          }

          // A new controller has no RAM access token. Restoration reads the real
          // OS secure store, and its next token call performs provider refresh.
          // This is controller recreation, not proof of OS process restart.
          current.dispose();
          current = AuthSessionController(
            oidc: NativeOidcClient(freshInteractiveSession: isolatedSignIn),
            tokenStore: store,
          );
          current.configure(config);
          await current.restore();
          _require(
            current.restoredSession &&
                current.hasStoredSession &&
                current.credentialSessionId == binding,
          );
          await control.stage('secure_restore_complete');
          await control.capture('refresh', await current.accessToken());
          await control.stage('refresh_complete');

          await current.signOut();
          _require(!current.isSignedIn && await store.read() == null);
          await control.stage('local_signout_complete');
          completed = true;
          debugPrint(
            'COSMOS_SYNC_ENTRA_NATIVE_PASS '
            'provider=actual pkce=native secureRestore=true '
            'refresh=true localSignout=true processRestart=unverified',
          );
        } finally {
          try {
            if (current != null) {
              await current.signOut();
            }
          } finally {
            current?.dispose();
            await store.clear();
          }
        }
      });
      expect(completed, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

void _require(bool condition) {
  if (!condition) {
    throw StateError('Native authentication lifecycle validation failed.');
  }
}

class _Control {
  _Control(this.base) {
    if (base.scheme != 'http' ||
        base.host != '127.0.0.1' ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        !base.path.endsWith('/') ||
        base.pathSegments.where((segment) => segment.isNotEmpty).isEmpty) {
      throw StateError('Use the private loopback Entra validation runner.');
    }
  }

  final Uri base;
  String? _storeKey;
  bool directoryProof = false;
  String get storeKey =>
      _storeKey ?? (throw StateError('Validation configuration is not ready.'));

  Future<Map<String, Object?>> configuration() async {
    final result = await _request('GET', 'config');
    if (!{1, 2}.contains(result['protocolVersion']) ||
        result['protocolVersion'] == 2 &&
            result['proofMode'] != 'directory-register-v1' ||
        result['nativeConfig'] is! Map ||
        result['storeKey'] is! String ||
        !(result['storeKey'] as String).startsWith(
          'cosmos_sync_example.auth_live.',
        )) {
      throw StateError('Validation configuration is invalid.');
    }
    _storeKey = result['storeKey'] as String;
    directoryProof = result['protocolVersion'] == 2;
    return (result['nativeConfig'] as Map).cast<String, Object?>();
  }

  Future<void> capture(String phase, String token) async {
    if (!{'initial', 'refresh'}.contains(phase) || token.isEmpty) {
      throw StateError('Validation token phase is invalid.');
    }
    await _request('POST', 'token', {'phase': phase, 'accessToken': token});
  }

  Future<void> stage(String value) async {
    await _request('POST', 'stage', {'stage': value});
  }

  Future<IdentityChallenge> challenge() async =>
      IdentityChallenge.fromJson(await _request('POST', 'challenge', {}));

  Future<void> proof(FreshIdentityProof proof) async {
    final result = await _request('POST', 'proof', proof.toJson());
    if (result['freshAuthenticationVerified'] != true ||
        result['directoryRegistrationVerified'] != true) {
      throw StateError('Directory authentication proof was not accepted.');
    }
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await http.openUrl(method, base.resolve(path));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        final encoded = utf8.encode(jsonEncode(body));
        request.contentLength = encoded.length;
        request.add(encoded);
      }
      final response = await request.close().timeout(
        Duration(seconds: directoryProof ? 90 : 15),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('Private validation control request failed.');
      }
      final value = await utf8.decoder.bind(response).join();
      if (value.length > 16 * 1024) {
        throw StateError('Private validation response is too large.');
      }
      return (jsonDecode(value) as Map).cast<String, Object?>();
    } catch (_) {
      // Native/provider/HTTP errors can contain credentials or account details.
      throw StateError('Private validation control request failed.');
    } finally {
      http.close(force: true);
    }
  }
}
