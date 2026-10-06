import 'dart:convert';

import 'package:cosmos_sync/cosmos_sync.dart';

/// A browser navigation preference, never proof of a provider identity.
enum BrokerProvider { google, apple }

/// Build-selected, public External ID provider configuration. The operator must
/// first enable these providers on the native client's associated user flow.
class EntraBrokerCapabilities {
  factory EntraBrokerCapabilities.fromJsonString(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      return EntraBrokerCapabilities.fromJson(decoded);
    } catch (_) {
      throw const AuthException(
        'invalid_broker_config',
        'Check the public External ID provider configuration.',
      );
    }
  }

  factory EntraBrokerCapabilities({
    required String issuer,
    required String clientId,
    required List<BrokerProvider> providers,
  }) {
    final uri = OidcConfig._httpsUri(issuer);
    if (!uri.host.endsWith('.ciamlogin.com') ||
        uri.path.isEmpty ||
        uri.path == '/' ||
        clientId.isEmpty ||
        clientId != clientId.trim() ||
        providers.isEmpty ||
        providers.toSet().length != providers.length) {
      throw const AuthException(
        'invalid_broker_config',
        'Check the External ID issuer, native client and enabled providers.',
      );
    }
    return EntraBrokerCapabilities._(
      issuer,
      clientId,
      List<BrokerProvider>.unmodifiable(providers),
    );
  }

  factory EntraBrokerCapabilities.fromJson(Map<String, Object?> json) {
    try {
      if (json['version'] != 1 ||
          json.keys.toSet().difference({
            'version',
            'issuer',
            'clientId',
            'providers',
          }).isNotEmpty) {
        throw const FormatException();
      }
      return EntraBrokerCapabilities(
        issuer: json['issuer'] as String,
        clientId: json['clientId'] as String,
        providers: (json['providers'] as List)
            .map((value) => BrokerProvider.values.byName(value as String))
            .toList(growable: false),
      );
    } catch (_) {
      throw const AuthException(
        'invalid_broker_config',
        'Check the public External ID provider configuration.',
      );
    }
  }

  const EntraBrokerCapabilities._(this.issuer, this.clientId, this.providers);
  final String issuer;
  final String clientId;
  final List<BrokerProvider> providers;

  bool matches({required String issuer, required String clientId}) =>
      this.issuer == issuer && this.clientId == clientId;
}

/// Public client configuration. There is deliberately no client secret.
class OidcConfig {
  factory OidcConfig({
    required String issuer,
    required String clientId,
    required String redirectUrl,
    required List<String> scopes,
    String? discoveryUrl,
    String? postLogoutRedirectUrl,
    EntraBrokerCapabilities? brokerCapabilities,
    bool browser = false,
  }) {
    final issuerUri = _httpsUri(issuer);
    final discovery =
        discoveryUrl ??
        '${issuer.endsWith('/') ? issuer.substring(0, issuer.length - 1) : issuer}/.well-known/openid-configuration';
    final discoveryUri = _httpsUri(discovery);
    if (issuerUri.origin != discoveryUri.origin ||
        clientId.trim().isEmpty ||
        clientId != clientId.trim() ||
        (brokerCapabilities != null &&
            !brokerCapabilities.matches(issuer: issuer, clientId: clientId))) {
      throw const AuthException(
        'invalid_config',
        'Check the provider and client configuration.',
      );
    }
    browser ? _browserCallbackUri(redirectUrl) : _callbackUri(redirectUrl);
    if (postLogoutRedirectUrl != null) {
      browser
          ? _browserCallbackUri(postLogoutRedirectUrl)
          : _callbackUri(postLogoutRedirectUrl);
    }
    final copiedScopes = List<String>.unmodifiable(scopes);
    if (!copiedScopes.contains('openid') ||
        !copiedScopes.any((scope) => !_identityScopes.contains(scope)) ||
        copiedScopes.any(
          (scope) => scope.isEmpty || RegExp(r'\s').hasMatch(scope),
        ) ||
        copiedScopes.toSet().length != copiedScopes.length) {
      throw const AuthException(
        'invalid_config',
        'Request openid and a delegated scope for the BFF API.',
      );
    }
    return OidcConfig._(
      issuer,
      clientId,
      redirectUrl,
      copiedScopes,
      discovery,
      postLogoutRedirectUrl,
      brokerCapabilities,
      null,
      browser,
    );
  }

  const OidcConfig._(
    this.issuer,
    this.clientId,
    this.redirectUrl,
    this.scopes,
    this.discoveryUrl,
    this.postLogoutRedirectUrl,
    this.brokerCapabilities,
    this.brokerProvider,
    this.browser,
  );

  final String issuer;
  final String clientId;
  final String redirectUrl;
  final List<String> scopes;
  final String discoveryUrl;
  final String? postLogoutRedirectUrl;
  final EntraBrokerCapabilities? brokerCapabilities;

  /// Ephemeral authorization-request intent. Excluded from credential/cache
  /// bindings and never forwarded to refresh, logout or BFF requests.
  final BrokerProvider? brokerProvider;
  final bool browser;

  OidcConfig withBrokerCapabilities(EntraBrokerCapabilities? capabilities) =>
      OidcConfig(
        issuer: issuer,
        clientId: clientId,
        redirectUrl: redirectUrl,
        scopes: scopes,
        discoveryUrl: discoveryUrl,
        postLogoutRedirectUrl: postLogoutRedirectUrl,
        brokerCapabilities: capabilities,
        browser: browser,
      );

  OidcConfig forBrokerProvider(BrokerProvider provider) {
    if (!(brokerCapabilities?.providers.contains(provider) ?? false)) {
      throw const AuthException(
        'provider_unavailable',
        'This sign-in provider is not enabled for this application.',
      );
    }
    return OidcConfig._(
      issuer,
      clientId,
      redirectUrl,
      scopes,
      discoveryUrl,
      postLogoutRedirectUrl,
      brokerCapabilities,
      provider,
      browser,
    );
  }

  List<String> get apiScopes => scopes
      .where((scope) => !_identityScopes.contains(scope))
      .toList(growable: false);

  /// Exact non-secret configuration binding; not a verified user identity.
  String get storageBinding => jsonEncode([
    issuer,
    clientId,
    redirectUrl,
    scopes,
    discoveryUrl,
    postLogoutRedirectUrl,
    if (browser) 'browser',
  ]);

  static const _identityScopes = {
    'openid',
    'profile',
    'email',
    'offline_access',
    'address',
    'phone',
  };

  static Uri _httpsUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const AuthException(
        'invalid_config',
        'The OIDC provider must use HTTPS without embedded credentials.',
      );
    }
    return uri;
  }

  static void _callbackUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        value.split(':').first != uri.scheme ||
        RegExp(r'\s').hasMatch(value) ||
        !RegExp(r'^[a-z][a-z0-9+.-]*\.[a-z0-9+.-]+$').hasMatch(uri.scheme) ||
        {'http', 'https', 'file', 'javascript', 'data'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path.isEmpty) {
      throw const AuthException(
        'invalid_config',
        'Use the registered lowercase native redirect scheme and path.',
      );
    }
  }

  static void _browserCallbackUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        RegExp(r'\s').hasMatch(value) ||
        !uri.path.endsWith('/auth-redirect.html') ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                {'localhost', '127.0.0.1', '::1'}.contains(uri.host)))) {
      throw const AuthException(
        'invalid_config',
        'Use the registered same-origin browser redirect bridge.',
      );
    }
  }
}

/// Only fixed application messages cross the UI/log boundary.
class AuthException implements Exception {
  const AuthException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'AuthException($code): $message';
}

enum OidcFailureKind { cancelled, interactionRequired, transient, failed }

class OidcFailure implements Exception {
  const OidcFailure(this.kind);
  final OidcFailureKind kind;
  @override
  String toString() => 'OidcFailure(${kind.name})';
}

class OidcTokens {
  const OidcTokens({
    this.accessToken,
    this.expiresAt,
    this.refreshToken,
    this.idToken,
    this.tokenType,
    this.scopes,
  });
  final String? accessToken;
  final DateTime? expiresAt;
  final String? refreshToken;

  /// Optional provider logout hint; never an API credential or cache owner.
  final String? idToken;
  final String? tokenType;
  final List<String>? scopes;
  @override
  String toString() => 'OidcTokens([redacted])';
}

abstract interface class OidcClient {
  Future<OidcTokens> signIn(OidcConfig config);
  Future<OidcTokens> refresh(OidcConfig config, String refreshToken);
  Future<void> endSession(OidcConfig config, String? idToken);
}

/// An isolated interactive proof; it must not replace the main credentials.
abstract interface class FreshOidcClient implements OidcClient {
  Future<FreshIdentityProof> freshIdentityProof(
    OidcConfig config,
    String nonce,
  );
}

/// Browser clients can additionally clear an isolated proof's private cache.
abstract interface class CancellableFreshOidcClient implements FreshOidcClient {
  Future<void> cancelIdentityProof();
}

void validateIdentityNonce(String nonce) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(nonce)) {
    throw const AuthException(
      'invalid_identity_challenge',
      'Use a fresh challenge from the configured BFF.',
    );
  }
}

FreshIdentityProof freshProofFromTokens(OidcTokens tokens, OidcConfig config) {
  if (tokens.accessToken == null ||
      tokens.idToken == null ||
      tokens.expiresAt == null ||
      !tokens.expiresAt!.isAfter(
        DateTime.now().add(const Duration(seconds: 30)),
      ) ||
      tokens.tokenType?.toLowerCase() != 'bearer' ||
      tokens.scopes != null &&
          config.apiScopes.any((scope) => !tokens.scopes!.contains(scope))) {
    throw const AuthException(
      'invalid_proof_response',
      'The provider did not return an API and ID proof. Reauthenticate online.',
    );
  }
  try {
    return FreshIdentityProof(
      accessToken: tokens.accessToken!,
      idToken: tokens.idToken!,
    );
  } on FormatException {
    throw const AuthException(
      'invalid_proof_response',
      'The provider did not return a usable identity proof.',
    );
  }
}

/// A browser SDK owns its in-memory refresh credential; it is never exported.
abstract interface class MemoryOidcClient implements OidcClient {
  Future<OidcTokens> refreshCurrent(OidcConfig config);
  Future<void> clearSession();
}

/// A single replaceable secure record. Implementations must fail on failed writes.
abstract interface class RefreshTokenStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}
