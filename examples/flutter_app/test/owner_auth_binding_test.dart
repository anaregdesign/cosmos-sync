import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/owner_auth_binding.dart';
import '../integration_test/support/owner_auth_gate.dart';

void main() {
  final binding = LiveTestWidgetsFlutterBinding()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  setUp(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('manual owner gate accepts physical device taps once', (
    tester,
  ) async {
    final previous = binding.shouldPropagateDevicePointerEvents;
    var starts = 0;
    try {
      await tester.pumpWidget(OwnerAuthGate(onStart: () => starts++));
      final position = tester.getCenter(
        find.byKey(const ValueKey('owner_auth_start')),
      );
      _deviceTap(binding, tester.view.viewId, position, 1);
      await tester.pump();
      expect(starts, 0);

      configureOwnerAuthBinding(binding, manualStart: true);
      _deviceTap(binding, tester.view.viewId, position, 2);
      await tester.pump();
      expect(starts, 1);
      expect(find.text('Sign-in started'), findsOneWidget);
      _deviceTap(binding, tester.view.viewId, position, 3);
      await tester.pump();
      expect(starts, 1);
    } finally {
      binding.shouldPropagateDevicePointerEvents = previous;
    }
  });

  testWidgets('automatic mode keeps device events isolated from test taps', (
    tester,
  ) async {
    final previous = binding.shouldPropagateDevicePointerEvents;
    var starts = 0;
    try {
      configureOwnerAuthBinding(binding, manualStart: false);
      await tester.pumpWidget(OwnerAuthGate(onStart: () => starts++));
      final button = find.byKey(const ValueKey('owner_auth_start'));
      _deviceTap(binding, tester.view.viewId, tester.getCenter(button), 4);
      await tester.pump();
      expect(starts, 0);
      await tester.tap(button);
      await tester.pump();
      expect(starts, 1);
    } finally {
      binding.shouldPropagateDevicePointerEvents = previous;
    }
  });

  testWidgets('device input cannot bypass the foreground lifecycle gate', (
    tester,
  ) async {
    final previous = binding.shouldPropagateDevicePointerEvents;
    var starts = 0;
    try {
      configureOwnerAuthBinding(binding, manualStart: true);
      await tester.pumpWidget(OwnerAuthGate(onStart: () => starts++));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      final position = tester.getCenter(
        find.byKey(const ValueKey('owner_auth_start')),
      );
      _deviceTap(binding, tester.view.viewId, position, 5);
      await tester.pump();
      expect(starts, 0);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      _deviceTap(binding, tester.view.viewId, position, 6);
      await tester.pump();
      expect(starts, 1);
    } finally {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      binding.shouldPropagateDevicePointerEvents = previous;
    }
  });
}

void _deviceTap(
  TestWidgetsFlutterBinding binding,
  int viewId,
  Offset position,
  int pointer,
) {
  binding.handlePointerEventForSource(
    PointerDownEvent(viewId: viewId, pointer: pointer, position: position),
    source: TestBindingEventSource.device,
  );
  binding.handlePointerEventForSource(
    PointerUpEvent(viewId: viewId, pointer: pointer, position: position),
    source: TestBindingEventSource.device,
  );
}
