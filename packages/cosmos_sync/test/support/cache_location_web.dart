import 'dart:async';
import 'dart:js_interop';
import 'dart:math';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:cosmos_sync/src/indexed_db_cache.dart';
import 'package:web/web.dart' as web;

class TestCacheLocation {
  TestCacheLocation._(this.name);
  final String name;
  Future<CacheStore> open() => IndexedDbCache.open(name);
  Future<void> cleanup() {
    final result = Completer<void>();
    final request = web.window.indexedDB.deleteDatabase(name);
    request.onsuccess = ((web.Event _) => result.complete()).toJS;
    request.onerror = ((web.Event _) => result.completeError(
      StateError('Could not delete test IndexedDB.'),
    )).toJS;
    request.onblocked = ((web.Event _) => result.completeError(
      StateError('Test IndexedDB deletion is blocked.'),
    )).toJS;
    return result.future.timeout(const Duration(seconds: 5));
  }
}

Future<TestCacheLocation>
createTestCacheLocation() async => TestCacheLocation._(
  'cosmos-conformance-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}',
);
