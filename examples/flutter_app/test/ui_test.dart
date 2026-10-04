import 'dart:async';
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

void main() {
  testWidgets(
    'configured shared workspace has a fixed explicit scope selection',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'cosmos-app-shared-ui-',
      );
      final controller = AppController(
        auth: AuthSessionController(),
        workspace: WorkspaceController(
          repository: WorkspaceRepository(directory: directory),
        ),
        settingsStore: FileSettingsStore(
          File('${directory.path}/connection.json'),
        ),
        sharedScopeId: 'b' * 64,
      );
      await tester.pumpWidget(CosmosSyncApp(controller: controller));
      final field = tester.widget<DropdownButtonFormField<SyncScopeMode>>(
        find.byKey(const Key('scope-mode')),
      );
      expect(field.initialValue, SyncScopeMode.shared);
      expect(field.onChanged, isNull);
      expect(find.text('Shared workspace (owner-provided)'), findsWidgets);
      expect(find.text('Legacy tenant scope'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await controller.close();
      directory.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'ordinary startup exposes usable configuration and rejects identity-only scopes',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('cosmos-app-ui-');
      final controller = AppController(
        auth: AuthSessionController(),
        workspace: WorkspaceController(
          repository: WorkspaceRepository(directory: directory),
        ),
        settingsStore: FileSettingsStore(
          File('${directory.path}/connection.json'),
        ),
      );
      await tester.pumpWidget(CosmosSyncApp(controller: controller));
      expect(find.byKey(const Key('bff-url')), findsOneWidget);
      expect(find.byKey(const Key('sign-in')), findsOneWidget);
      expect(find.byKey(const Key('sign-in-google')), findsNothing);
      expect(find.byKey(const Key('sign-in-apple')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('bff-url')),
        'https://bff.example.test',
      );
      await tester.enterText(
        find.byKey(const Key('oidc-issuer')),
        'https://issuer.example.test',
      );
      await tester.enterText(
        find.byKey(const Key('oidc-client')),
        'native-client',
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('sign-in')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sign-in')));
      await tester.pump();
      expect(find.byKey(const Key('error-message')), findsOneWidget);
      expect(controller.auth.state, AuthSessionState.unconfigured);
      await tester.pumpWidget(const SizedBox());
      await controller.close();
      directory.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'provider buttons require matching public capabilities and share cancellation',
    (tester) async {
      const issuer = 'https://consumer.ciamlogin.com/tenant/v2.0';
      final directory = Directory.systemTemp.createTempSync(
        'cosmos-broker-ui-',
      );
      final oidc = _PendingOidc();
      final store = _Store();
      late AppController controller;
      // Keep the secure-store queue in the real async zone used by disk and
      // external-browser work, rather than the widget test's fake async zone.
      await tester.runAsync(() async {
        controller = AppController(
          auth: AuthSessionController(oidc: oidc, tokenStore: store),
          workspace: WorkspaceController(
            repository: WorkspaceRepository(directory: directory),
          ),
          settingsStore: FileSettingsStore(
            File('${directory.path}/connection.json'),
          ),
          brokerCapabilities: EntraBrokerCapabilities(
            issuer: issuer,
            clientId: 'native-public',
            providers: [BrokerProvider.google, BrokerProvider.apple],
          ),
        );
      });
      await tester.pumpWidget(CosmosSyncApp(controller: controller));
      expect(find.byKey(const Key('sign-in-google')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('bff-url')),
        'https://bff.example.test',
      );
      await tester.enterText(find.byKey(const Key('oidc-issuer')), issuer);
      await tester.enterText(
        find.byKey(const Key('oidc-client')),
        'native-public',
      );
      await tester.enterText(
        find.byKey(const Key('oidc-scopes')),
        'openid offline_access api://bff/Cosmos.Sync',
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sign-in-google')), findsOneWidget);
      expect(find.byKey(const Key('sign-in-apple')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('oidc-client')),
        'another-client',
      );
      await tester.pump();
      expect(find.byKey(const Key('sign-in-google')), findsNothing);
      expect(find.byKey(const Key('sign-in-apple')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('oidc-client')),
        'native-public',
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('sign-in-apple')));
      await tester.pumpAndSettle();
      final signIn = tester
          .widget<OutlinedButton>(find.byKey(const Key('sign-in-apple')))
          .onPressed!;
      // Disk persistence and the pending external browser use real async work.
      await tester.runAsync(() async {
        signIn();
        await oidc.launched.future;
      });
      await tester.pump();
      expect(oidc.config!.brokerProvider, BrokerProvider.apple);
      expect(controller.auth.state, AuthSessionState.authorizing);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('sign-in-google')))
            .onPressed,
        null,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('sign-in-apple')))
            .onPressed,
        null,
      );
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('sign-in'))).onPressed,
        null,
      );
      await tester.ensureVisible(find.byKey(const Key('cancel-sign-in')));
      await tester.pump();
      final cancel = tester
          .widget<TextButton>(find.byKey(const Key('cancel-sign-in')))
          .onPressed!;
      await tester.runAsync(() async {
        cancel();
        oidc.response.complete(
          OidcTokens(
            accessToken: 'late-secret',
            refreshToken: 'late-refresh-secret',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
            tokenType: 'Bearer',
          ),
        );
        while (controller.busy) {
          await Future<void>.delayed(Duration.zero);
        }
      });
      await tester.pumpAndSettle();
      expect(controller.auth.isSignedIn, false);
      expect(controller.workspace.connected, false);
      expect(controller.workspace.documents, isEmpty);
      expect(store.value, null);
      expect(find.textContaining('late-secret'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await controller.close();
      directory.deleteSync(recursive: true);
    },
  );
}

class _PendingOidc implements OidcClient {
  final launched = Completer<void>.sync();
  final response = Completer<OidcTokens>.sync();
  OidcConfig? config;
  @override
  Future<OidcTokens> signIn(OidcConfig config) {
    this.config = config;
    launched.complete();
    return response.future;
  }

  @override
  Future<OidcTokens> refresh(OidcConfig config, String refreshToken) =>
      throw StateError('Refresh must not be called.');
  @override
  Future<void> endSession(OidcConfig config, String? idToken) async {}
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
