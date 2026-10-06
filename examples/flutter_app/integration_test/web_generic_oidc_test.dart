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

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final reloaded = Uri.base.queryParameters['phase'] == 'reloaded';
  final origin = Uri.base.replace(path: '/', query: null, fragment: null);
  var completed = false;
  var stage = 'startup';
  String? operation;
  if (origin.scheme != 'http' || origin.host != '127.0.0.1') {
    throw StateError('Use the owned loopback browser OIDC fixture.');
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
          'different_identity_isolated': completed && reloaded,
          'auth': 'actual_generic_oidc_popup',
          if (!passed) 'failure_stage': stage,
          if (!passed)
            'failure_source_lines': binding.failureMethodsDetails
                .expand(
                  (failure) => RegExp(r'web_generic_oidc_test\.dart:(\d+)')
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
    'actual generic Web OIDC isolates API-verified caches across reload and subjects',
    (tester) async {
      final response = await http
          .get(origin.resolve('fixture'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 || response.body.length > 32768) {
        throw StateError(
          'Browser OIDC fixture public configuration is unavailable.',
        );
      }
      final fixture = jsonDecode(response.body) as Map<String, dynamic>;
      final namespace = fixture['namespace'] as String;
      final store = BrowserSettingsStore(key: '$namespace.connection');
      AppController createApp() => AppController(
        auth: AuthSessionController(
          oidc: WebOidcClient(),
          tokenStore: MemoryRefreshTokenStore(),
        ),
        workspace: WorkspaceController(
          repository: WorkspaceRepository(namespace: namespace),
        ),
        settingsStore: store,
      );
      var app = createApp();
      Future<void> selectSubject(String subject) => _post(
        Uri.parse(fixture['issuer'] as String).resolve('/_fixture/options'),
        {'mode': 'normal', 'subject': subject},
      );
      try {
        if (reloaded) await app.initialize();
        await tester.pumpWidget(CosmosSyncApp(controller: app));
        if (!reloaded) {
          stage = 'configure-generic-ui';
          await tester.tap(find.byKey(const Key('browser-auth-adapter')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Generic OIDC (Code + PKCE)').last);
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('bff-url')),
            fixture['url'] as String,
          );
          await tester.enterText(
            find.byKey(const Key('oidc-issuer')),
            fixture['issuer'] as String,
          );
          await tester.enterText(
            find.byKey(const Key('oidc-client')),
            fixture['clientId'] as String,
          );
          await tester.enterText(
            find.byKey(const Key('oidc-scopes')),
            'openid offline_access cosmos_sync',
          );
          await ui.tap(tester, find.byType(CheckboxListTile));
          stage = 'real-popup-api-bind';
          await ui.tap(tester, find.byKey(const Key('sign-in')));
          await ui.waitFor(
            tester,
            () => app.workspace.connected && !app.busy && !app.workspace.busy,
          );
          expect(app.settings!.oidc.browserAdapter, BrowserAuthAdapter.oidc);
          expect(app.settings!.oidc.redirectUrl, fixture['redirectUrl']);
          expect(app.workspace.bootstrapComplete, true);
          expect(app.auth.supportsFreshIdentityProof, false);
          expect(app.auth.hasStoredSession, false);
          await ui.tap(tester, find.byKey(const Key('offline-switch')));
          await ui.waitFor(tester, () => !app.workspace.busy);
          await ui.edit(
            tester,
            id: 'oidc-note',
            json: '{"text":"before OIDC reload"}',
          );
          await ui.waitFor(tester, () => !app.workspace.busy);
          operation = app.workspace.pending.single.operationId;
          final saved = await store.read();
          expect(saved, contains('"browserAdapter":"oidc"'));
          expect(saved, isNot(contains('accessToken')));
          expect(saved, isNot(contains('refreshToken')));
          expect(saved, isNot(contains('idToken')));
        } else {
          stage = 'reload-signed-out';
          expect(app.settings!.oidc.browserAdapter, BrowserAuthAdapter.oidc);
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
            app.workspace.repository.open(
              config: app.settings!.connection,
              credentialBinding: 'no-restored-browser-credential',
              tokenProvider: () async =>
                  throw StateError('No offline token request.'),
              offline: true,
            ),
            throwsStateError,
          );

          stage = 'different-identity-isolated';
          await selectSubject('bob');
          await ui.tap(tester, find.byKey(const Key('sign-in')));
          await ui.waitFor(
            tester,
            () => app.workspace.connected && !app.busy && !app.workspace.busy,
          );
          expect(app.workspace.pending, isEmpty);
          expect(app.workspace.documents, isEmpty);
          await tester.pumpWidget(const SizedBox());
          await app.close();

          stage = 'reload-original-identity';
          await selectSubject('alice');
          app = createApp();
          await app.initialize();
          await tester.pumpWidget(CosmosSyncApp(controller: app));
          await tester.runAsync(app.auth.signIn);
          final rebound = await app.workspace.repository.open(
            config: app.settings!.connection,
            credentialBinding: app.auth.credentialSessionId!,
            tokenProvider: app.auth.accessToken,
          );
          try {
            stage = 'retained-operation';
            expect(rebound.pending.single.operationId, fixture['operation']);
            expect(
              rebound.get('oidc-note')!.data!['text'],
              'before OIDC reload',
            );
          } finally {
            await rebound.close();
          }
          stage = 'server-ack';
          await ui.tap(tester, find.byKey(const Key('connect-online')));
          await ui.waitFor(
            tester,
            () => app.workspace.connected && !app.busy && !app.workspace.busy,
          );
          expect(app.workspace.pending, isEmpty);
          expect(app.workspace.documents.single.hasPendingWrites, false);
          expect(find.byKey(const Key('document-oidc-note')), findsOneWidget);
          await ui.tap(tester, find.byKey(const Key('offline-switch')));
          await ui.waitFor(tester, () => !app.workspace.busy);
          await ui.edit(tester, id: 'purge-me', json: '{"text":"unsent"}');
          await ui.waitFor(tester, () => !app.workspace.busy);
          stage = 'logout';
          await ui.tap(tester, find.byKey(const Key('sign-out')));
          await ui.tap(tester, find.byKey(const Key('confirm-sign-out')));
          await ui.waitFor(tester, () => !app.busy);
          expect(app.auth.credentialSessionId, null);
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

Future<void> _post(Uri uri, Map<String, Object?> value) async {
  final response = await http
      .post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(value),
      )
      .timeout(const Duration(seconds: 10));
  if (response.statusCode != 204) {
    throw StateError('Browser OIDC fixture control failed.');
  }
}
