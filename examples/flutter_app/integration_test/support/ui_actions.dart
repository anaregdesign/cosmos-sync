import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> waitFor(
  WidgetTester tester,
  bool Function() ready, {
  void Function()? onTimeout,
}) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) {
        onTimeout?.call();
        throw TimeoutException('App operation did not finish.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> edit(
  WidgetTester tester, {
  required String id,
  required String json,
  bool existing = false,
}) async {
  await tap(
    tester,
    find.byKey(Key(existing ? 'document-$id' : 'new-document')),
  );
  await tester.pumpAndSettle();
  if (!existing) {
    await tester.enterText(find.byKey(const Key('document-id')), id);
  }
  await tester.enterText(find.byKey(const Key('document-json')), json);
  await tap(tester, find.byKey(const Key('save-document')));
}
