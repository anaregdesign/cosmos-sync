import 'package:cosmos_sync_example/auth/oidc.dart';
import 'package:cosmos_sync_example/ui/browser_auth_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'explicit selection advertises the correct callback/proof boundary',
    (tester) async {
      var selected = BrowserAuthAdapter.entra;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => BrowserAuthSelector(
                value: selected,
                onChanged: (value) => setState(() => selected = value),
              ),
            ),
          ),
        ),
      );
      expect(
        find.text('Use the registered Entra SPA client and MSAL callback.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('browser-auth-adapter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generic OIDC (Code + PKCE)').last);
      await tester.pumpAndSettle();
      expect(selected, BrowserAuthAdapter.oidc);
      expect(
        find.textContaining('Entra directory linking is not supported'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the selector and isolated preview are constrained and contain no native clients',
    (tester) async {
      await tester.pumpWidget(browserAuthSelectorPreview());
      expect(find.byKey(const Key('browser-auth-adapter')), findsOneWidget);
      expect(
        find.textContaining('Entra directory linking is not supported'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BrowserAuthSelector(
              value: BrowserAuthAdapter.oidc,
              onChanged: null,
            ),
          ),
        ),
      );
      final field = tester.widget<DropdownButtonFormField<BrowserAuthAdapter>>(
        find.byKey(const Key('browser-auth-adapter')),
      );
      expect(field.onChanged, isNull);
    },
  );
}
