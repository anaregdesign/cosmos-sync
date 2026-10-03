import 'dart:convert';

/// Public native-client configuration. There is deliberately no client secret.
class OidcConfig {
  factory OidcConfig({
    required String issuer,
    required String clientId,
    required String redirectUrl,
    required List<String> scopes,
    String? discoveryUrl,
    String? postLogoutRedirectUrl,
  }) {
    final issuerUri = _httpsUri(issuer);
    final discovery =
        discoveryUrl ??
        '${issuer.endsWith('/') ? issuer.substring(0, issuer.length - 1) : issuer}/.well-known/openid-configuration';
    final discoveryUri = _httpsUri(discovery);
    if (issuerUri.origin != discoveryUri.origin ||
        clientId.trim().isEmpty ||
        clientId != clientId.trim()) {
      throw const AuthException(
        'invalid_config',
        'Check the provider and client configuration.',
      );
    }
    _callbackUri(redirectUrl);
    if (postLogoutRedirectUrl != null) {
      _callbackUri(postLogoutRedirectUrl);
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
    );
  }

  const OidcConfig._(
    this.issuer,
    this.clientId,
    this.redirectUrl,
    this.scopes,
    this.discoveryUrl,
    this.postLogoutRedirectUrl,
  );

  final String issuer;
  final String clientId;
  final String redirectUrl;
  final List<String> scopes;
  final String discoveryUrl;
  final String? postLogoutRedirectUrl;

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

/// A single replaceable secure record. Implementations must fail on failed writes.
abstract interface class RefreshTokenStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}
