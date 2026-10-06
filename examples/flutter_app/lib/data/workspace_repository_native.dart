import 'dart:convert';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:path/path.dart' as p;

import 'workspace_repository_base.dart';

class WorkspaceRepository extends WorkspaceRepositoryBase {
  WorkspaceRepository({required this.directory, super.transportFactory});

  final Directory directory;
  File get _index => File(p.join(directory.path, 'verified-session.json'));

  @override
  Future<void> prepare() => directory.create(recursive: true);

  @override
  Future<CacheStore> openCache(String identity) async =>
      SqliteCache(p.join(directory.path, '$identity.sqlite'));

  @override
  Future<Map<String, Object?>?> readIndex() async {
    if (!await _index.exists()) return null;
    try {
      return (jsonDecode(await _index.readAsString()) as Map)
          .cast<String, Object?>();
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> saveIndex(Map<String, Object?> value) async {
    final temporary = File('${_index.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(_index.path);
  }

  @override
  Future<void> purge() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
