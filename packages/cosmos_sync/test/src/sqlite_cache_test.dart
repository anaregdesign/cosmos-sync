@TestOn('vm')
library;

import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String path;
  late SqliteCache cache;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('cosmos-cache-test-');
    path = '${directory.path}/cache.sqlite';
    cache = SqliteCache(path);
    cache.initialize(
      const SessionInfo(
        principalId: 'principal',
        scopeId: 'scope',
        permissionVersion: '1',
      ),
    );
  });
  tearDown(() {
    cache.close();
    directory.deleteSync(recursive: true);
  });

  ServerDocument document(String id, int version) => ServerDocument(
    id: id,
    data: {'version': version},
    version: version,
    deleted: false,
  );

  test('page documents, cursor and consistency envelope roll back together', () {
    cache.applyPage(
      SyncPage(
        changes: [document('existing', 1)],
        cursor: 'before',
        hasMore: false,
      ),
      'token-before',
    );
    final fault = sqlite3.open(path);
    fault.execute(
      "CREATE TRIGGER fail_sync BEFORE INSERT ON documents WHEN NEW.id = 'fail' BEGIN SELECT RAISE(ABORT, 'injected disk fault'); END",
    );
    fault.close();
    expect(
      () => cache.applyPage(
        SyncPage(
          changes: [document('first', 2), document('fail', 3)],
          cursor: 'after',
          hasMore: false,
        ),
        'token-after',
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(cache.get('first'), isNull);
    expect(cache.get('existing')!.version, 1);
    expect(cache.cursor, 'before');
    expect(cache.consistencyToken, 'token-before');
    cache.close();
    cache = SqliteCache(path);
    expect(cache.get('first'), isNull);
    expect(cache.cursor, 'before');
  });

  test('ACK base, pending removal and successor version bind atomically', () {
    cache.enqueue(
      operationId: 'first',
      documentId: 'note',
      kind: MutationKind.put,
      data: {'text': 'one'},
    );
    cache.enqueue(
      operationId: 'second',
      documentId: 'note',
      kind: MutationKind.put,
      data: {'text': 'two'},
    );
    final prepared = cache.prepare(cache.pending.first);
    final fault = sqlite3.open(path);
    fault.execute(
      "CREATE TRIGGER fail_ack BEFORE DELETE ON outbox WHEN OLD.operation_id = 'first' BEGIN SELECT RAISE(ABORT, 'injected disk fault'); END",
    );
    fault.close();
    expect(
      () => cache.acknowledge(prepared, document('note', 1), 'token'),
      throwsA(isA<SqliteException>()),
    );
    expect(cache.pending, hasLength(2));
    expect(cache.pending.last.predecessorOperationId, 'first');
    expect(cache.pending.last.observedVersion, 0);
    expect(cache.get('note')!.version, 0);
    expect(cache.consistencyToken, isNull);
  });

  test('explicit conflict retry links successor to new operation ID', () {
    cache.enqueue(
      operationId: 'first',
      documentId: 'note',
      kind: MutationKind.put,
      data: {'text': 'one'},
    );
    cache.enqueue(
      operationId: 'second',
      documentId: 'note',
      kind: MutationKind.put,
      data: {'text': 'two'},
    );
    cache.markConflict(cache.prepare(cache.pending.first), document('note', 5));
    cache.retryConflict('first', 'retried');
    expect(cache.pending.first.operationId, 'retried');
    expect(cache.pending.first.observedVersion, 5);
    expect(cache.pending.last.predecessorOperationId, 'retried');
    final prepared = cache.prepare(cache.pending.first);
    cache.acknowledge(prepared, document('note', 6), 'token');
    expect(cache.pending.single.observedVersion, 6);
    expect(cache.pending.single.predecessorOperationId, isNull);
    expect(cache.prepare(cache.pending.single).baseVersion, 6);
  });

  test(
    'discarding conflict conservatively retains successor original base',
    () {
      cache.enqueue(
        operationId: 'first',
        documentId: 'note',
        kind: MutationKind.put,
        data: {'text': 'one'},
      );
      cache.enqueue(
        operationId: 'second',
        documentId: 'note',
        kind: MutationKind.put,
        data: {'text': 'two'},
      );
      cache.markConflict(
        cache.prepare(cache.pending.first),
        document('note', 5),
      );
      cache.discard('first');
      expect(cache.pending.single.predecessorOperationId, isNull);
      expect(cache.prepare(cache.pending.single).baseVersion, 0);
    },
  );
}
