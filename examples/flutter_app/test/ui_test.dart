import 'dart:io';

import 'package:cosmos_sync_example/auth/auth_session_controller.dart';
import 'package:cosmos_sync_example/data/workspace_repository.dart';
import 'package:cosmos_sync_example/main.dart';
import 'package:cosmos_sync_example/ui/app_controller.dart';
import 'package:cosmos_sync_example/ui/workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'ordinary startup exposes usable configuration and rejects identity-only scopes',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('cosmos-app-ui-');
      final controller = AppController(
        auth: AuthSessionController(),
        workspace: WorkspaceController(
          repository: WorkspaceRepository(directory: directory),
        ),
        settingsFile: File('${directory.path}/connection.json'),
      );
      await tester.pumpWidget(CosmosSyncApp(controller: controller));
      expect(find.byKey(const Key('bff-url')), findsOneWidget);
      expect(find.byKey(const Key('sign-in')), findsOneWidget);
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
}
