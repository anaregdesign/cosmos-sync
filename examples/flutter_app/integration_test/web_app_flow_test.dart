@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:cosmos_sync_example/auth/auth_session_controller.dart';
import 'package:cosmos_sync_example/auth/web_oidc.dart';
import 'package:cosmos_sync_example/data/settings_store_web.dart';
import 'package:cosmos_sync_example/data/workspace_repository_web.dart';
import 'package:cosmos_sync_example/main.dart';
import 'package:cosmos_sync_example/ui/app_controller.dart';
import 'package:cosmos_sync_example/ui/workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:web/web.dart' as web;

import 'support/ui_actions.dart' as ui;

/// Only this integration target has a signed-fixture OIDC adapter. Ordinary
/// main.dart always uses MSAL; no token or test switch enters its configuration.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final reloaded = Uri.base.queryParameters['phase'] == 'reloaded';
  var completed = false;
  var failureStage = 'startup';
  String? operation;
  final origin = Uri.base.replace(path: '/', query: null, fragment: null);
  if (origin.scheme != 'http' || origin.host != '127.0.0.1') {
    throw StateError('Use the owned loopback Web fixture.');
  }
  unawaited(
    binding.allTestsPassed.future.then((passed) async {
      if (passed && completed && !reloaded) {
        await _post(origin.resolve('checkpoint'), {'operation': operation});
        web.window.location.replace(
          origin.replace(queryParameters: {'phase': 'reloaded'}).toString(),
        );
      } else {
        await _post(origin.resolve('result'), {
          'passed': passed && completed && reloaded,
          'real_http': completed && reloaded,
          'real_indexeddb': completed && reloaded,
          'document_reload': reloaded,
          'offline_rebind_refused': completed && reloaded,
          'exact_operation_retained': completed && reloaded,
          'server_ack': completed && reloaded,
          'logout_purge': completed && reloaded,
          'auth': 'signed_test_issuer_adapter',
          if (!passed) 'failure_stage': failureStage,
          if (!passed)
            'failure_source_lines': binding.failureMethodsDetails
                .expand(
                  (failure) => RegExp(r'web_app_flow_test\.dart:(\d+)')
                      .allMatches(failure.details ?? '')
                      .map((match) => int.parse(match.group(1)!)),
                )
                .toSet()
                .toList(),
        });
      }
    }),
  );

  testWidgets(
    'Web UI verifies JWT HTTP and IndexedDB across an actual document reload',
    (tester) async {
      final response = await http
          .get(origin.resolve('fixture'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 || response.body.length > 32768) {
        throw StateError('The signed Web fixture is not ready.');
      }
      final fixture = jsonDecode(response.body) as Map<String, dynamic>;
      final namespace = fixture['namespace'] as String;
      final repository = WorkspaceRepository(namespace: namespace);
      final store = BrowserSettingsStore(key: '$namespace.connection');
      final auth = AuthSessionController(
        oidc: _FixtureOidc(fixture['token'] as String),
        tokenStore: MemoryRefreshTokenStore(),
      );
      final app = AppController(
        auth: auth,
        workspace: WorkspaceController(repository: repository),
        settingsStore: store,
      );
      try {
        if (reloaded) await app.initialize();
        await tester.pumpWidget(CosmosSyncApp(controller: app));
        if (!reloaded) {
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
            'signed-web-fixture',
          );
          await tester.enterText(
            find.byKey(const Key('oidc-scopes')),
            'openid cosmos_sync',
          );
          await ui.tap(tester, find.byType(CheckboxListTile));
          await ui.tap(tester, find.byKey(const Key('sign-in')));
          await ui.waitFor(
            tester,
            () => app.workspace.connected && !app.busy && !app.workspace.busy,
          );
          expect(app.workspace.bootstrapComplete, true);
          expect(app.auth.hasStoredSession, false);
          await ui.tap(tester, find.byKey(const Key('offline-switch')));
          await ui.waitFor(tester, () => !app.workspace.busy);
          await ui.edit(
            tester,
            id: 'web-note',
            json: '{"text":"before reload"}',
          );
          await ui.waitFor(tester, () => !app.workspace.busy);
          operation = app.workspace.pending.single.operationId;
          expect(app.workspace.documents.single.hasPendingWrites, true);
          expect(
            await store.read(),
            isNot(contains(fixture['token'] as String)),
          );
          expect(
            web.window.localStorage.getItem('$namespace.cache-registry'),
            isNot(contains(fixture['token'] as String)),
          );
        } else {
          failureStage = 'reload-signed-out';
          expect(app.settings!.oidc.browser, true);
          expect(app.auth.isSignedIn, false);
          expect(app.auth.restoredSession, false);
          expect(app.workspace.documents, isEmpty);
          expect(
            tester
                .widget<OutlinedButton>(
                  find.byKey(const Key('connect-offline')),
                )
                .onPressed,
            null,
          );
          await expectLater(
            repository.open(
              config: app.settings!.connection,
              credentialBinding: 'no-restored-browser-credential',
              tokenProvider: () async =>
                  throw StateError('No offline token request.'),
              offline: true,
            ),
            throwsStateError,
          );

          failureStage = 'reload-interactive-sign-in';
          await auth.signIn();
          failureStage = 'online-rebind';
          final rebound = await repository.open(
            config: app.settings!.connection,
            credentialBinding: auth.credentialSessionId!,
            tokenProvider: auth.accessToken,
          );
          try {
            failureStage = 'retained-operation';
            expect(rebound.pending.single.operationId, fixture['operation']);
            expect(rebound.get('web-note')!.data!['text'], 'before reload');
          } finally {
            await rebound.close();
          }
          await tester.pumpAndSettle();
          failureStage = 'online-connect';
          await ui.tap(tester, find.byKey(const Key('connect-online')));
          await ui.waitFor(
            tester,
            () => app.workspace.connected && !app.busy && !app.workspace.busy,
          );
          failureStage = 'server-ack';
          expect(app.workspace.pending, isEmpty);
          expect(app.workspace.documents.single.hasPendingWrites, false);
          expect(find.byKey(const Key('document-web-note')), findsOneWidget);
          await ui.tap(tester, find.byKey(const Key('offline-switch')));
          await ui.waitFor(tester, () => !app.workspace.busy);
          await ui.edit(tester, id: 'purge-me', json: '{"text":"unsent"}');
          await ui.waitFor(tester, () => !app.workspace.busy);
          failureStage = 'logout';
          await ui.tap(tester, find.byKey(const Key('sign-out')));
          await ui.tap(tester, find.byKey(const Key('confirm-sign-out')));
          await ui.waitFor(tester, () => !app.busy);
          expect(app.auth.credentialSessionId, null);
          expect(app.workspace.connected, false);
          expect(app.workspace.documents, isEmpty);
          expect(app.workspace.pending, isEmpty);
          expect(
            web.window.localStorage.getItem('$namespace.cache-registry'),
            null,
          );
        }
        completed = true;
      } finally {
        await tester.pumpWidget(const SizedBox());
        await app.close();
      }
    },
  );
}

Future<void> _post(Uri url, Map<String, Object?> value) async {
  final response = await http
      .post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(value),
      )
      .timeout(const Duration(seconds: 10));
  if (response.statusCode != 204) {
    throw StateError('Web fixture reporting failed.');
  }
}

class _FixtureOidc implements MemoryOidcClient {
  _FixtureOidc(this.token);
  final String token;
  OidcTokens _tokens() => OidcTokens(
    accessToken: token,
    tokenType: 'Bearer',
    expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    scopes: ['cosmos_sync'],
  );
  @override
  Future<OidcTokens> signIn(OidcConfig config) async => _tokens();
  @override
  Future<OidcTokens> refreshCurrent(OidcConfig config) async => _tokens();
  @override
  Future<OidcTokens> refresh(OidcConfig config, String refreshToken) async =>
      throw StateError('No exported browser refresh token.');
  @override
  Future<void> clearSession() async {}
  @override
  Future<void> endSession(OidcConfig config, String? idToken) async {}
}
