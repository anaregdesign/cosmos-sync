import 'dart:async';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:cosmos_sync_example/auth/auth_session_controller.dart';
import 'package:cosmos_sync_example/data/workspace_repository.dart';
import 'package:cosmos_sync_example/ui/app_controller.dart';
import 'package:cosmos_sync_example/ui/workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_transport.dart';

void main() {
  late Directory directory;
  late TestServer server;
  late DateTime now;
  late _Oidc oidc;
  late _Store store;
  late AppController app;
  final settings = AppSettings(
    connection: ConnectionConfig(bffUri: Uri.parse('https://bff.example.test')),
    oidc: OidcConfig(
      issuer: 'https://issuer.example.test',
      clientId: 'native-public',
      redirectUrl: 'com.anaregdesign.cosmossync://auth/oauthredirect',
      scopes: ['openid', 'offline_access', 'cosmos_sync'],
    ),
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cosmos-app-lifecycle-');
    server = TestServer();
    now = DateTime.utc(2026, 10, 3);
    oidc = _Oidc(() => now);
    store = _Store();
    app = AppController(
      auth: AuthSessionController(
        oidc: oidc,
        tokenStore: store,
        clock: () => now,
      ),
      workspace: WorkspaceController(
        repository: WorkspaceRepository(
          directory: Directory('${directory.path}/workspaces'),
          transportFactory: (_, token) => _TokenTransport(server, token),
        ),
      ),
      settingsFile: File('${directory.path}/connection.json'),
    );
    await app.signIn(settings);
    expect(app.workspace.connected, true);
  });
  tearDown(() async {
    await app.close();
    await directory.delete(recursive: true);
  });

  test(
    'ordinary signout can drain a pending request and removes credentials last',
    () async {
      server.inFlight = Completer<ServerDocument>();
      final saving = app.workspace.put('note', {'title': 'late'});
      await server.started.future;
      final signingOut = app.signOut();
      await Future<void>.delayed(Duration.zero);
      expect(app.workspace.connected, false);
      expect(app.busy, true);
      expect(
        store.value,
        isNotNull,
        reason: 'Credentials live until the SDK drains.',
      );
      server.inFlight!.complete(
        ServerDocument(
          id: 'note',
          data: {'title': 'late'},
          version: 1,
          deleted: false,
        ),
      );
      await Future.wait([saving, signingOut]);
      expect(app.workspace.documents, isEmpty);
      expect(app.auth.credentialSessionId, null);
      expect(store.value, null);
      expect(await app.workspace.repository.directory.exists(), false);
    },
  );

  test('terminal auth refresh hides then purges the connected cache', () async {
    await app.workspace.setOffline(true);
    await app.workspace.put('offline', {'title': 'private'});
    expect(app.workspace.documents, isNotEmpty);
    now = now.add(const Duration(hours: 2));
    oidc.terminal = true;
    await app.workspace.setOffline(false);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (app.busy) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Purge did not finish.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(app.auth.credentialSessionId, null);
    expect(app.workspace.connected, false);
    expect(app.workspace.documents, isEmpty);
    expect(app.workspace.pending, isEmpty);
    expect(await app.workspace.repository.directory.exists(), false);
    expect(store.value, null);
  });

  test(
    'signout then account switch never shows prior principal documents',
    () async {
      await app.workspace.setOffline(true);
      await app.workspace.put('alice-private', {'title': 'private'});
      final previousBinding = app.auth.credentialSessionId;
      await app.signOut();
      server.principal = 'bob';
      await app.signIn(settings);
      expect(app.workspace.connected, true);
      expect(app.workspace.session!.principalId, 'bob');
      expect(app.auth.credentialSessionId, isNot(previousBinding));
      expect(app.workspace.documents, isEmpty);
      expect(app.workspace.pending, isEmpty);
    },
  );

  test(
    'Google to Apple navigation switch requires a fresh BFF cache owner',
    () async {
      await app.signOut();
      await app.close();
      const issuer = 'https://consumer.ciamlogin.com/tenant/v2.0';
      app = AppController(
        auth: AuthSessionController(
          oidc: oidc,
          tokenStore: store,
          clock: () => now,
        ),
        workspace: WorkspaceController(
          repository: WorkspaceRepository(
            directory: Directory('${directory.path}/workspaces'),
            transportFactory: (_, token) => _TokenTransport(server, token),
          ),
        ),
        settingsFile: File('${directory.path}/connection.json'),
        brokerCapabilities: EntraBrokerCapabilities(
          issuer: issuer,
          clientId: 'native-public',
          providers: [BrokerProvider.google, BrokerProvider.apple],
        ),
      );
      final brokerSettings = AppSettings(
        connection: settings.connection,
        oidc: OidcConfig(
          issuer: issuer,
          clientId: 'native-public',
          redirectUrl: settings.oidc.redirectUrl,
          scopes: settings.oidc.scopes,
        ),
      );
      await app.signIn(brokerSettings, provider: BrokerProvider.google);
      expect(oidc.lastSignIn!.brokerProvider, BrokerProvider.google);
      await app.workspace.setOffline(true);
      await app.workspace.put('alice-private', {'title': 'private'});
      final previousBinding = app.auth.credentialSessionId;
      await app.signOut();
      server.principal = 'bob';
      await app.signIn(brokerSettings, provider: BrokerProvider.apple);
      expect(oidc.lastSignIn!.brokerProvider, BrokerProvider.apple);
      expect(app.auth.config!.brokerProvider, null);
      expect(app.workspace.session!.principalId, 'bob');
      expect(app.auth.credentialSessionId, isNot(previousBinding));
      expect(app.workspace.documents, isEmpty);
      expect(app.workspace.pending, isEmpty);
      expect(
        await app.settingsFile.readAsString(),
        isNot(contains('domain_hint')),
      );
      expect(
        await app.settingsFile.readAsString(),
        isNot(contains('providers')),
      );
    },
  );
}

class _TokenTransport extends TestTransport {
  _TokenTransport(super.server, this.token);
  final Future<String> Function() token;
  @override
  Future<SessionInfo> sessionInfo() async {
    await token();
    return super.sessionInfo();
  }
}

class _Store implements RefreshTokenStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
  @override
  Future<void> clear() async => value = null;
}

class _Oidc implements OidcClient {
  _Oidc(this.clock);
  final DateTime Function() clock;
  bool terminal = false;
  OidcConfig? lastSignIn;
  OidcTokens tokens() => OidcTokens(
    accessToken: 'test-access',
    refreshToken: 'test-refresh',
    tokenType: 'Bearer',
    expiresAt: clock().add(const Duration(hours: 1)),
  );
  @override
  Future<OidcTokens> signIn(OidcConfig config) async {
    lastSignIn = config;
    return tokens();
  }

  @override
  Future<OidcTokens> refresh(OidcConfig config, String refreshToken) async {
    if (terminal) throw const OidcFailure(OidcFailureKind.interactionRequired);
    return tokens();
  }

  @override
  Future<void> endSession(OidcConfig config, String? idToken) async {}
}
