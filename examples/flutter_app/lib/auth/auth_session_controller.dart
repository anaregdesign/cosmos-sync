import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:flutter/foundation.dart';

import 'native_oidc.dart'
    if (dart.library.js_interop) 'web_oidc.dart'
    as platform;
import 'oidc.dart';

export 'oidc.dart';

enum AuthSessionState {
  unconfigured,
  signedOut,
  authorizing,
  refreshing,
  provingIdentity,
  ready,
  signingOut,
  error,
}

/// A credential lifecycle, not a source of identity or authorization claims.
/// Only an authenticated BFF session may establish an offline cache owner.
class AuthSessionController extends ChangeNotifier {
  AuthSessionController({
    OidcClient? oidc,
    RefreshTokenStore? tokenStore,
    DateTime Function()? clock,
  }) : _oidc = oidc ?? platform.createOidcClient(),
       _store = tokenStore ?? platform.createTokenStore(),
       _clock = clock ?? DateTime.now;

  final OidcClient _oidc;
  final RefreshTokenStore _store;
  final DateTime Function() _clock;
  OidcConfig? _config;
  AuthSessionState _state = AuthSessionState.unconfigured;
  AuthException? _error;
  String? _accessToken;
  DateTime? _expiresAt;
  String? _refreshToken;
  String? _idToken;
  String? _credentialSessionId;
  bool _restoredSession = false;
  bool _disposed = false;
  int _generation = 0;
  int _proofGeneration = 0;
  Future<void> _storeTail = Future<void>.value();
  Future<void>? _restoreFlight;
  Future<void>? _signInFlight;
  Future<String>? _refreshFlight;
  Future<FreshIdentityProof>? _proofFlight;

  OidcConfig? get config => _config;
  AuthSessionState get state => _state;
  AuthException? get error => _error;
  bool get isSignedIn => _credentialSessionId != null;
  bool get hasStoredSession =>
      _credentialSessionId != null && _refreshToken != null;
  bool get restoredSession => _restoredSession;
  bool get supportsCredentialRestore => _oidc is! MemoryOidcClient;
  String? get credentialSessionId => _credentialSessionId;
  bool get supportsFreshIdentityProof => _oidc is FreshOidcClient;

  void configure(OidcConfig config) {
    _checkDisposed();
    if (_signInFlight != null ||
        _restoreFlight != null ||
        _refreshFlight != null ||
        _proofFlight != null ||
        isSignedIn ||
        _state == AuthSessionState.signingOut) {
      throw const AuthException(
        'auth_busy',
        'Sign out before changing the provider configuration.',
      );
    }
    _generation++;
    // Navigation intent belongs to one authorization request, not a session.
    _config = config.withBrokerCapabilities(config.brokerCapabilities);
    _forgetCredentials();
    _setState(AuthSessionState.signedOut);
  }

  /// Restores a secure refresh credential without contacting the provider.
  /// `ready` does not imply current server grants: cache authority is a separate,
  /// previously BFF-verified binding owned by the application.
  Future<void> restore() {
    final config = _requireConfig();
    if (_state != AuthSessionState.signedOut ||
        _restoreFlight != null ||
        _signInFlight != null ||
        _refreshFlight != null ||
        _proofFlight != null) {
      return Future.error(
        const AuthException(
          'auth_busy',
          'Restore credentials only at a signed-out app startup.',
        ),
      );
    }
    final generation = _generation;
    final completion = Completer<void>();
    final future = completion.future;
    _restoreFlight = future;
    unawaited(
      _performRestore(config, generation).then<void>(
        (_) {
          if (identical(_restoreFlight, future)) {
            _restoreFlight = null;
          }
          completion.complete();
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_restoreFlight, future)) {
            _restoreFlight = null;
          }
          completion.completeError(error, stackTrace);
        },
      ),
    );
    return future;
  }

  Future<void> _performRestore(OidcConfig config, int generation) async {
    try {
      if (_oidc is MemoryOidcClient) {
        await _clearCredentials();
        _ensureCurrent(generation);
        return;
      }
      final value = await _queuedStore(_store.read);
      _ensureCurrent(generation);
      if (value == null) {
        return;
      }
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['config'] != config.storageBinding ||
          !_nonEmpty(decoded['refreshToken']) ||
          decoded['credentialSessionId'] is! String ||
          !RegExp(
            r'^[A-Za-z0-9_-]{32}$',
          ).hasMatch(decoded['credentialSessionId'] as String) ||
          (decoded['idToken'] != null && decoded['idToken'] is! String)) {
        await _clearCredentials();
        _ensureCurrent(generation);
        return;
      }
      _refreshToken = decoded['refreshToken'] as String;
      _idToken = decoded['idToken'] as String?;
      _credentialSessionId = decoded['credentialSessionId'] as String;
      _restoredSession = true;
      _setState(AuthSessionState.ready);
    } catch (error) {
      _ensureCurrent(generation);
      _forgetCredentials();
      if (error is FormatException) {
        await _clearCredentials();
        _ensureCurrent(generation);
        _setState(AuthSessionState.signedOut);
        return;
      }
      final safe = const AuthException(
        'storage_failed',
        'Secure credentials could not be restored. Unlock the device and retry.',
      );
      _setState(AuthSessionState.error, safe);
      throw safe;
    }
  }

  Future<void> signIn({BrokerProvider? provider}) {
    final configured = _requireConfig();
    final config = provider == null
        ? configured
        : configured.forBrokerProvider(provider);
    if (_signInFlight != null ||
        _restoreFlight != null ||
        _proofFlight != null ||
        _state == AuthSessionState.signingOut) {
      return Future.error(
        const AuthException(
          'auth_busy',
          'Finish the current browser sign-in first.',
        ),
      );
    }
    final generation = ++_generation;
    _forgetCredentials();
    // Publish before notifying: a listener may synchronously request sign-in.
    final completion = Completer<void>();
    final future = completion.future;
    _signInFlight = future;
    _setState(AuthSessionState.authorizing);
    unawaited(
      _performSignIn(config, generation).then<void>(
        (_) {
          if (identical(_signInFlight, future)) {
            _signInFlight = null;
          }
          completion.complete();
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_signInFlight, future)) {
            _signInFlight = null;
          }
          completion.completeError(error, stackTrace);
        },
      ),
    );
    return future;
  }

  Future<void> _performSignIn(OidcConfig config, int generation) async {
    try {
      // An interrupted account switch must never restore the prior credentials.
      await _clearCredentials();
      _ensureCurrent(generation);
      final tokens = await _oidc.signIn(config);
      _ensureCurrent(generation);
      _validateTokens(tokens, config);
      final binding = base64Url
          .encode(List<int>.generate(24, (_) => Random.secure().nextInt(256)))
          .replaceAll('=', '');
      await _persist(config, tokens.refreshToken, tokens.idToken, binding);
      _ensureCurrent(generation);
      _adopt(tokens, binding);
      _setState(AuthSessionState.ready);
    } catch (error) {
      if (!_isCurrent(generation)) {
        throw const AuthException('cancelled', 'Sign-in was cancelled.');
      }
      if (_oidc is MemoryOidcClient) {
        try {
          await _clearCredentials();
        } catch (_) {
          _ensureCurrent(generation);
          _forgetCredentials();
          final safe = const AuthException(
            'storage_failed',
            'Browser credentials could not be removed. Retry sign-out.',
          );
          _setState(AuthSessionState.error, safe);
          throw safe;
        }
        _ensureCurrent(generation);
      }
      _forgetCredentials();
      if (error is OidcFailure && error.kind == OidcFailureKind.cancelled) {
        _setState(AuthSessionState.signedOut);
        throw const AuthException('cancelled', 'Sign-in was cancelled.');
      }
      final safe = error is AuthException
          ? error
          : const AuthException(
              'sign_in_failed',
              'Sign-in failed. Check the connection and registered provider settings.',
            );
      _setState(AuthSessionState.error, safe);
      throw safe;
    }
  }

  /// Invalidates late callbacks; close the authentication browser to dismiss it.
  Future<void> cancelSignIn() async {
    _checkDisposed();
    if (_state != AuthSessionState.authorizing) {
      return;
    }
    final generation = ++_generation;
    _forgetCredentials();
    _setState(AuthSessionState.signedOut);
    try {
      await _clearCredentials();
      _ensureCurrent(generation);
    } catch (_) {
      _ensureCurrent(generation);
      final safe = const AuthException(
        'storage_failed',
        'Cancelled sign-in credentials could not be removed. Retry sign-out.',
      );
      _setState(AuthSessionState.error, safe);
      throw safe;
    }
  }

  Future<String> accessToken() {
    final config = _requireConfig();
    if (_state == AuthSessionState.authorizing ||
        _state == AuthSessionState.signingOut ||
        _proofFlight != null) {
      return Future.error(
        const AuthException(
          'auth_busy',
          'Authentication is changing. Try again after it finishes.',
        ),
      );
    }
    if (_credentialSessionId == null) {
      return Future.error(
        const AuthException(
          'sign_in_required',
          'Sign in before connecting to the BFF.',
        ),
      );
    }
    if (_accessToken != null &&
        _expiresAt!.isAfter(_clock().add(const Duration(seconds: 30)))) {
      return Future.value(_accessToken);
    }
    if (_refreshFlight != null) {
      return _refreshFlight!;
    }
    if (_refreshToken == null && _oidc is! MemoryOidcClient) {
      _forgetCredentials();
      final safe = const AuthException(
        'sign_in_required',
        'The session expired. Sign in again.',
      );
      _setState(AuthSessionState.signedOut, safe);
      return Future.error(safe);
    }
    final generation = _generation;
    final refreshToken = _refreshToken;
    final binding = _credentialSessionId!;
    // A refreshing listener can ask for a token before _performRefresh returns.
    final completion = Completer<String>();
    final future = completion.future;
    _refreshFlight = future;
    unawaited(
      _performRefresh(config, generation, refreshToken, binding).then<void>(
        (token) {
          if (identical(_refreshFlight, future)) {
            _refreshFlight = null;
          }
          completion.complete(token);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_refreshFlight, future)) {
            _refreshFlight = null;
          }
          completion.completeError(error, stackTrace);
        },
      ),
    );
    return future;
  }

  Future<FreshIdentityProof> freshIdentityProof(IdentityChallenge challenge) {
    final config = _requireConfig();
    final client = _oidc;
    if (client is! FreshOidcClient) {
      return Future.error(
        const AuthException(
          'identity_proof_unavailable',
          'This authentication adapter cannot obtain a fresh identity proof.',
        ),
      );
    }
    if (!isSignedIn ||
        _proofFlight != null ||
        _signInFlight != null ||
        _restoreFlight != null ||
        _refreshFlight != null ||
        _state == AuthSessionState.signingOut) {
      return Future.error(
        const AuthException(
          'auth_busy',
          'Finish authentication before requesting an identity proof.',
        ),
      );
    }
    if (!challenge.target.matchesClient(
          config.issuer,
          config.clientId,
          config.redirectUrl,
        ) ||
        !challenge.expiresAt.isAfter(_clock().toUtc())) {
      return Future.error(
        const AuthException(
          'invalid_identity_challenge',
          'The challenge is expired or does not match this configured client.',
        ),
      );
    }
    final generation = _generation;
    final proofGeneration = ++_proofGeneration;
    final completion = Completer<FreshIdentityProof>();
    final future = completion.future;
    _proofFlight = future;
    _setState(AuthSessionState.provingIdentity);
    unawaited(
      _performIdentityProof(
        client,
        config,
        challenge,
        generation,
        proofGeneration,
      ).then<void>(
        (proof) {
          if (identical(_proofFlight, future)) _proofFlight = null;
          if (_isProofCurrent(generation, proofGeneration)) {
            _setState(AuthSessionState.ready);
          }
          completion.complete(proof);
        },
        onError: (Object error, StackTrace stack) {
          if (identical(_proofFlight, future)) _proofFlight = null;
          if (_isProofCurrent(generation, proofGeneration)) {
            _setState(
              AuthSessionState.ready,
              error is AuthException
                  ? error
                  : const AuthException(
                      'identity_proof_failed',
                      'Identity authentication failed. No proof was submitted.',
                    ),
            );
          }
          completion.completeError(error, stack);
        },
      ),
    );
    return future;
  }

  Future<FreshIdentityProof> _performIdentityProof(
    FreshOidcClient client,
    OidcConfig config,
    IdentityChallenge challenge,
    int generation,
    int proofGeneration,
  ) async {
    try {
      _ensureProofCurrent(generation, proofGeneration);
      final proof = await client.freshIdentityProof(
        config,
        challenge.challenge,
      );
      _ensureProofCurrent(generation, proofGeneration);
      if (!challenge.expiresAt.isAfter(_clock().toUtc())) {
        throw const AuthException(
          'invalid_identity_challenge',
          'The challenge expired. Start a new online operation.',
        );
      }
      return proof;
    } catch (error) {
      _ensureProofCurrent(generation, proofGeneration);
      if (error is AuthException) rethrow;
      throw error is OidcFailure && error.kind == OidcFailureKind.cancelled
          ? const AuthException(
              'cancelled',
              'Identity authentication was cancelled.',
            )
          : const AuthException(
              'identity_proof_failed',
              'Identity authentication failed. No proof was submitted.',
            );
    }
  }

  /// Invalidates late proof callbacks without replacing the signed-in session.
  /// Native AppAuth's system browser must also be dismissed by the user.
  Future<void> cancelIdentityProof() async {
    _checkDisposed();
    if (_proofFlight == null) return;
    _proofGeneration++;
    final generation = _generation;
    _setState(isSignedIn ? AuthSessionState.ready : AuthSessionState.signedOut);
    final client = _oidc;
    if (client is CancellableFreshOidcClient) {
      try {
        await client.cancelIdentityProof();
        _ensureCurrent(generation);
      } catch (_) {
        _ensureCurrent(generation);
        final safe = const AuthException(
          'identity_cancel_failed',
          'Proof cancellation needs a retry. Close the authentication window.',
        );
        _setState(AuthSessionState.ready, safe);
        throw safe;
      }
    }
  }

  bool _isProofCurrent(int generation, int proofGeneration) =>
      _isCurrent(generation) && proofGeneration == _proofGeneration;

  void _ensureProofCurrent(int generation, int proofGeneration) {
    if (!_isProofCurrent(generation, proofGeneration)) {
      throw const AuthException(
        'cancelled',
        'Identity authentication was cancelled.',
      );
    }
  }

  Future<String> _performRefresh(
    OidcConfig config,
    int generation,
    String? refreshToken,
    String binding,
  ) async {
    try {
      _setState(AuthSessionState.refreshing);
      _ensureCurrent(generation);
      final OidcTokens tokens;
      final client = _oidc;
      if (refreshToken != null) {
        tokens = await client.refresh(config, refreshToken);
      } else if (client is MemoryOidcClient) {
        tokens = await client.refreshCurrent(config);
      } else {
        throw const OidcFailure(OidcFailureKind.interactionRequired);
      }
      _ensureCurrent(generation);
      _validateTokens(tokens, config);
      final next = OidcTokens(
        accessToken: tokens.accessToken,
        expiresAt: tokens.expiresAt,
        refreshToken: _nonEmpty(tokens.refreshToken)
            ? tokens.refreshToken
            : refreshToken,
        idToken: tokens.idToken ?? _idToken,
        tokenType: tokens.tokenType,
        scopes: tokens.scopes,
      );
      // Store rotated credentials before any caller may use the new access token.
      await _persist(config, next.refreshToken, next.idToken, binding);
      _ensureCurrent(generation);
      _adopt(next, binding);
      _setState(AuthSessionState.ready);
      return next.accessToken!;
    } catch (error) {
      if (!_isCurrent(generation)) {
        throw const AuthException(
          'cancelled',
          'The credential session changed.',
        );
      }
      if ((error is OidcFailure &&
              error.kind == OidcFailureKind.interactionRequired) ||
          (error is AuthException && error.code == 'api_scope_denied')) {
        // Retain the published flight through deletion: a signedOut listener
        // must not restore the old disk record while terminal purge is pending.
        _forgetCredentials(keepRefreshFlight: true);
        final safe = error is AuthException
            ? error
            : const AuthException(
                'sign_in_required',
                'The provider requires a new sign-in.',
              );
        _setState(AuthSessionState.signedOut, safe);
        try {
          await _clearCredentials();
        } catch (_) {
          _ensureCurrent(generation);
          final storageError = const AuthException(
            'storage_failed',
            'Expired credentials could not be removed. Retry sign-out.',
          );
          _setState(AuthSessionState.error, storageError);
          throw storageError;
        }
        _ensureCurrent(generation);
        throw safe;
      }
      final safe = error is AuthException
          ? error
          : const AuthException(
              'refresh_failed',
              'Token refresh failed. Retry when connected, or sign in again.',
            );
      // A transient outage preserves the secure binding for explicit offline use.
      _setState(AuthSessionState.error, safe);
      throw safe;
    }
  }

  /// Drain and purge CosmosSyncClient first, then remove these credentials.
  /// Provider logout is optional and does not revoke BFF grants or refresh tokens.
  Future<void> signOut({bool endProviderSession = false}) async {
    _checkDisposed();
    final config = _config;
    final hint = _idToken;
    final generation = ++_generation;
    _proofGeneration++;
    _forgetCredentials();
    _setState(AuthSessionState.signingOut);
    try {
      await _clearCredentials();
      _ensureCurrent(generation);
    } catch (error) {
      _ensureCurrent(generation);
      final safe = const AuthException(
        'storage_failed',
        'Secure credentials could not be removed. Retry sign-out before closing.',
      );
      _setState(AuthSessionState.error, safe);
      throw safe;
    }
    _setState(
      config == null
          ? AuthSessionState.unconfigured
          : AuthSessionState.signedOut,
    );
    if (endProviderSession && config != null) {
      try {
        await _oidc.endSession(config, hint);
        _ensureCurrent(generation);
      } catch (_) {
        _ensureCurrent(generation);
        final safe = const AuthException(
          'provider_logout_failed',
          'Local sign-out completed. Provider browser logout did not complete.',
        );
        _setState(AuthSessionState.signedOut, safe);
        throw safe;
      }
    }
  }

  Future<void> _persist(
    OidcConfig config,
    String? refreshToken,
    String? idToken,
    String binding,
  ) {
    if (_oidc is MemoryOidcClient && _nonEmpty(refreshToken)) {
      throw const AuthException(
        'invalid_token_response',
        'Browser refresh credentials must remain inside the provider SDK.',
      );
    }
    if (!_nonEmpty(refreshToken)) {
      return _queuedStore(_store.clear);
    }
    final value = jsonEncode({
      'version': 1,
      'config': config.storageBinding,
      'refreshToken': refreshToken,
      'idToken': idToken,
      'credentialSessionId': binding,
    });
    return _queuedStore(() => _store.write(value));
  }

  void _validateTokens(OidcTokens tokens, OidcConfig config) {
    if (tokens.scopes != null &&
        config.apiScopes.any((scope) => !tokens.scopes!.contains(scope))) {
      throw const AuthException(
        'api_scope_denied',
        'The provider no longer grants the requested API scope. Sign in again.',
      );
    }
    if (!_nonEmpty(tokens.accessToken) ||
        tokens.accessToken!.length > 16384 ||
        !RegExp(r'^[A-Za-z0-9\-._~+/]+=*$').hasMatch(tokens.accessToken!) ||
        tokens.expiresAt == null ||
        !tokens.expiresAt!.isAfter(_clock().add(const Duration(seconds: 30))) ||
        tokens.tokenType?.toLowerCase() != 'bearer') {
      throw const AuthException(
        'invalid_token_response',
        'The provider did not return a usable Bearer access token for the requested API scope.',
      );
    }
  }

  void _adopt(OidcTokens tokens, String binding) {
    _accessToken = tokens.accessToken;
    _expiresAt = tokens.expiresAt;
    _refreshToken = _nonEmpty(tokens.refreshToken) ? tokens.refreshToken : null;
    _idToken = tokens.idToken;
    _credentialSessionId = binding;
  }

  void _forgetCredentials({bool keepRefreshFlight = false}) {
    _accessToken = null;
    _expiresAt = null;
    _refreshToken = null;
    _idToken = null;
    _credentialSessionId = null;
    _restoredSession = false;
    if (!keepRefreshFlight) {
      _refreshFlight = null;
    }
  }

  Future<T> _queuedStore<T>(Future<T> Function() action) {
    final result = _storeTail.then((_) => action());
    _storeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _clearCredentials() async {
    await _queuedStore(_store.clear);
    final client = _oidc;
    if (client is MemoryOidcClient) await client.clearSession();
  }

  OidcConfig _requireConfig() {
    _checkDisposed();
    return _config ??
        (throw const AuthException(
          'unconfigured',
          'Configure the OIDC provider first.',
        ));
  }

  void _checkDisposed() {
    if (_disposed) {
      throw const AuthException(
        'closed',
        'The authentication controller is closed.',
      );
    }
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;
  void _ensureCurrent(int generation) {
    if (!_isCurrent(generation)) {
      throw const AuthException('cancelled', 'The credential session changed.');
    }
  }

  void _setState(AuthSessionState state, [AuthException? error]) {
    if (_disposed) {
      return;
    }
    _state = state;
    _error = error;
    notifyListeners();
  }

  static bool _nonEmpty(Object? value) => value is String && value.isNotEmpty;

  /// Native app close preserves its secure restore record. Browser close also
  /// invalidates late callbacks and releases the SDK's in-memory credentials.
  Future<void> close() async {
    if (_disposed) return;
    if (_oidc is MemoryOidcClient) {
      _generation++;
      _forgetCredentials();
      try {
        await _clearCredentials();
      } catch (_) {
        final safe = const AuthException(
          'storage_failed',
          'Browser credentials could not be removed. Retry closing the session.',
        );
        _setState(AuthSessionState.error, safe);
        throw safe;
      }
    }
    dispose();
  }

  @override
  void dispose() {
    _generation++;
    _proofGeneration++;
    _disposed = true;
    _forgetCredentials();
    super.dispose();
  }
}
