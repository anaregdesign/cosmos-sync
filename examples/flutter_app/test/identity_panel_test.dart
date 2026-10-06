import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:cosmos_sync_example/ui/identity_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final capabilities = IdentityCapabilities(
    targets: [
      IdentityProofTarget(
        issuer: 'https://issuer.example.test/tenant',
        provider: 'entra',
        namespace: 'fixture-v1',
        clientId: '22222222-2222-4222-8222-222222222222',
        callback: 'com.anaregdesign.cosmossync://auth/oauthredirect',
      ),
    ],
    freshAuthenticationSeconds: 300,
    maximumIdentities: 8,
    recovery: 'remaining-identity-only',
    deletion: 'operator-review-required',
    migration: 'operator-review-required',
  );
  IdentityAccount account(int count) => IdentityAccount(
    account: BuiltinAccount(accountId: 'a' * 64, personalScopeId: 'b' * 64),
    identityGeneration: 2,
    currentIdentityId: 'c' * 64,
    identities: [
      AccountIdentityCredential(identityId: 'c' * 64, provider: 'entra'),
      for (var index = 1; index < count; index++)
        AccountIdentityCredential(
          identityId: index.toRadixString(16).padLeft(64, '0'),
          provider: 'entra',
        ),
    ],
  );
  var registrations = 0;
  var links = 0;
  var recoveries = 0;
  var cancellations = 0;
  String? removed;
  setUp(() {
    registrations = links = recoveries = cancellations = 0;
    removed = null;
  });
  Widget panel({
    IdentityAccount? value,
    bool registration = false,
    bool enabled = true,
    bool proving = false,
  }) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: IdentityPanel(
          capabilities: capabilities,
          account: value,
          registrationRequired: registration,
          enabled: enabled,
          proving: proving,
          onRegister: () => registrations++,
          onLink: () => links++,
          onUnlink: (id) => removed = id,
          onRecover: () => recoveries++,
          onCancel: () => cancellations++,
        ),
      ),
    ),
  );

  testWidgets(
    'registration and remaining-identity recovery are explicit actions',
    (tester) async {
      await tester.pumpWidget(panel(registration: true));
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const Key('link-identity')), findsNothing);
      await tester.tap(find.byKey(const Key('register-account')));
      await tester.tap(find.byKey(const Key('recover-account')));
      expect(registrations, 1);
      expect(recoveries, 1);
      expect(find.textContaining('operator review'), findsOneWidget);
    },
  );

  testWidgets('last-credential removal and capacity growth fail visibly', (
    tester,
  ) async {
    await tester.pumpWidget(panel(value: account(1)));
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(Key('unlink-${'c' * 64}')))
          .onPressed,
      null,
    );
    expect(find.text('The last credential cannot be removed.'), findsOneWidget);
    await tester.tap(find.byKey(Key('unlink-${'c' * 64}')));
    expect(removed, null);
    await tester.tap(find.byKey(const Key('link-identity')));
    expect(links, 1);
    await tester.pumpWidget(panel(value: account(8)));
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('link-identity')))
          .onPressed,
      null,
    );
    await tester.tap(find.byKey(Key('unlink-${'c' * 64}')));
    expect(removed, 'c' * 64);
  });

  testWidgets(
    'offline or busy actions stay disabled while proof cancellation remains usable',
    (tester) async {
      await tester.pumpWidget(
        panel(value: account(2), enabled: false, proving: true),
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(Key('unlink-${'c' * 64}')))
            .onPressed,
        null,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('recover-account')))
            .onPressed,
        null,
      );
      await tester.tap(find.byKey(const Key('cancel-identity-proof')));
      expect(cancellations, 1);
    },
  );

  testWidgets(
    'narrow linked-account preview renders without native plugins or token inputs',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(identityPanelPreview());
      expect(tester.takeException(), null);
      expect(find.byType(TextField), findsNothing);
      final remove = find.byKey(Key('unlink-${'c' * 64}'));
      expect(remove, findsOneWidget);
    },
  );
}
