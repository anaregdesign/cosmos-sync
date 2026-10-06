import 'dart:convert';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:cosmos_sync_example/auth/auth_session_controller.dart';
import 'package:cosmos_sync_example/data/workspace_repository.dart';
import 'package:cosmos_sync_example/data/settings_store_native.dart';
import 'package:cosmos_sync_example/main.dart';
import 'package:cosmos_sync_example/ui/app_controller.dart';
import 'package:cosmos_sync_example/ui/workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Manual test target: recorded, signature-verified real provider API token.
/// This does not perform or claim fresh AppAuth, provider refresh or Keychain
/// restoration. The separate entra_auth_live_test proves those operations.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'actual Cosmos via native UI, pinned TLS and durable SQLite',
    (tester) async {
      final control = _Control(
        Uri.parse(
          const String.fromEnvironment('COSMOS_SYNC_AZURE_UI_CONTROL_URL'),
        ),
      );
      late Map<String, Object?> fixture;
      await tester.runAsync(
        () async => fixture = await control.configuration(),
      );
      final native = (fixture['nativeConfig'] as Map).cast<String, Object?>();
      final urls = (fixture['bffUrls'] as List).cast<String>();
      final certificate = utf8.encode(fixture['certificatePem'] as String);
      final token = fixture['accessToken'] as String;
      final note = fixture['documentId'] as String;
      final memoryStore = _MemoryStore();
      final oidc = _RecordedProviderToken(token);
      late Directory directory;
      await tester.runAsync(() async {
        final support = await getApplicationSupportDirectory();
        directory = await Directory(
          '${support.path}/cosmos-azure-ui-${DateTime.now().microsecondsSinceEpoch}',
        ).create(recursive: true);
      });
      AppController? app;
      CosmosSyncClient? peer;
      HttpSyncTransport transport(
        String base,
        Future<String> Function() provider,
      ) => HttpSyncTransport(
        baseUri: Uri.parse(base),
        tokenProvider: provider,
        client: _BoundedClient(base, certificate, control),
      );
      AppController makeApp() => AppController(
        auth: AuthSessionController(oidc: oidc, tokenStore: memoryStore),
        workspace: WorkspaceController(
          repository: WorkspaceRepository(
            directory: Directory('${directory.path}/workspaces'),
            transportFactory: (config, provider) =>
                transport(config.bffUri.toString(), provider),
          ),
        ),
        settingsStore: FileSettingsStore(
          File('${directory.path}/connection.json'),
        ),
      );
      DocumentSnapshot ownDocument() =>
          app!.workspace.documents.firstWhere((item) => item.id == note);
      try {
        app = makeApp();
        await tester.pumpWidget(CosmosSyncApp(controller: app));
        await tester.enterText(find.byKey(const Key('bff-url')), urls.first);
        await tester.enterText(
          find.byKey(const Key('oidc-issuer')),
          native['issuer'] as String,
        );
        await tester.enterText(
          find.byKey(const Key('oidc-client')),
          native['clientId'] as String,
        );
        await tester.enterText(
          find.byKey(const Key('oidc-scopes')),
          (native['scopes'] as List).cast<String>().join(' '),
        );
        await _tap(tester, find.byKey(const Key('sign-in')));
        await _wait(tester, () => app!.workspace.connected && !app.busy);
        expect(app.workspace.bootstrapComplete, isTrue);
        await _stage(tester, control, 'ui_connected');

        await _tap(tester, find.byKey(const Key('offline-switch')));
        await _wait(tester, () => !app!.workspace.busy);
        await _edit(
          tester,
          note,
          '{"fixture":"flutter-live","value":"offline"}',
        );
        await _wait(tester, () => !app!.workspace.busy);
        final operation = app.workspace.pending
            .singleWhere((item) => item.documentId == note)
            .operationId;
        expect(ownDocument().hasPendingWrites, isTrue);
        await _stage(tester, control, 'offline_write_durable');
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async => app!.close());

        app = makeApp();
        await tester.runAsync(() async => app!.initialize());
        expect(app.auth.restoredSession, isTrue);
        await tester.pumpWidget(CosmosSyncApp(controller: app));
        await _tap(tester, find.byKey(const Key('connect-offline')));
        await _wait(tester, () => app!.workspace.connected && !app.busy);
        expect(
          app.workspace.pending
              .singleWhere((item) => item.documentId == note)
              .operationId,
          operation,
        );
        expect(ownDocument().data!['value'], 'offline');
        await _stage(tester, control, 'offline_cache_reopened');

        await _tap(tester, find.byKey(const Key('offline-switch')));
        await _wait(tester, () => !app!.workspace.busy);
        expect(
          app.workspace.pending.where((item) => item.documentId == note),
          isEmpty,
        );
        expect(ownDocument().hasPendingWrites, isFalse);
        expect(ownDocument().version, greaterThan(0));
        await _stage(tester, control, 'create_acknowledged');
        await _edit(
          tester,
          note,
          '{"fixture":"flutter-live","value":"acknowledged-update"}',
          existing: true,
        );
        await _wait(tester, () => !app!.workspace.busy);
        expect(ownDocument().hasPendingWrites, isFalse);
        expect(ownDocument().data!['value'], 'acknowledged-update');
        await _stage(tester, control, 'update_acknowledged');
        await _tap(tester, find.byKey(const Key('offline-switch')));
        await _wait(tester, () => !app!.workspace.busy);

        await tester.runAsync(() async {
          peer = await CosmosSyncClient.open(
            path: '${directory.path}/peer.sqlite',
            transport: transport(urls.last, () async => token),
          );
          await peer!.sync();
        });
        expect(peer!.get(note)!.data!['value'], 'acknowledged-update');
        await _stage(tester, control, 'cross_replica_document_verified');
        await tester.runAsync(() async => peer!.close());
        peer = null;

        await _edit(tester, note, '{"value":"must-purge"}', existing: true);
        await _wait(tester, () => !app!.workspace.busy);
        expect(ownDocument().hasPendingWrites, isTrue);
        await tester.runAsync(() async => control.action('downgrade'));
        await _tap(tester, find.byKey(const Key('offline-switch')));
        await _wait(tester, () => !app!.workspace.busy);
        expect(app.workspace.status!.paused, isTrue);
        expect(
          app.workspace.status!.reason,
          anyOf('scope_changed', 'forbidden'),
        );
        expect(app.workspace.documents, isEmpty);
        expect(app.workspace.pending, isEmpty);
        await _stage(tester, control, 'permission_generation_purged');

        // Fresh reader generation uses the same real API JWT. No provider login
        // is implied by this recorded-token adapter or controller recreation.
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async => app!.close());
        app = makeApp();
        await tester.runAsync(() async => app!.initialize());
        await tester.pumpWidget(CosmosSyncApp(controller: app));
        await _tap(tester, find.byKey(const Key('connect-online')));
        await _wait(tester, () => app!.workspace.connected && !app.busy);
        expect(app.workspace.status!.paused, isFalse);
        expect(ownDocument().data!['value'], 'acknowledged-update');
        await _tap(tester, find.byKey(const Key('offline-switch')));
        await _wait(tester, () => !app!.workspace.busy);
        await _edit(
          tester,
          note,
          '{"value":"revoked-must-purge"}',
          existing: true,
        );
        await _wait(tester, () => !app!.workspace.busy);
        await tester.runAsync(() async => control.action('revoke'));
        await _tap(tester, find.byKey(const Key('offline-switch')));
        await _wait(tester, () => !app!.workspace.busy);
        expect(app.workspace.status!.paused, isTrue);
        expect(app.workspace.status!.reason, 'forbidden');
        expect(app.workspace.documents, isEmpty);
        expect(app.workspace.pending, isEmpty);
        await _stage(tester, control, 'revocation_purged');

        await _tap(tester, find.byKey(const Key('sign-out')));
        await _tap(tester, find.byKey(const Key('confirm-sign-out')));
        await _wait(tester, () => !app!.busy);
        expect(app.workspace.connected, isFalse);
        expect(app.auth.credentialSessionId, isNull);
        expect(memoryStore.value, isNull);
        await _stage(tester, control, 'local_signout_complete');
        debugPrint(
          'COSMOS_SYNC_AZURE_UI_PASS '
          'auth=recorded-real-provider-api-token tls=pinned-owned-ca '
          'ui=true sqlite=true cosmos=true offlineRestore=true '
          'grantDowngradePurge=true revocationPurge=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await peer?.close();
          await app?.close();
          await directory.delete(recursive: true);
        });
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}

Future<void> _stage(WidgetTester tester, _Control control, String value) =>
    tester.runAsync(() => control.stage(value));

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Private live UI operation did not complete.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _edit(
  WidgetTester tester,
  String id,
  String json, {
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

class _RecordedProviderToken implements OidcClient {
  _RecordedProviderToken(this.apiToken);
  final String apiToken;
  OidcTokens tokens() => OidcTokens(
    accessToken: apiToken,
    refreshToken: 'recorded-token-adapter-no-provider-refresh',
    tokenType: 'Bearer',
    expiresAt: DateTime.now().add(const Duration(minutes: 3)),
  );
  @override
  Future<OidcTokens> signIn(OidcConfig config) async => tokens();
  @override
  Future<OidcTokens> refresh(OidcConfig config, String refreshToken) async =>
      tokens();
  @override
  Future<void> endSession(OidcConfig config, String? idToken) async {}
}

class _BoundedClient extends http.BaseClient {
  _BoundedClient(String origin, List<int> certificate, this.control)
    : origin = Uri.parse(origin),
      inner = IOClient(
        HttpClient(
          context: SecurityContext(withTrustedRoots: false)
            ..setTrustedCertificatesBytes(certificate),
        )..connectionTimeout = const Duration(seconds: 10),
      );
  final Uri origin;
  final IOClient inner;
  final _Control control;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.scheme != 'https' ||
        request.url.host != '127.0.0.1' ||
        request.url.origin != origin.origin) {
      throw StateError('Only the owned pinned-TLS BFF is accepted.');
    }
    request.followRedirects = false;
    await control.permit(request.method, request.url.path);
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

class _Control {
  _Control(this.base) {
    if (base.scheme != 'http' ||
        base.host != '127.0.0.1' ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        !base.path.endsWith('/') ||
        base.pathSegments.where((item) => item.isNotEmpty).isEmpty) {
      throw StateError('Use the private approved Azure UI runner.');
    }
  }
  final Uri base;
  Future<Map<String, Object?>> configuration() => _request('GET', 'config');
  Future<void> stage(String value) async =>
      _request('POST', 'stage', {'stage': value});
  Future<void> action(String value) async =>
      _request('POST', 'action', {'action': value});
  Future<void> permit(String method, String path) async =>
      _request('POST', 'permit', {'method': method, 'path': path});
  Future<Map<String, Object?>> _request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await http.openUrl(method, base.resolve(path));
      request.followRedirects = false;
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != 200) {
        throw StateError('Private live UI control rejected the operation.');
      }
      final value = await utf8.decoder.bind(response).join();
      if (value.length > 32 * 1024) {
        throw StateError('Private control response exceeds bound.');
      }
      return (jsonDecode(value) as Map).cast<String, Object?>();
    } catch (_) {
      throw StateError('Private live UI control operation failed.');
    } finally {
      http.close(force: true);
    }
  }
}
