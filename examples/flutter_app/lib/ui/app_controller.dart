import 'dart:async';
import 'dart:convert';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:flutter/foundation.dart';

import '../auth/auth_session_controller.dart';
import '../data/workspace_repository.dart';
import '../data/settings_store.dart';
import 'workspace_controller.dart';

class AppSettings {
  const AppSettings({required this.connection, required this.oidc});
  final ConnectionConfig connection;
  final OidcConfig oidc;

  Map<String, Object?> toJson() => {
    'connection': connection.toJson(),
    'oidc': {
      'issuer': oidc.issuer,
      'clientId': oidc.clientId,
      'redirectUrl': oidc.redirectUrl,
      'scopes': oidc.scopes,
      'discoveryUrl': oidc.discoveryUrl,
      'postLogoutRedirectUrl': oidc.postLogoutRedirectUrl,
      if (oidc.browser) 'browser': true,
      if (oidc.browser && oidc.browserAdapter != BrowserAuthAdapter.entra)
        'browserAdapter': oidc.browserAdapter.name,
    },
  };

  factory AppSettings.fromJson(Map<String, Object?> json) {
    final oidc = (json['oidc'] as Map).cast<String, Object?>();
    return AppSettings(
      connection: ConnectionConfig.fromJson(
        (json['connection'] as Map).cast<String, Object?>(),
      ),
      oidc: OidcConfig(
        issuer: oidc['issuer'] as String,
        clientId: oidc['clientId'] as String,
        redirectUrl: oidc['redirectUrl'] as String,
        scopes: (oidc['scopes'] as List).cast<String>(),
        discoveryUrl: oidc['discoveryUrl'] as String?,
        postLogoutRedirectUrl: oidc['postLogoutRedirectUrl'] as String?,
        browser: oidc['browser'] as bool? ?? false,
        browserAdapter: BrowserAuthAdapter.values.byName(
          oidc['browserAdapter'] as String? ?? 'entra',
        ),
      ),
    );
  }
}

/// Coordinates native auth and cache lifetime without deriving JWT identity.
class AppController extends ChangeNotifier {
  AppController({
    required this.auth,
    required this.workspace,
    required this.settingsStore,
    this.sharedScopeId,
    this.brokerCapabilities,
    HttpSyncTransport Function(ConnectionConfig, Future<String> Function())?
    identityTransportFactory,
  }) : _identityTransportFactory = identityTransportFactory ?? _identityHTTP {
    auth.addListener(_authChanged);
    workspace.addListener(_changed);
  }

  final AuthSessionController auth;
  final WorkspaceController workspace;
  final SettingsStore settingsStore;

  /// Optional build-selected, server-created shared scope. The BFF still checks
  /// current membership; this identifier grants no permission.
  final String? sharedScopeId;

  /// Explicit operator build configuration, never inferred from saved settings
  /// or a provider/token claim. It advertises navigation, not data permission.
  final EntraBrokerCapabilities? brokerCapabilities;
  final HttpSyncTransport Function(ConnectionConfig, Future<String> Function())
  _identityTransportFactory;
  HttpSyncTransport? _identityTransport;
  String? _identityCredential;
  IdentityCapabilities? identityCapabilities;
  IdentityAccount? identityAccount;
  bool registrationRequired = false;
  AppSettings? settings;
  bool _actionBusy = false;
  bool _disposed = false;
  bool _purgingExpired = false;
  String? _workspaceCredential;
  String? message;
  bool get busy => _actionBusy || _purgingExpired;

  bool get canConnect => auth.credentialSessionId != null && !busy;
  bool get canChangeIdentity =>
      identityCapabilities != null &&
      auth.supportsFreshIdentityProof &&
      auth.isSignedIn &&
      !workspace.offline &&
      !workspace.busy &&
      !busy;

  static HttpSyncTransport _identityHTTP(
    ConnectionConfig config,
    Future<String> Function() tokenProvider,
  ) => HttpSyncTransport(
    baseUri: config.bffUri,
    tokenProvider: tokenProvider,
    allowInsecureLocalhost: config.allowInsecureLocalhost,
  );

  Future<void> initialize() => _run(() async {
    final saved = await settingsStore.read();
    if (saved == null) return;
    settings = _selectedSettings(
      AppSettings.fromJson((jsonDecode(saved) as Map).cast<String, Object?>()),
    );
    auth.configure(settings!.oidc);
    await auth.restore();
    if (auth.credentialSessionId == null && auth.supportsCredentialRestore) {
      await workspace.repository.purge();
    }
  });

  Future<void> signIn(AppSettings value, {BrokerProvider? provider}) =>
      _run(() async {
        if (workspace.connected) {
          throw StateError('Sign out before changing the connection.');
        }
        final selected = _selectedSettings(value);
        if (provider != null) selected.oidc.forBrokerProvider(provider);
        // Validate the transport URL without requesting credentials or data.
        final check = HttpSyncTransport(
          baseUri: selected.connection.bffUri,
          scopeMode: selected.connection.scopeMode,
          sharedScopeId: selected.connection.sharedScopeId,
          allowInsecureLocalhost: selected.connection.allowInsecureLocalhost,
          tokenProvider: () async => throw StateError('Validation only.'),
        );
        check.close();
        auth.configure(selected.oidc);
        settings = selected;
        await settingsStore.write(jsonEncode(selected.toJson()));
        await auth.signIn(provider: provider);
        if (auth.credentialSessionId != null) await _connect(offline: false);
      });

  AppSettings _selectedSettings(AppSettings value) {
    value.connection.validateScopeSelection();
    final capabilities = brokerCapabilities;
    final oidc = value.oidc.withBrokerCapabilities(
      capabilities != null &&
              value.oidc.supportsEntraNavigation &&
              capabilities.matches(
                issuer: value.oidc.issuer,
                clientId: value.oidc.clientId,
              )
          ? capabilities
          : null,
    );
    final selected = AppSettings(
      connection: sharedScopeId == null
          ? value.connection
          : ConnectionConfig(
              bffUri: value.connection.bffUri,
              scopeMode: SyncScopeMode.shared,
              sharedScopeId: sharedScopeId,
              allowInsecureLocalhost: value.connection.allowInsecureLocalhost,
            ),
      oidc: oidc,
    );
    selected.connection.validateScopeSelection();
    return selected;
  }

  Future<void> connect({bool offline = false}) =>
      _run(() => _connect(offline: offline));

  Future<void> _connect({
    required bool offline,
    SessionInfo? expectedIdentity,
  }) async {
    final config = settings;
    final binding = auth.credentialSessionId;
    if (config == null || binding == null) {
      throw StateError('Sign in with the configured identity provider first.');
    }
    if (workspace.busy) {
      throw const AuthException(
        'workspace_busy',
        'Finish workspace operations before connecting.',
      );
    }
    _workspaceCredential = binding;
    await workspace.connect(
      config: config.connection,
      credentialBinding: binding,
      tokenProvider: auth.accessToken,
      offline: offline,
      expectedIdentity: expectedIdentity,
    );
    if (offline) return;
    if (expectedIdentity != null &&
        !workspace.connected &&
        workspace.lastTransportError != null) {
      throw workspace.lastTransportError!;
    }
    if (workspace.lastTransportError?.code ==
        'identity_registration_required') {
      await _loadIdentity(registration: true);
      message =
          'This credential is not registered. Register a new account explicitly, '
          'or sign in with a remaining linked identity to recover an existing account.';
    } else if (workspace.session?.identityGeneration != null) {
      try {
        await _loadIdentity(expectedSession: workspace.session);
      } catch (error) {
        if (error is TransportException && error.authorizationFailure ||
            error is AuthException &&
                error.code == 'identity_session_changed') {
          await workspace.disconnect(purge: true);
        }
        rethrow;
      }
    } else {
      _clearIdentity();
    }
  }

  Future<SessionInfo?> _loadIdentity({
    bool registration = false,
    SessionInfo? expectedSession,
    IdentityAccount? expectedAccount,
  }) async {
    final configured = settings!;
    final credential = auth.credentialSessionId!;
    _clearIdentity();
    final transport = _identityTransportFactory(
      configured.connection,
      auth.accessToken,
    );
    try {
      final capabilities = await transport.identityCapabilities();
      capabilities.targetFor(
        issuer: configured.oidc.issuer,
        clientId: configured.oidc.clientId,
        callback: configured.oidc.redirectUrl,
      );
      IdentityAccount? account;
      SessionInfo? verified;
      if (!registration) {
        final session = await transport.sessionInfo();
        if (session.identityGeneration == null ||
            expectedSession != null &&
                (session.principalId != expectedSession.principalId ||
                    session.identityGeneration !=
                        expectedSession.identityGeneration ||
                    session.identityId != expectedSession.identityId) ||
            expectedAccount != null &&
                !_matchesIdentityAccount(expectedAccount, session)) {
          throw const AuthException(
            'identity_session_changed',
            'The identity changed. Verify the account online before reopening data.',
          );
        }
        account = await transport.accountIdentities();
        if (!_matchesIdentityAccount(account, session)) {
          throw const AuthException(
            'identity_session_changed',
            'The identity result does not match the verified BFF session.',
          );
        }
        verified = session;
      }
      _requireCredential(credential);
      _identityTransport = transport;
      _identityCredential = credential;
      identityCapabilities = capabilities;
      identityAccount = account;
      registrationRequired = registration;
      return verified;
    } catch (_) {
      transport.close();
      rethrow;
    }
  }

  static bool _matchesIdentityAccount(
    IdentityAccount account,
    SessionInfo session,
  ) =>
      account.account.accountId == session.principalId &&
      account.account.personalScopeId == session.scopeId &&
      account.identityGeneration == session.identityGeneration &&
      account.currentIdentityId == session.identityId;

  Future<void> registerAccount({bool discardPending = false}) =>
      _identityOperation(
        IdentityOperation.register,
        discardPending: discardPending,
      );

  Future<void> linkIdentity({bool discardPending = false}) =>
      _identityOperation(
        IdentityOperation.link,
        discardPending: discardPending,
      );

  Future<void> unlinkIdentity(
    String identityId, {
    bool discardPending = false,
  }) => _identityOperation(
    IdentityOperation.unlink,
    removeIdentityId: identityId,
    discardPending: discardPending,
  );

  Future<void> _identityOperation(
    IdentityOperation operation, {
    String? removeIdentityId,
    required bool discardPending,
  }) => _run(() async {
    final capabilities = identityCapabilities;
    final account = identityAccount;
    final transport = _identityTransport;
    final configured = settings;
    final credential = auth.credentialSessionId;
    if (capabilities == null ||
        transport == null ||
        configured == null ||
        credential == null ||
        !auth.supportsFreshIdentityProof ||
        workspace.offline ||
        workspace.busy ||
        (operation == IdentityOperation.register) != registrationRequired ||
        operation != IdentityOperation.register && account == null) {
      throw const AuthException(
        'identity_operation_unavailable',
        'Verify the configured directory account online before changing identities.',
      );
    }
    _checkPending(discardPending);
    if (operation == IdentityOperation.link &&
            account!.identities.length >= capabilities.maximumIdentities ||
        operation == IdentityOperation.unlink &&
            (account!.identities.length <= 1 ||
                !account.identities.any(
                  (value) => value.identityId == removeIdentityId,
                ))) {
      throw const AuthException(
        'identity_operation_unavailable',
        'Keep at least one linked credential and use a listed identity.',
      );
    }
    final target = capabilities.targetFor(
      issuer: configured.oidc.issuer,
      clientId: configured.oidc.clientId,
      callback: configured.oidc.redirectUrl,
    );
    var submitted = false;
    try {
      await workspace.disconnect(purge: true);
      _workspaceCredential = null;
      _requireCredential(credential);
      final challenge = await transport.createIdentityChallenge(
        operation: operation,
        callback: target.callback,
        removeIdentityId: removeIdentityId,
      );
      if (!challenge.target.sameTarget(target)) {
        throw const AuthException(
          'invalid_identity_challenge',
          'The BFF challenge does not match its approved target.',
        );
      }
      message = operation == IdentityOperation.register
          ? 'Authenticate the credential for this new account.'
          : 'First, reauthenticate the currently signed-in credential.';
      _changed();
      final current = await auth.freshIdentityProof(challenge);
      FreshIdentityProof? independent;
      if (operation != IdentityOperation.register) {
        message = operation == IdentityOperation.link
            ? 'Now authenticate the independent identity to link.'
            : 'Now authenticate a credential that will remain linked.';
        _changed();
        independent = await auth.freshIdentityProof(challenge);
      }
      _requireCredential(credential);
      submitted = true;
      final result = switch (operation) {
        IdentityOperation.register => await transport.registerIdentity(
          challenge,
          current,
        ),
        IdentityOperation.link => await transport.linkIdentity(
          challenge: challenge,
          reauthentication: current,
          identity: independent!,
        ),
        IdentityOperation.unlink => await transport.unlinkIdentity(
          challenge: challenge,
          reauthentication: current,
          remainingIdentity: independent!,
        ),
      };
      _requireCredential(credential);
      if (result.currentIdentityId == null) {
        _clearIdentity();
        await auth.signOut();
        message =
            'The current identity was removed. Sign in online with a remaining '
            'linked credential; the removed credential cannot recover this account.';
        return;
      }
      final verified = await _loadIdentity(expectedAccount: result);
      await _connect(offline: false, expectedIdentity: verified);
      message = workspace.connected
          ? 'Account identity updated and verified online. Server-owned data is unchanged.'
          : 'Account identity updated. The workspace still needs online verification.';
    } catch (_) {
      _clearIdentity();
      if (submitted) {
        if (!_disposed && auth.credentialSessionId == credential) {
          await auth.signOut();
        }
        throw const AuthException(
          'identity_outcome_unknown',
          'The identity outcome or new session could not be verified. Sign in '
              'online with a linked credential; do not replay the old challenge.',
        );
      }
      rethrow;
    }
  });

  void _checkPending(bool discardPending) {
    if (workspace.pending.isNotEmpty && !discardPending) {
      throw const AuthException(
        'pending_writes',
        'Synchronize pending writes or explicitly confirm their local removal first.',
      );
    }
  }

  Future<void> recoverWithRemainingIdentity({bool discardPending = false}) =>
      _run(() async {
        _checkPending(discardPending);
        await workspace.disconnect(purge: true);
        _workspaceCredential = null;
        _clearIdentity();
        await auth.signOut();
        message =
            'Sign in online with a remaining, already linked identity. '
            'Recovery never matches email or creates a replacement account.';
      });

  Future<void> cancelIdentityProof() async {
    try {
      await auth.cancelIdentityProof();
    } catch (_) {
      message =
          'Proof cancellation needs a retry. Close the authentication window.';
      _changed();
    }
  }

  void _requireCredential(String credential) {
    if (_disposed || auth.credentialSessionId != credential) {
      throw const AuthException('cancelled', 'The credential session changed.');
    }
  }

  void _clearIdentity() {
    _identityTransport?.close();
    _identityTransport = null;
    _identityCredential = null;
    identityCapabilities = null;
    identityAccount = null;
    registrationRequired = false;
  }

  Future<void> signOut() => _run(() async {
    await workspace.disconnect(purge: true);
    _workspaceCredential = null;
    _clearIdentity();
    await auth.signOut();
    message = 'Signed out. Local documents and pending writes were removed.';
  });

  void _authChanged() {
    if (_disposed) return;
    if (_identityCredential != null &&
        _identityCredential != auth.credentialSessionId) {
      _clearIdentity();
    }
    if (_workspaceCredential != null &&
        auth.credentialSessionId != _workspaceCredential &&
        !_purgingExpired) {
      _purgingExpired = true;
      unawaited(
        workspace
            .disconnect(purge: true)
            .then(
              (_) {
                _workspaceCredential = null;
                message = 'Authentication expired. Local cache was removed.';
              },
              onError: (Object error, StackTrace stack) {
                message =
                    'Authentication expired. Cache cleanup needs a retry.';
              },
            )
            .whenComplete(() {
              _purgingExpired = false;
              _changed();
            }),
      );
    }
    _changed();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || _disposed) return;
    _actionBusy = true;
    message = null;
    _changed();
    try {
      await action();
    } catch (error) {
      message = error is AuthException
          ? error.message
          : error is TransportException
          ? 'Account request failed (${error.statusCode ?? 'network'}). '
                'Verify online before changing identities.'
          : 'Action unavailable. Check the settings or sign in again.';
    } finally {
      _actionBusy = false;
      _changed();
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> close() async {
    if (_disposed) return;
    _clearIdentity();
    await workspace.disconnect();
    await auth.close();
    dispose();
    workspace.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    auth.removeListener(_authChanged);
    workspace.removeListener(_changed);
    super.dispose();
  }
}
