import 'dart:async';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';

const session = SessionInfo(
  scopeId: 'crash-scope',
  principalId: 'crash-principal',
  permissionVersion: '1',
);

Future<void> main(List<String> arguments) async {
  final CacheStore cache = SqliteCache(arguments[1]);
  if (arguments[0] == 'write') {
    await cache.initialize(session);
    await cache.applyPage(
      SyncPage(
        changes: [
          ServerDocument(
            id: 'note',
            data: {'value': 'confirmed'},
            version: 1,
            deleted: false,
          ),
        ],
        cursor: 'durable-cursor-1',
        hasMore: false,
      ),
      'durable-session-1',
    );
    await cache.enqueue(
      operationId: 'd1858280-6f5a-4f74-87a8-1cf3cb989d39',
      documentId: 'note',
      kind: MutationKind.put,
      data: {'value': 'pending'},
    );
    final locked = await cache.prepare(cache.pending.single);
    if (locked.baseVersion != 1) throw StateError('base not observed');
    await cache.defer(locked, DateTime.utc(2030), 'network_error');
    File(arguments[2]).writeAsStringSync('ready', flush: true);
    // The orchestrator SIGKILLs this process; intentionally do not close SQLite.
    await Completer<void>().future;
  } else {
    try {
      final pending = cache.pending.single;
      if (cache.cursor != 'durable-cursor-1' ||
          cache.consistencyToken != 'durable-session-1' ||
          cache.bootstrapIncomplete ||
          cache.session?.principalId != 'crash-principal' ||
          pending.operationId != 'd1858280-6f5a-4f74-87a8-1cf3cb989d39' ||
          pending.baseVersion != 1 ||
          pending.attempts < 1 ||
          pending.nextAttemptAt != DateTime.utc(2030) ||
          cache.get('note')!.data!['value'] != 'pending') {
        throw StateError(
          'committed state was not restored after process death',
        );
      }
      stdout.writeln(
        'PASS SIGKILL recovery: cursor/session/observed base/locked operation/retry/overlay and ownership release',
      );
    } finally {
      await cache.close();
    }
  }
}
