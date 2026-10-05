import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/owner_auth_gate.dart';

void main() {
  setUp(() {
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
  tearDown(() {
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets('foreground authentication requires one explicit owner tap', (
    tester,
  ) async {
    var starts = 0;
    await tester.pumpWidget(OwnerAuthGate(onStart: () => starts++));
    expect(starts, 0);
    final button = find.byKey(const ValueKey('owner_auth_start'));
    await tester.tap(button);
    await tester.pump();
    expect(starts, 1);
    expect(find.text('Sign-in started'), findsOneWidget);
    expect(tester.widget<ElevatedButton>(button).onPressed, null);
    await tester.tap(button);
    await tester.pump();
    expect(starts, 1);
  });

  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    testWidgets('$state cannot start authentication until resumed', (
      tester,
    ) async {
      var starts = 0;
      await tester.pumpWidget(OwnerAuthGate(onStart: () => starts++));
      WidgetsBinding.instance.handleAppLifecycleStateChanged(state);
      await tester.pump();
      final button = find.byKey(const ValueKey('owner_auth_start'));
      expect(tester.widget<ElevatedButton>(button).onPressed, null);
      await tester.tap(button);
      await tester.pump();
      expect(starts, 0);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      await tester.tap(button);
      await tester.pump();
      expect(starts, 1);
    });
  }

  testWidgets('disposing the gate removes its lifecycle observer', (
    tester,
  ) async {
    var starts = 0;
    await tester.pumpWidget(OwnerAuthGate(onStart: () => starts++));
    await tester.pumpWidget(const SizedBox());
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );
    await tester.pump();
    expect(starts, 0);
    expect(tester.takeException(), null);
  });
}
