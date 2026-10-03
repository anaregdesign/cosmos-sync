import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';

class TestCacheLocation {
  TestCacheLocation._(this._directory);
  final Directory _directory;
  String get name => '${_directory.path}/cache.sqlite';
  Future<CacheStore> open() async => SqliteCache(name);
  Future<void> cleanup() async => _directory.deleteSync(recursive: true);
}

Future<TestCacheLocation> createTestCacheLocation() async =>
    TestCacheLocation._(
      Directory.systemTemp.createTempSync('cosmos-conformance-'),
    );
