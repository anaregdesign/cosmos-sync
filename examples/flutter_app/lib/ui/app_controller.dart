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
  }) {
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
  AppSettings? settings;
  bool _actionBusy = false;
  bool _disposed = false;
  bool _purgingExpired = false;
  String? _workspaceCredential;
  String? message;
  bool get busy => _actionBusy || _purgingExpired;

  bool get canConnect => auth.credentialSessionId != null && !busy;

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

  Future<void> _connect({required bool offline}) async {
    final config = settings;
    final binding = auth.credentialSessionId;
    if (config == null || binding == null) {
      throw StateError('Sign in with the configured identity provider first.');
    }
    _workspaceCredential = binding;
    await workspace.connect(
      config: config.connection,
      credentialBinding: binding,
      tokenProvider: auth.accessToken,
      offline: offline,
    );
  }

  Future<void> signOut() => _run(() async {
    await workspace.disconnect(purge: true);
    _workspaceCredential = null;
    await auth.signOut();
    message = 'Signed out. Local documents and pending writes were removed.';
  });

  void _authChanged() {
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
    } catch (_) {
      message = 'Action unavailable. Check the settings or sign in again.';
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
