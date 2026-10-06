import 'dart:convert';
import 'dart:js_interop';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:web/web.dart' as web;

import 'oidc.dart';

@JS('cosmosSyncAuth.signIn')
external JSPromise<JSString> _signIn(JSString config);
@JS('cosmosSyncAuth.refresh')
external JSPromise<JSString> _refresh(JSString config);
@JS('cosmosSyncAuth.clear')
external JSPromise<JSString> _clear();
@JS('cosmosSyncAuth.endSession')
external JSPromise<JSString> _endSession(JSString config);
@JS('cosmosSyncAuth.freshProof')
external JSPromise<JSString> _freshProof(JSString config, JSString nonce);
@JS('cosmosSyncAuth.cancelProof')
external JSPromise<JSString> _cancelProof();

class WebOidcClient
    implements
        MemoryOidcClient,
        CancellableFreshOidcClient,
        ConfiguredFreshOidcClient {
  @override
  bool supportsFreshIdentityProof(OidcConfig config) =>
      config.browser && config.browserAdapter == BrowserAuthAdapter.entra;

  @override
  Future<OidcTokens> signIn(OidcConfig config) =>
      _tokens(() => _signIn(_encoded(config)).toDart);

  @override
  Future<OidcTokens> refreshCurrent(OidcConfig config) =>
      _tokens(() => _refresh(_encoded(config)).toDart);

  @override
  Future<OidcTokens> refresh(OidcConfig config, String refreshToken) async {
    throw const AuthException(
      'unsupported_refresh',
      'Browser refresh credentials must remain inside the authentication adapter.',
    );
  }

  @override
  Future<void> clearSession() async {
    await _response(() => _clear().toDart);
  }

  @override
  Future<void> endSession(OidcConfig config, String? idToken) async {
    await _response(() => _endSession(_encoded(config)).toDart);
  }

  @override
  Future<FreshIdentityProof> freshIdentityProof(
    OidcConfig config,
    String nonce,
  ) async {
    if (!supportsFreshIdentityProof(config)) {
      throw const AuthException(
        'identity_proof_unavailable',
        'Generic browser sign-in does not support this Entra directory proof profile.',
      );
    }
    validateIdentityNonce(nonce);
    final response = await _response(
      () => _freshProof(_encoded(config), nonce.toJS).toDart,
    );
    try {
      return freshProofFromTokens(
        OidcTokens(
          accessToken: response['accessToken'] as String,
          idToken: response['idToken'] as String,
          expiresAt: DateTime.parse(response['expiresAt'] as String),
          tokenType: response['tokenType'] as String,
          scopes: (response['scopes'] as List).cast<String>(),
        ),
        config,
      );
    } on AuthException {
      rethrow;
    } on Object {
      throw const OidcFailure(OidcFailureKind.failed);
    }
  }

  @override
  Future<void> cancelIdentityProof() async {
    await _response(() => _cancelProof().toDart);
  }

  JSString _encoded(OidcConfig config) {
    if (!config.browser) {
      throw const AuthException(
        'invalid_config',
        'Use the registered browser redirect for Web authentication.',
      );
    }
    return jsonEncode({
      'issuer': config.issuer,
      'clientId': config.clientId,
      'redirectUrl': config.redirectUrl,
      'scopes': config.scopes,
      'discoveryUrl': config.discoveryUrl,
      'postLogoutRedirectUrl': config.postLogoutRedirectUrl,
      'browserAdapter': config.browserAdapter.name,
      if (config.brokerProvider != null)
        'provider': config.brokerProvider!.name,
    }).toJS;
  }

  Future<OidcTokens> _tokens(Future<JSString> Function() action) async {
    final response = await _response(action);
    try {
      final scopes = (response['scopes'] as List).cast<String>();
      return OidcTokens(
        accessToken: response['accessToken'] as String,
        expiresAt: DateTime.parse(response['expiresAt'] as String),
        tokenType: response['tokenType'] as String,
        scopes: scopes,
      );
    } on Object {
      throw const OidcFailure(OidcFailureKind.failed);
    }
  }

  Future<Map<String, dynamic>> _response(
    Future<JSString> Function() action,
  ) async {
    try {
      final raw = (await action()).toDart;
      if (raw.length > 65536) {
        throw const OidcFailure(OidcFailureKind.failed);
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const OidcFailure(OidcFailureKind.failed);
      }
      if (decoded['ok'] != true) {
        throw OidcFailure(switch (decoded['kind']) {
          'cancelled' => OidcFailureKind.cancelled,
          'interactionRequired' => OidcFailureKind.interactionRequired,
          'transient' => OidcFailureKind.transient,
          _ => OidcFailureKind.failed,
        });
      }
      return decoded;
    } on OidcFailure {
      rethrow;
    } on AuthException {
      rethrow;
    } on Object {
      throw const OidcFailure(OidcFailureKind.failed);
    }
  }
}

class MemoryRefreshTokenStore implements RefreshTokenStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> clear() async {}
  @override
  Future<void> write(String value) async {
    throw const AuthException(
      'unsupported_storage',
      'Browser refresh credentials must never enter application storage.',
    );
  }
}

OidcClient createOidcClient() => WebOidcClient();
RefreshTokenStore createTokenStore() => MemoryRefreshTokenStore();
String defaultRedirectUrl({
  BrowserAuthAdapter adapter = BrowserAuthAdapter.entra,
}) => Uri.parse(web.document.baseURI)
    .resolve(
      adapter == BrowserAuthAdapter.entra
          ? 'auth-redirect.html'
          : 'oidc-redirect.html',
    )
    .toString();
