@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:cosmos_sync/src/indexed_db_cache.dart';
import 'package:cosmos_sync/src/models.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

const _scope = SessionInfo(
  scopeId: 'scope',
  principalId: 'principal',
  permissionVersion: '1',
  scopeMode: SyncScopeMode.user,
);

ServerDocument _document(
  String id,
  int version, {
  String? text,
  bool deleted = false,
}) => ServerDocument(
  id: id,
  data: deleted ? null : {'text': text ?? 'server-$version'},
  version: version,
  deleted: deleted,
);

SyncPage _page(
  List<ServerDocument> changes, {
  String cursor = 'cursor',
  bool hasMore = false,
}) => SyncPage(changes: changes, cursor: cursor, hasMore: hasMore);

Future<void> _deleteDatabase(String name) {
  final completed = Completer<void>();
  final request = web.window.indexedDB.deleteDatabase(name);
  request.onsuccess = ((web.Event _) => completed.complete()).toJS;
  request.onerror = ((web.Event _) => completed.completeError(
    StateError('Could not delete test database.'),
  )).toJS;
  request.onblocked = ((web.Event _) => completed.completeError(
    StateError('Test database deletion was blocked.'),
  )).toJS;
  return completed.future;
}

void main() {
  late String name;
  late IndexedDbCache cache;
  var sequence = 0;
  var abortNext = false;
  void Function(web.IDBTransaction)? observeTransaction;

  Future<void> reopen() async {
    await cache.close();
    cache = await IndexedDbCache.open(
      name,
      transactionHookForTesting: (transaction) {
        observeTransaction?.call(transaction);
        if (abortNext) {
          abortNext = false;
          transaction.abort();
        }
      },
    );
  }

  Future<void> enqueue(
    String operation,
    String document,
    String text, {
    MutationKind kind = MutationKind.put,
  }) => cache.enqueue(
    operationId: operation,
    documentId: document,
    kind: kind,
    data: kind == MutationKind.delete ? null : {'text': text},
  );

  setUp(() async {
    name =
        'cosmos-sync-browser-${DateTime.now().microsecondsSinceEpoch}-${sequence++}';
    abortNext = false;
    observeTransaction = null;
    cache = await IndexedDbCache.open(
      name,
      transactionHookForTesting: (transaction) {
        observeTransaction?.call(transaction);
        if (abortNext) {
          abortNext = false;
          transaction.abort();
        }
      },
    );
    await cache.initialize(_scope);
  });

  tearDown(() async {
    observeTransaction = null;
    await cache.close();
    await _deleteDatabase(name);
  });

  test('strict native commit precedes the new synchronous read view', () async {
    expect(web.window.isSecureContext, isTrue);
    observeTransaction = (transaction) {
      expect(transaction.mode, 'readwrite');
      expect(transaction.durability, 'strict');
      expect(cache.pendingCount, 0);
      expect(cache.get('note'), isNull);
    };
    final write = enqueue('first', 'note', 'local');
    expect(cache.pendingCount, 0);
    await write;
    observeTransaction = null;
    expect(cache.pendingCount, 1);
    expect(cache.get('note')!.data, {'text': 'local'});
    expect(cache.get('note')!.hasPendingWrites, isTrue);
    await reopen();
    expect(cache.pending.single.operationId, 'first');
    expect(cache.session!.sameScope(_scope), isTrue);
    expect(cache.bootstrapIncomplete, isTrue);
  });

  test('unsupported Web Locks fail before creating a database', () async {
    final navigator = web.window.navigator;
    final object = globalContext.getProperty<JSObject>('Object'.toJS);
    final previous = object.callMethod<JSAny?>(
      'getOwnPropertyDescriptor'.toJS,
      navigator,
      'locks'.toJS,
    );
    object.callMethod<JSAny?>(
      'defineProperty'.toJS,
      navigator,
      'locks'.toJS,
      {'value': null, 'configurable': true}.jsify(),
    );
    final unsupportedName = '$name-unsupported';
    try {
      await expectLater(
        IndexedDbCache.open(unsupportedName),
        throwsUnsupportedError,
      );
    } finally {
      if (previous == null) {
        navigator.delete('locks'.toJS);
      } else {
        object.callMethod<JSAny?>(
          'defineProperty'.toJS,
          navigator,
          'locks'.toJS,
          previous,
        );
      }
    }
    final databases = await web.window.indexedDB.databases().toDart;
    expect(
      databases.toDart.any((database) => database.name == unsupportedName),
      isFalse,
    );
    final recovered = await IndexedDbCache.open(unsupportedName);
    await recovered.close();
    await _deleteDatabase(unsupportedName);
  });

  test(
    'journal bootstrap fallback continues from its cursor after reopen',
    () async {
      await cache.resetForResync(journalOnly: true);
      await cache.applyPage(
        _page(
          [_document('first', 1)],
          cursor: 'journal-partial',
          hasMore: true,
        ),
        'partial-token',
      );
      await reopen();
      expect(cache.journalBootstrap, isTrue);
      expect(cache.bootstrapIncomplete, isTrue);
      expect(cache.cursor, 'journal-partial');
      expect(cache.consistencyToken, 'partial-token');
      expect(cache.snapshotCursor, isNull);
      await cache.applyPage(
        _page([_document('last', 2)], cursor: 'journal-final'),
        'final-token',
      );
      await reopen();
      expect(cache.bootstrapIncomplete, isFalse);
      expect(cache.journalBootstrap, isFalse);
      expect(cache.cursor, 'journal-final');
      await cache.resetForResync(journalOnly: true);
      await cache.resetForResync();
      await reopen();
      expect(cache.journalBootstrap, isFalse);
      expect(cache.cursor, isNull);
      expect(cache.bootstrapIncomplete, isTrue);
    },
  );

  test(
    'snapshot progress survives reopen and final cutover keeps newer bases',
    () async {
      await cache.applySnapshotPage(
        SnapshotPage(
          documents: [_document('first', 3)],
          cursor: 'snapshot-next',
          syncCursor: 'journal-at-five',
          cutoverSequence: 5,
          hasMore: true,
        ),
        'snapshot-token',
      );
      await reopen();
      expect(cache.get('first')!.version, 3);
      expect(cache.snapshotCursor, 'snapshot-next');
      expect(cache.snapshotCutoverSequence, 5);
      expect(cache.cursor, isNull);
      expect(cache.consistencyToken, 'snapshot-token');
      expect(cache.bootstrapIncomplete, isTrue);
      await enqueue('local', 'second', 'local-six');
      final prepared = await cache.prepare(cache.pending.single);
      await cache.acknowledge(
        prepared,
        _document('second', 6, text: 'local-six'),
        'ack-token',
      );
      await cache.applySnapshotPage(
        SnapshotPage(
          documents: [_document('second', 4, text: 'older-snapshot')],
          cursor: 'snapshot-complete',
          syncCursor: 'journal-at-five',
          cutoverSequence: 5,
          hasMore: false,
        ),
        'final-token',
      );
      await reopen();
      expect(cache.get('second')!.version, 6);
      expect(cache.get('second')!.data, {'text': 'local-six'});
      expect(cache.cursor, 'journal-at-five');
      expect(cache.snapshotCursor, isNull);
      expect(cache.snapshotCutoverSequence, isNull);
      expect(cache.bootstrapIncomplete, isFalse);
      expect(cache.consistencyToken, 'final-token');
    },
  );

  test(
    'snapshot final abort preserves partial progress and resume cutover',
    () async {
      await cache.applySnapshotPage(
        SnapshotPage(
          documents: [_document('first', 1)],
          cursor: 'partial',
          syncCursor: 'journal-at-two',
          cutoverSequence: 2,
          hasMore: true,
        ),
        'partial-token',
      );
      final finalPage = SnapshotPage(
        documents: [_document('second', 2)],
        cursor: 'finished',
        syncCursor: 'journal-at-two',
        cutoverSequence: 2,
        hasMore: false,
      );
      abortNext = true;
      await expectLater(
        cache.applySnapshotPage(finalPage, 'final-token'),
        throwsStateError,
      );
      expect(cache.get('second'), isNull);
      expect(cache.snapshotCursor, 'partial');
      expect(cache.snapshotCutoverSequence, 2);
      expect(cache.cursor, isNull);
      expect(cache.bootstrapIncomplete, isTrue);
      expect(cache.consistencyToken, 'partial-token');
      await reopen();
      expect(cache.snapshotCursor, 'partial');
      expect(cache.snapshotCutoverSequence, 2);
      expect(cache.get('second'), isNull);
      await cache.applySnapshotPage(finalPage, 'final-token');
      expect(cache.cursor, 'journal-at-two');
      expect(cache.snapshotCursor, isNull);
      expect(cache.bootstrapIncomplete, isFalse);
    },
  );

  test(
    'snapshot rejects changed cutovers and documents newer than cutover',
    () async {
      await cache.applySnapshotPage(
        SnapshotPage(
          documents: [_document('first', 1)],
          cursor: 'partial',
          syncCursor: 'journal-at-two',
          cutoverSequence: 2,
          hasMore: true,
        ),
        'partial-token',
      );
      await expectLater(
        cache.applySnapshotPage(
          SnapshotPage(
            documents: <ServerDocument>[],
            cursor: 'changed',
            syncCursor: 'other-journal',
            cutoverSequence: 3,
            hasMore: false,
          ),
          'invalid-token',
        ),
        throwsFormatException,
      );
      expect(
        () => SnapshotPage(
          documents: [_document('invalid', 3)],
          cursor: 'changed',
          syncCursor: 'journal-at-two',
          cutoverSequence: 2,
          hasMore: false,
        ),
        throwsFormatException,
      );
      await reopen();
      expect(cache.get('invalid'), isNull);
      expect(cache.snapshotCursor, 'partial');
      expect(cache.snapshotCutoverSequence, 2);
      expect(cache.consistencyToken, 'partial-token');
      await cache.resetForResync();
      await reopen();
      expect(cache.snapshotCursor, isNull);
      expect(cache.snapshotCutoverSequence, isNull);
      expect(cache.bootstrapIncomplete, isTrue);
    },
  );

  test(
    'lifetime Web Lock rejects duplicate owners and is released on close',
    () async {
      await expectLater(IndexedDbCache.open(name), throwsStateError);
      await cache.close();
      await cache.close();
      cache = await IndexedDbCache.open(name);
      expect(cache.session!.sameScope(_scope), isTrue);
      await expectLater(IndexedDbCache.open(name), throwsStateError);
    },
  );

  test('close drains queued writes before releasing the lock', () async {
    final writes = [
      enqueue('one', 'note', 'one'),
      enqueue('two', 'note', 'two'),
      enqueue('three', 'other', 'three'),
    ];
    final closing = cache.close();
    await expectLater(enqueue('late', 'note', 'late'), throwsStateError);
    await Future.wait(writes);
    await closing;
    cache = await IndexedDbCache.open(name);
    expect(cache.pending.map((item) => item.operationId), [
      'one',
      'two',
      'three',
    ]);
    expect(cache.pending.map((item) => item.sequence), [1, 2, 3]);
    expect(cache.pending[1].predecessorOperationId, 'one');
    expect(cache.get('note')!.data, {'text': 'two'});
  });

  test('takes the caller data snapshot before queued persistence', () async {
    final data = <String, Object?>{
      'nested': <String, Object?>{'value': 'before'},
    };
    final write = cache.enqueue(
      operationId: 'one',
      documentId: 'note',
      kind: MutationKind.put,
      data: data,
    );
    (data['nested'] as Map<String, Object?>)['value'] = 'after';
    await write;
    expect(cache.pending.single.data, {
      'nested': {'value': 'before'},
    });
    await reopen();
    expect(cache.get('note')!.data, {
      'nested': {'value': 'before'},
    });
  });

  test(
    'page abort rolls back documents cursor token and bootstrap together',
    () async {
      await cache.applyPage(
        _page([_document('existing', 1)], cursor: 'before', hasMore: true),
        'token-before',
      );
      abortNext = true;
      await expectLater(
        cache.applyPage(
          _page([_document('new', 2), _document('other', 3)], cursor: 'after'),
          'token-after',
        ),
        throwsStateError,
      );
      expect(cache.get('new'), isNull);
      expect(cache.get('existing')!.version, 1);
      expect(cache.cursor, 'before');
      expect(cache.consistencyToken, 'token-before');
      expect(cache.bootstrapIncomplete, isTrue);
      await reopen();
      expect(cache.get('new'), isNull);
      expect(cache.cursor, 'before');
      expect(cache.consistencyToken, 'token-before');
      expect(cache.bootstrapIncomplete, isTrue);
      await cache.applyPage(
        _page([_document('new', 2)], cursor: 'recovered'),
        'recovered-token',
      );
      expect(cache.get('new')!.version, 2);
    },
  );

  test(
    'ACK abort rolls back base removal successor dependency and token',
    () async {
      await enqueue('first', 'note', 'one');
      await enqueue('second', 'note', 'two');
      final prepared = await cache.prepare(cache.pending.first);
      abortNext = true;
      await expectLater(
        cache.acknowledge(prepared, _document('note', 1), 'ack-token'),
        throwsStateError,
      );
      expect(cache.pending, hasLength(2));
      expect(cache.pending.last.predecessorOperationId, 'first');
      expect(cache.pending.last.observedVersion, 0);
      expect(cache.get('note')!.version, 0);
      expect(cache.consistencyToken, isNull);
      await reopen();
      expect(cache.pending.last.predecessorOperationId, 'first');
      expect(cache.pending.first.baseVersion, 0);
      expect(cache.consistencyToken, isNull);
    },
  );

  test(
    'injected quota failure aborts native writes and leaves the old view durable',
    () async {
      await cache.applyPage(
        _page([_document('existing', 1)], cursor: 'before'),
        'before-token',
      );
      final quota = web.DOMException(
        'Injected storage quota fault.',
        'QuotaExceededError',
      );
      observeTransaction = (_) => throw quota;
      await expectLater(
        cache.applyPage(
          _page([_document('new', 2)], cursor: 'after'),
          'after-token',
        ),
        throwsA(same(quota)),
      );
      observeTransaction = null;
      expect(cache.get('new'), isNull);
      expect(cache.cursor, 'before');
      expect(cache.consistencyToken, 'before-token');
      await reopen();
      expect(cache.get('new'), isNull);
      expect(cache.get('existing')!.version, 1);
      expect(cache.cursor, 'before');
      expect(cache.consistencyToken, 'before-token');
      await cache.applyPage(
        _page([_document('new', 2)], cursor: 'recovered'),
        null,
      );
      expect(cache.get('new')!.version, 2);
    },
  );

  test(
    'lost ACK retains exact request while newer pull cannot rebase it',
    () async {
      await cache.applyPage(_page([_document('note', 1)]), 'initial-token');
      await enqueue('first', 'note', 'one');
      final prepared = await cache.prepare(cache.pending.single);
      final exactRequest = prepared.request.toJson();
      await enqueue('second', 'note', 'two');
      await cache.applyPage(
        _page([_document('note', 5, text: 'remote')], cursor: 'newer'),
        'pull-token',
      );
      await reopen();
      expect(
        (await cache.prepare(cache.pending.first)).request.toJson(),
        exactRequest,
      );
      expect(cache.pending.last.predecessorOperationId, 'first');
      expect(cache.get('note')!.data, {'text': 'two'});
      await cache.acknowledge(
        cache.pending.first,
        _document('note', 2, text: 'one'),
        'ack-token',
      );
      expect(cache.get('note')!.version, 5);
      expect(cache.get('note')!.data, {'text': 'two'});
      expect(cache.pending.single.observedVersion, 2);
      expect(cache.pending.single.predecessorOperationId, isNull);
      expect((await cache.prepare(cache.pending.single)).baseVersion, 2);
      await reopen();
      expect(cache.pending.single.baseVersion, 2);
      expect(cache.consistencyToken, 'ack-token');
    },
  );

  test(
    'unattempted write retains the version observed before a remote pull',
    () async {
      await cache.applyPage(_page([_document('note', 3)]), null);
      await enqueue('offline', 'note', 'edit-at-three');
      await cache.applyPage(_page([_document('note', 8)]), null);
      await reopen();
      expect(cache.pending.single.observedVersion, 3);
      expect((await cache.prepare(cache.pending.single)).baseVersion, 3);
      expect(cache.get('note')!.version, 8);
    },
  );

  test(
    'explicit conflict retry updates predecessor identity atomically',
    () async {
      await enqueue('first', 'note', 'one');
      await enqueue('second', 'note', 'two');
      final prepared = await cache.prepare(cache.pending.first);
      await cache.markConflict(prepared, _document('note', 5));
      expect(cache.nextReady(DateTime.now()), isNull);
      expect(cache.get('note')!.hasConflict, isTrue);
      await cache.retryConflict(
        'first',
        'retried',
        replacementData: {'text': 'resolved'},
      );
      await reopen();
      expect(cache.pending.first.operationId, 'retried');
      expect(cache.pending.first.sequence, 1);
      expect(cache.pending.first.observedVersion, 5);
      expect(cache.pending.first.data, {'text': 'resolved'});
      expect(cache.pending.last.predecessorOperationId, 'retried');
      final retry = await cache.prepare(cache.pending.first);
      await cache.acknowledge(retry, _document('note', 6), 'token');
      expect((await cache.prepare(cache.pending.single)).baseVersion, 6);
    },
  );

  test(
    'discard refuses unknown attempted outcome and never rebases successors',
    () async {
      await enqueue('first', 'note', 'one');
      await enqueue('second', 'note', 'two');
      final prepared = await cache.prepare(cache.pending.first);
      await expectLater(cache.discard('first'), throwsStateError);
      expect(cache.pending, hasLength(2));
      await cache.markConflict(prepared, _document('note', 5));
      await cache.discard('first');
      await reopen();
      expect(cache.pending.single.predecessorOperationId, isNull);
      expect(cache.pending.single.observedVersion, 0);
      expect((await cache.prepare(cache.pending.single)).baseVersion, 0);
    },
  );

  test('deferred and rejected heads block their own successor only', () async {
    final now = DateTime.now().toUtc();
    final later = now.add(const Duration(minutes: 1));
    await enqueue('one', 'a', 'one');
    await enqueue('two', 'a', 'two');
    await enqueue('three', 'b', 'three');
    final first = await cache.prepare(cache.pending.first);
    await cache.defer(first, later, 'busy');
    expect(cache.nextReady(now)!.operationId, 'three');
    expect(cache.nextRetryAt, later);
    await reopen();
    expect(cache.pending.first.attempts, 1);
    expect(cache.pending.first.errorCode, 'busy');
    expect(cache.nextReady(later)!.operationId, 'one');
    await cache.markRejected(cache.pending.first, 'invalid');
    expect(cache.nextReady(later)!.operationId, 'three');
    expect(cache.nextRetryAt, isNull);
    await reopen();
    expect(cache.pending.first.state, MutationState.rejected);
    expect(cache.pending.first.errorCode, 'invalid');
    expect(cache.pending.first.nextAttemptAt, isNull);
  });

  test('revocation purge and explicit resume survive reopening', () async {
    await cache.applyPage(_page([_document('confirmed', 1)]), 'saved-token');
    await enqueue('pending', 'note', 'private');
    await cache.purgeAndPause('authorization_failed');
    await reopen();
    expect(cache.list(includeDeleted: true), isEmpty);
    expect(cache.pending, isEmpty);
    expect(cache.cursor, isNull);
    expect(cache.consistencyToken, isNull);
    expect(cache.paused, isTrue);
    expect(cache.pauseReason, 'authorization_failed');
    expect(cache.session!.sameScope(_scope), isTrue);
    const newScope = SessionInfo(
      scopeId: 'new-scope',
      principalId: 'new-principal',
      permissionVersion: '2',
      scopeMode: SyncScopeMode.tenant,
    );
    await cache.resumeFor(newScope);
    await reopen();
    expect(cache.session!.sameScope(newScope), isTrue);
    expect(cache.paused, isFalse);
    expect(cache.pauseReason, isNull);
    expect(cache.bootstrapIncomplete, isTrue);
  });

  test(
    'resync removes server base and cursors but preserves exact outbox',
    () async {
      await cache.applyPage(_page([_document('note', 3)]), 'saved-token');
      await enqueue('one', 'note', 'one');
      final prepared = await cache.prepare(cache.pending.single);
      await enqueue('two', 'note', 'two');
      await cache.resetForResync();
      await reopen();
      expect(cache.cursor, isNull);
      expect(cache.consistencyToken, isNull);
      expect(cache.bootstrapIncomplete, isTrue);
      expect(cache.get('note')!.version, 0);
      expect(cache.get('note')!.data, {'text': 'two'});
      expect(cache.pending.first.request.toJson(), prepared.request.toJson());
      expect(cache.pending.last.predecessorOperationId, 'one');
    },
  );

  test(
    'confirmed tombstones and versions cannot be reversed by stale pages',
    () async {
      await cache.applyPage(
        _page([_document('b', 1), _document('a', 2, deleted: true)]),
        'first-token',
      );
      await cache.applyPage(_page([_document('a', 1)], cursor: 'later'), null);
      await reopen();
      expect(cache.list().map((item) => item.id), ['b']);
      expect(cache.list(includeDeleted: true).map((item) => item.id), [
        'a',
        'b',
      ]);
      expect(cache.get('a')!.version, 2);
      expect(cache.get('a')!.deleted, isTrue);
      expect(cache.get('a')!.data, isNull);
      expect(cache.bootstrapIncomplete, isFalse);
    },
  );

  test(
    'validation failures and duplicate operations leave committed state unchanged',
    () async {
      await enqueue('one', 'note', 'one');
      await expectLater(enqueue('one', 'other', 'duplicate'), throwsStateError);
      await expectLater(
        cache.prepare(
          PendingMutation(
            sequence: 100,
            operationId: 'unknown',
            documentId: 'note',
            kind: MutationKind.put,
            data: {'text': 'unknown'},
            state: MutationState.queued,
            attempts: 0,
            baseVersion: null,
            observedVersion: 0,
            predecessorOperationId: null,
            nextAttemptAt: null,
          ),
        ),
        throwsStateError,
      );
      expect(
        () => cache.applyPage(
          _page([_document('other', 3)], cursor: ''),
          'invalid-token',
        ),
        throwsFormatException,
      );
      final prepared = await cache.prepare(cache.pending.single);
      await expectLater(
        cache.acknowledge(prepared, _document('wrong', 1), 'invalid-token'),
        throwsFormatException,
      );
      await reopen();
      expect(cache.pending.single.operationId, 'one');
      expect(cache.get('other'), isNull);
      expect(cache.get('wrong'), isNull);
      expect(cache.consistencyToken, isNull);
    },
  );
}
