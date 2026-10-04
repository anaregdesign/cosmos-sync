import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'oidc.dart';

/// AppAuth owns state, nonce, PKCE verifier and the external browser callback.
class NativeOidcClient implements OidcClient {
  NativeOidcClient({FlutterAppAuth? appAuth})
    : _appAuth = appAuth ?? const FlutterAppAuth();
  final FlutterAppAuth _appAuth;

  void _checkPlatform() {
    if (kIsWeb ||
        !{
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.macOS,
        }.contains(defaultTargetPlatform)) {
      throw const AuthException(
        'unsupported_platform',
        'Native sign-in supports Android, iOS and macOS.',
      );
    }
  }

  @override
  Future<OidcTokens> signIn(OidcConfig config) async {
    _checkPlatform();
    return _run(
      () async => _convert(
        await _appAuth.authorizeAndExchangeCode(
          AuthorizationTokenRequest(
            config.clientId,
            config.redirectUrl,
            discoveryUrl: config.discoveryUrl,
            scopes: config.scopes,
            additionalParameters: config.brokerProvider == null
                ? null
                : {'domain_hint': config.brokerProvider!.name},
            allowInsecureConnections: false,
            externalUserAgent: ExternalUserAgent.asWebAuthenticationSession,
          ),
        ),
      ),
    );
  }

  @override
  Future<OidcTokens> refresh(OidcConfig config, String refreshToken) async {
    _checkPlatform();
    return _run(
      () async => _convert(
        await _appAuth.token(
          TokenRequest(
            config.clientId,
            config.redirectUrl,
            discoveryUrl: config.discoveryUrl,
            scopes: config.scopes,
            refreshToken: refreshToken,
            allowInsecureConnections: false,
          ),
        ),
      ),
    );
  }

  @override
  Future<void> endSession(OidcConfig config, String? idToken) async {
    _checkPlatform();
    if (config.postLogoutRedirectUrl == null) {
      throw const AuthException(
        'logout_not_configured',
        'Register and configure a provider logout redirect first.',
      );
    }
    await _run(() async {
      await _appAuth.endSession(
        EndSessionRequest(
          idTokenHint: idToken,
          postLogoutRedirectUrl: config.postLogoutRedirectUrl,
          discoveryUrl: config.discoveryUrl,
          externalUserAgent: ExternalUserAgent.asWebAuthenticationSession,
        ),
      );
    });
  }

  static OidcTokens _convert(TokenResponse response) => OidcTokens(
    accessToken: response.accessToken,
    expiresAt: response.accessTokenExpirationDateTime,
    refreshToken: response.refreshToken,
    idToken: response.idToken,
    tokenType: response.tokenType,
    scopes: response.scopes,
  );

  static Future<T> _run<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on FlutterAppAuthUserCancelledException {
      throw const OidcFailure(OidcFailureKind.cancelled);
    } on FlutterAppAuthPlatformException catch (error) {
      // Inspect only structured OAuth codes. Native descriptions may include
      // token responses, authorization codes, account names or redirect URLs.
      final code = error.platformErrorDetails.error;
      if ({
        'invalid_grant',
        'interaction_required',
        'login_required',
        'consent_required',
      }.contains(code)) {
        throw const OidcFailure(OidcFailureKind.interactionRequired);
      }
      if ({'server_error', 'temporarily_unavailable'}.contains(code) ||
          code == null) {
        throw const OidcFailure(OidcFailureKind.transient);
      }
      throw const OidcFailure(OidcFailureKind.failed);
    } catch (_) {
      throw const OidcFailure(OidcFailureKind.failed);
    }
  }
}

/// Refresh credentials never enter preferences, SQLite, diagnostics or backups.
class NativeRefreshTokenStore implements RefreshTokenStore {
  NativeRefreshTokenStore({FlutterSecureStorage? storage, String? key})
    : _key = key ?? storageKey,
      _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
              synchronizable: false,
              accountName: 'cosmos_sync_example.auth',
            ),
            mOptions: MacOsOptions(
              // Local-only macOS sample: avoid Keychain Sharing provisioning.
              usesDataProtectionKeychain: false,
              accessibility: KeychainAccessibility.unlocked_this_device,
              synchronizable: false,
              accountName: 'cosmos_sync_example.auth',
            ),
          );
  static const storageKey = 'cosmos_sync_example.refresh.v1';
  final String _key;
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read() async {
    try {
      return await _storage.read(key: _key);
    } catch (_) {
      throw const AuthException(
        'storage_failed',
        'Secure credentials could not be read. Unlock the device and retry.',
      );
    }
  }

  @override
  Future<void> write(String value) async {
    try {
      await _storage.write(key: _key, value: value);
      if (await read() == value) {
        return;
      }
    } catch (_) {
      // Platform failures and read-back mismatch use the same fixed message.
    }
    throw const AuthException(
      'storage_failed',
      'Secure credential storage could not be verified.',
    );
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
      if (await read() == null) {
        return;
      }
    } catch (_) {
      // Native descriptions are unsafe diagnostics for credential operations.
    }
    throw const AuthException(
      'storage_failed',
      'Secure credentials could not be removed. Retry sign-out.',
    );
  }
}
