import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:flutter/foundation.dart';

import '../auth/auth_session_controller.dart';
import '../data/workspace_repository.dart';
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
      ),
    );
  }
}

/// Coordinates native auth and cache lifetime without deriving JWT identity.
class AppController extends ChangeNotifier {
  AppController({
    required this.auth,
    required this.workspace,
    required this.settingsFile,
  }) {
    auth.addListener(_authChanged);
    workspace.addListener(_changed);
  }

  final AuthSessionController auth;
  final WorkspaceController workspace;
  final File settingsFile;
  AppSettings? settings;
  bool _actionBusy = false;
  bool _disposed = false;
  bool _purgingExpired = false;
  String? _workspaceCredential;
  String? message;
  bool get busy => _actionBusy || _purgingExpired;

  bool get canConnect => auth.credentialSessionId != null && !busy;

  Future<void> initialize() => _run(() async {
    if (!await settingsFile.exists()) return;
    settings = AppSettings.fromJson(
      (jsonDecode(await settingsFile.readAsString()) as Map)
          .cast<String, Object?>(),
    );
    auth.configure(settings!.oidc);
    await auth.restore();
    if (auth.credentialSessionId == null) {
      await workspace.repository.purge();
    }
  });

  Future<void> signIn(AppSettings value) => _run(() async {
    if (workspace.connected) {
      throw StateError('Sign out before changing the connection.');
    }
    // Validate the transport URL without requesting credentials or data.
    final check = HttpSyncTransport(
      baseUri: value.connection.bffUri,
      scopeMode: value.connection.scopeMode,
      allowInsecureLocalhost: value.connection.allowInsecureLocalhost,
      tokenProvider: () async => throw StateError('Validation only.'),
    );
    check.close();
    auth.configure(value.oidc);
    settings = value;
    await settingsFile.parent.create(recursive: true);
    final temporary = File('${settingsFile.path}.tmp');
    await temporary.writeAsString(jsonEncode(value.toJson()), flush: true);
    await temporary.rename(settingsFile.path);
    await auth.signIn();
    if (auth.credentialSessionId != null) await _connect(offline: false);
  });

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
    await workspace.disconnect();
    dispose();
    workspace.dispose();
    auth.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    auth.removeListener(_authChanged);
    workspace.removeListener(_changed);
    super.dispose();
  }
}
