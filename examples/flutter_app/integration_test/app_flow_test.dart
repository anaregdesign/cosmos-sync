import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:cosmos_sync_example/auth/auth_session_controller.dart';
import 'package:cosmos_sync_example/auth/native_oidc.dart';
import 'package:cosmos_sync_example/data/workspace_repository.dart';
import 'package:cosmos_sync_example/main.dart';
import 'package:cosmos_sync_example/ui/app_controller.dart';
import 'package:cosmos_sync_example/ui/workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Test-target-only adapter. The ordinary main target always uses AppAuth.
/// A loopback test control URL supplies a short-lived JWT signed by the Go test
/// issuer; no credential is embedded in a dart-define, asset or checked-in file.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native UI uses real HTTP, SQLite and isolated OS secure storage', (
    tester,
  ) async {
    const fixtureUrl = String.fromEnvironment('COSMOS_SYNC_TEST_FIXTURE_URL');
    expect(
      fixtureUrl,
      isNotEmpty,
      reason: 'Run through tools/flutter_app_smoke.py.',
    );
    final fixture = await _fixture(Uri.parse(fixtureUrl));
    final support = await getApplicationSupportDirectory();
    final directory = await Directory(
      '${support.path}/cosmos-app-validation-${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final store = _MemoryStore();
    final oidc = _FixtureOidc(fixture['token'] as String);
    final nativeStore = NativeRefreshTokenStore(
      key: 'cosmos_sync_example.test.${DateTime.now().microsecondsSinceEpoch}',
    );
    AppController? app;
    CosmosSyncClient? peer;
    AppController makeApp() => AppController(
      auth: AuthSessionController(oidc: oidc, tokenStore: store),
      workspace: WorkspaceController(
        repository: WorkspaceRepository(
          directory: Directory('${directory.path}/workspaces'),
        ),
      ),
      settingsFile: File('${directory.path}/connection.json'),
    );
    try {
      await nativeStore.write('fixture-refresh-record');
      expect(await nativeStore.read(), 'fixture-refresh-record');
      await nativeStore.clear();
      expect(await nativeStore.read(), isNull);

      app = makeApp();
      await tester.pumpWidget(CosmosSyncApp(controller: app));
      await tester.enterText(
        find.byKey(const Key('bff-url')),
        fixture['url'] as String,
      );
      await tester.enterText(
        find.byKey(const Key('oidc-issuer')),
        'https://fixture.cosmos-sync.test',
      );
      await tester.enterText(
        find.byKey(const Key('oidc-client')),
        'native-fixture',
      );
      await tester.enterText(
        find.byKey(const Key('oidc-scopes')),
        'openid offline_access cosmos_sync',
      );
      await _tap(
        tester,
        find.text('Allow loopback HTTP for local development'),
      );
      await _tap(tester, find.byKey(const Key('sign-in')));
      await _wait(
        tester,
        () => app!.workspace.connected && !app.busy && !app.workspace.busy,
      );
      expect(app.workspace.bootstrapComplete, true);
      expect(app.workspace.session!.principalId, isNotEmpty);
      expect(app.auth.restoredSession, false);

      await _tap(tester, find.byKey(const Key('offline-switch')));
      await _wait(tester, () => !app!.workspace.busy);
      await _edit(tester, id: 'note', json: '{"title":"offline first"}');
      await _wait(tester, () => !app!.workspace.busy);
      final operationId = app.workspace.pending.single.operationId;
      expect(app.workspace.documents.single.hasPendingWrites, true);
      expect(find.byKey(const Key('document-note')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await app.close();

      app = makeApp();
      await app.initialize();
      expect(app.auth.restoredSession, true);
      final refreshCalls = oidc.refreshCalls;
      await tester.pumpWidget(CosmosSyncApp(controller: app));
      await _tap(tester, find.byKey(const Key('connect-offline')));
      await _wait(tester, () => app!.workspace.connected && !app.busy);
      expect(
        oidc.refreshCalls,
        refreshCalls,
        reason: 'Opening cache offline does not refresh.',
      );
      expect(app.workspace.pending.single.operationId, operationId);
      expect(app.workspace.documents.single.data!['title'], 'offline first');
      await _tap(tester, find.byKey(const Key('offline-switch')));
      await _wait(tester, () => !app!.workspace.busy);
      expect(app.workspace.pending, isEmpty);
      expect(app.workspace.documents.single.hasPendingWrites, false);

      peer = await CosmosSyncClient.open(
        path: '${directory.path}/peer.sqlite',
        transport: HttpSyncTransport(
          baseUri: Uri.parse(fixture['url'] as String),
          tokenProvider: () async => fixture['token'] as String,
          allowInsecureLocalhost: true,
        ),
      );
      await peer.sync();
      await _tap(tester, find.byKey(const Key('offline-switch')));
      await _wait(tester, () => !app!.workspace.busy);
      await _edit(
        tester,
        id: 'note',
        json: '{"title":"keep local"}',
        existing: true,
      );
      await _wait(tester, () => !app!.workspace.busy);
      await peer.put('note', {'title': 'remote conflict'});
      await peer.flush();
      await _tap(tester, find.byKey(const Key('offline-switch')));
      await _wait(tester, () => !app!.workspace.busy);
      expect(app.workspace.pending.single.state, MutationState.conflict);
      await _tap(tester, find.byKey(const Key('keep-local-note')));
      await _wait(tester, () => !app!.workspace.busy);
      expect(app.workspace.pending, isEmpty);
      expect(app.workspace.documents.single.data!['title'], 'keep local');

      await _tap(tester, find.byKey(const Key('offline-switch')));
      await _wait(tester, () => !app!.workspace.busy);
      await _edit(
        tester,
        id: 'note',
        json: '{"title":"discard local"}',
        existing: true,
      );
      await _wait(tester, () => !app!.workspace.busy);
      await peer.sync();
      await peer.put('note', {'title': 'use server'});
      await peer.flush();
      await _tap(tester, find.byKey(const Key('offline-switch')));
      await _wait(tester, () => !app!.workspace.busy);
      expect(app.workspace.pending.single.state, MutationState.conflict);
      await _tap(tester, find.byKey(const Key('discard-note')));
      await _wait(tester, () => !app!.workspace.busy);
      expect(app.workspace.documents.single.data!['title'], 'use server');

      await _tap(tester, find.byKey(const Key('delete-note')));
      await _tap(tester, find.byKey(const Key('confirm-delete')));
      await _wait(tester, () => !app!.workspace.busy);
      expect(app.workspace.documents, isEmpty);
      await peer.sync();
      expect(peer.get('note')!.deleted, true);

      await _tap(tester, find.byKey(const Key('offline-switch')));
      await _wait(tester, () => !app!.workspace.busy);
      await _edit(tester, id: 'unsent', json: '{"title":"purge on logout"}');
      await _wait(tester, () => !app!.workspace.busy);
      await _tap(tester, find.byKey(const Key('sign-out')));
      await _tap(tester, find.byKey(const Key('confirm-sign-out')));
      await _wait(tester, () => !app!.busy);
      expect(app.workspace.connected, false);
      expect(app.workspace.documents, isEmpty);
      expect(app.workspace.pending, isEmpty);
      expect(app.auth.credentialSessionId, null);
      expect(store.value, null);
      expect(await app.workspace.repository.directory.exists(), false);
      debugPrint(
        'COSMOS_SYNC_APP_PASS ${Platform.operatingSystem} '
        'realHttp=true realSqlite=true auth=test-adapter nativeSecureStorage=verified',
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      await peer?.close();
      await app?.close();
      await nativeStore.clear();
      await directory.delete(recursive: true);
    }
  });
}

Future<Map<String, Object?>> _fixture(Uri uri) async {
  if (uri.scheme != 'http' || uri.host != '127.0.0.1') {
    throw StateError('The disposable test control endpoint must use loopback.');
  }
  final http = HttpClient();
  try {
    final response = await (await http.getUrl(uri)).close();
    if (response.statusCode != 200) throw StateError('Fixture is not ready.');
    return (jsonDecode(await utf8.decoder.bind(response).join()) as Map)
        .cast<String, Object?>();
  } finally {
    http.close(force: true);
  }
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('App operation did not finish.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _edit(
  WidgetTester tester, {
  required String id,
  required String json,
  bool existing = false,
}) async {
  await _tap(
    tester,
    find.byKey(Key(existing ? 'document-$id' : 'new-document')),
  );
  await tester.pumpAndSettle();
  if (!existing) {
    await tester.enterText(find.byKey(const Key('document-id')), id);
  }
  await tester.enterText(find.byKey(const Key('document-json')), json);
  await _tap(tester, find.byKey(const Key('save-document')));
}

class _MemoryStore implements RefreshTokenStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
  @override
  Future<void> clear() async => value = null;
}

class _FixtureOidc implements OidcClient {
  _FixtureOidc(this.token);
  final String token;
  int refreshCalls = 0;
  OidcTokens tokens() => OidcTokens(
    accessToken: token,
    refreshToken: 'fixture-memory-refresh',
    tokenType: 'Bearer',
    expiresAt: DateTime.now().add(const Duration(minutes: 5)),
  );
  @override
  Future<OidcTokens> signIn(OidcConfig config) async => tokens();
  @override
  Future<OidcTokens> refresh(OidcConfig config, String refreshToken) async {
    refreshCalls++;
    return tokens();
  }

  @override
  Future<void> endSession(OidcConfig config, String? idToken) async {}
}
