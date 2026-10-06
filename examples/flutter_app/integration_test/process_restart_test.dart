import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cosmos_sync_example/auth/auth_session_controller.dart';
import 'package:cosmos_sync_example/auth/native_oidc.dart';
import 'package:cosmos_sync_example/data/settings_store_native.dart';
import 'package:cosmos_sync_example/data/workspace_repository.dart';
import 'package:cosmos_sync_example/main.dart';
import 'package:cosmos_sync_example/ui/app_controller.dart';
import 'package:cosmos_sync_example/ui/workspace_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// Only this test target uses a signed local adapter. The host terminates the
// first Android process without disposing its controller or clearing app data.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('secure binding and exact pending operation survive OS restart', (
    tester,
  ) async {
    const url = String.fromEnvironment('COSMOS_SYNC_RESTART_CONTROL_URL');
    final control = _RestartControl(url);
    final fixture = await control.request('config');
    _require(
      Platform.isAndroid &&
          {'write', 'read'}.contains(fixture['phase']) &&
          fixture['directoryName'] is String &&
          RegExp(
            r'^cosmos-restart-[0-9a-f]{32}$',
          ).hasMatch(fixture['directoryName'] as String) &&
          fixture['storeKey'] is String &&
          (fixture['storeKey'] as String).startsWith(
            'cosmos_sync_example.restart.',
          ),
    );
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/${fixture['directoryName']}');
    final expected = File('${directory.path}/restart-expected.json');
    final store = NativeRefreshTokenStore(key: fixture['storeKey'] as String);
    final oidc = _RestartOidc(fixture['token'] as String);
    final app = AppController(
      auth: AuthSessionController(oidc: oidc, tokenStore: store),
      workspace: WorkspaceController(
        repository: WorkspaceRepository(
          directory: Directory('${directory.path}/workspaces'),
        ),
      ),
      settingsStore: FileSettingsStore(File('${directory.path}/settings.json')),
    );
    await tester.pumpWidget(CosmosSyncApp(controller: app));
    if (fixture['phase'] == 'write') {
      _require(!await directory.exists() && await store.read() == null);
      await app.signIn(
        AppSettings(
          connection: ConnectionConfig(
            bffUri: Uri.parse(fixture['url'] as String),
            allowInsecureLocalhost: true,
          ),
          oidc: OidcConfig(
            issuer: 'https://fixture.cosmos-sync.test',
            clientId: 'native-restart-fixture',
            redirectUrl: 'com.anaregdesign.cosmossync://auth/oauthredirect',
            scopes: const ['openid', 'offline_access', 'cosmos_sync'],
          ),
        ),
      );
      debugPrint(
        'COSMOS_SYNC_RESTART_CONNECTION '
        'signedIn=${app.auth.isSignedIn} '
        'connected=${app.workspace.connected} '
        'bootstrapComplete=${app.workspace.bootstrapComplete} '
        'transportError=${app.workspace.lastTransportError != null}',
      );
      _require(app.workspace.connected && app.workspace.bootstrapComplete);
      await app.workspace.setOffline(true);
      await app.workspace.put('restart-note', {
        'title': 'durable before death',
      });
      _require(app.workspace.pending.length == 1);
      final operation = app.workspace.pending.single.operationId;
      await expected.writeAsString(
        jsonEncode({
          'operationId': operation,
          'credentialBinding': app.auth.credentialSessionId,
          'session': app.workspace.session!.toJson(),
        }),
        flush: true,
      );
      await control.request('durable', {
        'operationId': operation,
        'scopeId': app.workspace.session!.scopeId,
      });
      await Completer<void>().future;
      return;
    }
    try {
      _require(await expected.exists());
      final saved = (jsonDecode(await expected.readAsString()) as Map)
          .cast<String, Object?>();
      await app.initialize();
      _require(
        app.auth.restoredSession &&
            app.auth.credentialSessionId == saved['credentialBinding'] &&
            oidc.refreshCalls == 0,
      );
      await app.connect(offline: true);
      _require(
        app.workspace.connected &&
            app.workspace.offline &&
            oidc.refreshCalls == 0 &&
            app.workspace.pending.length == 1 &&
            app.workspace.pending.single.operationId == saved['operationId'] &&
            jsonEncode(app.workspace.session!.toJson()) ==
                jsonEncode(saved['session']) &&
            app.workspace.documents.single.data!['title'] ==
                'durable before death',
      );
      await app.workspace.setOffline(false);
      _require(
        app.workspace.pending.isEmpty &&
            app.workspace.documents.single.version == 1 &&
            !app.workspace.documents.single.hasPendingWrites,
      );
      await app.signOut();
      _require(
        app.auth.credentialSessionId == null &&
            await store.read() == null &&
            !await Directory('${directory.path}/workspaces').exists(),
      );
      await control.request('replayed', {
        'credentialBindingStable': true,
        'operationIdStable': true,
        'verifiedSessionStable': true,
        'offlineOpenWithoutRefresh': true,
        'matchingAckObserved': true,
        'localSignoutPurged': true,
      });
    } finally {
      await tester.pumpWidget(const SizedBox());
      await app.close();
      await store.clear();
      if (await directory.exists()) await directory.delete(recursive: true);
      control.close();
    }
  });
}

void _require(bool condition) {
  if (!condition) {
    throw StateError('The isolated process-restart contract failed.');
  }
}

class _RestartControl {
  _RestartControl(String value) : uri = Uri.parse(value) {
    _require(
      uri.scheme == 'http' &&
          uri.host == '127.0.0.1' &&
          uri.userInfo.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          uri.path.endsWith('/'),
    );
  }
  final Uri uri;
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);
  Future<Map<String, Object?>> request(
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final request = await client.openUrl(
      body == null ? 'GET' : 'POST',
      uri.resolve(path),
    );
    request.followRedirects = false;
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close().timeout(const Duration(seconds: 10));
    _require(response.statusCode == 200);
    return (jsonDecode(await utf8.decoder.bind(response).join()) as Map)
        .cast<String, Object?>();
  }

  void close() => client.close(force: true);
}

class _RestartOidc implements OidcClient {
  _RestartOidc(this.token);
  final String token;
  int refreshCalls = 0;
  OidcTokens tokens() => OidcTokens(
    accessToken: token,
    refreshToken: 'isolated-signed-restart-fixture',
    tokenType: 'Bearer',
    expiresAt: DateTime.now().add(const Duration(minutes: 5)),
  );
  @override
  Future<OidcTokens> signIn(OidcConfig config) async => tokens();
  @override
  Future<OidcTokens> refresh(OidcConfig config, String refreshToken) async {
    _require(refreshToken == 'isolated-signed-restart-fixture');
    refreshCalls++;
    return tokens();
  }

  @override
  Future<void> endSession(OidcConfig config, String? idToken) async {}
}
