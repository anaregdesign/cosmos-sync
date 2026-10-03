import 'dart:async';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:test/test.dart';

import 'support/cache_location.dart';
import 'support/testing_transport.dart';

void main() {
  late TestCacheLocation location;
  late TestServer server;
  final clients = <CosmosSyncClient>[];
  Future<CosmosSyncClient> open(TestTransport transport) async {
    final client = await CosmosSyncClient.open(
      cache: await location.open(),
      transport: transport,
      session: scope,
    );
    clients.add(client);
    return client;
  }

  Future<void> eventually(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  setUp(() async {
    location = await createTestCacheLocation();
    server = TestServer();
  });
  tearDown(() async {
    for (final client in clients) {
      await client.close();
    }
    clients.clear();
    await location.cleanup();
  });

  test(
    'snapshot partial cursor resumes after reopen and final cutover precedes deltas',
    () async {
      server.externalPut('a', {'text': 'a-v1'});
      server.externalPut('b', {'text': 'b-v2'});
      final transport = SnapshotTestTransport(server)
        ..pages.add(
          SnapshotPage(
            documents: [server.documents['a']!],
            cursor: 'snapshot-1',
            syncCursor: '2',
            cutoverSequence: 2,
            hasMore: true,
          ),
        );
      var client = await open(transport);
      await client.sync(maxPages: 1);
      expect(client.cache.snapshotCursor, 'snapshot-1');
      expect(client.cache.snapshotCutoverSequence, 2);
      expect(client.cache.cursor, isNull);
      final id = await client.put('a', {'text': 'local-from-v1'});
      server.externalPut('a', {'text': 'after-cutover-v3'});
      await client.close();
      final resumed = SnapshotTestTransport(server)
        ..pages.add(
          SnapshotPage(
            documents: [server.documents['b']!],
            cursor: 'snapshot-final',
            syncCursor: '2',
            cutoverSequence: 2,
            hasMore: false,
          ),
        );
      client = await open(resumed);
      await client.sync(maxPages: 1);
      expect(resumed.snapshotCursors, ['snapshot-1']);
      expect(client.cache.cursor, '2');
      expect(client.cache.snapshotCursor, isNull);
      expect(client.cache.bootstrapIncomplete, isFalse);
      await client.sync();
      expect(resumed.cursors.single, '2');
      expect(client.get('a')!.version, 3);
      expect(client.get('a')!.data!['text'], 'local-from-v1');
      expect(client.pending.single.operationId, id);
      await client.flush();
      expect(resumed.requests.single.baseVersion, 1);
      expect(client.pending.single.state, MutationState.conflict);
    },
  );

  test(
    'snapshot413 fallback survives partial journal replay and reopen',
    () async {
      for (final id in ['a', 'b', 'c']) {
        server.externalPut(id, {'id': id});
      }
      final transport = SnapshotTestTransport(server)..snapshotLimit = true;
      var client = await open(transport);
      await client.sync(pageSize: 1, maxPages: 1);
      expect(transport.snapshotCursors, [null]);
      expect(client.cache.cursor, '1');
      expect(client.cache.journalBootstrap, isTrue);
      await client.close();
      final resumed = SnapshotTestTransport(server)..snapshotLimit = true;
      client = await open(resumed);
      await client.sync(pageSize: 1, maxPages: 1);
      expect(resumed.snapshotCursors, isEmpty);
      expect(client.cache.cursor, '2');
      await client.sync(pageSize: 1, maxPages: 1);
      expect(client.cache.cursor, '3');
      expect(client.cache.journalBootstrap, isFalse);
      expect(client.list(), hasLength(3));
    },
  );

  test(
    'changed snapshot cutover rejects page without changing committed cache',
    () async {
      final client = await open(TestTransport(server));
      await client.cache.applySnapshotPage(
        SnapshotPage(
          documents: [
            ServerDocument(id: 'a', data: {}, version: 1, deleted: false),
          ],
          cursor: 'partial',
          syncCursor: '2',
          cutoverSequence: 2,
          hasMore: true,
        ),
        'token-2',
      );
      await expectLater(
        Future<void>.sync(
          () => client.cache.applySnapshotPage(
            SnapshotPage(
              documents: [
                ServerDocument(id: 'b', data: {}, version: 3, deleted: false),
              ],
              cursor: 'wrong',
              syncCursor: '3',
              cutoverSequence: 3,
              hasMore: false,
            ),
            'token-3',
          ),
        ),
        throwsFormatException,
      );
      expect(client.get('b'), isNull);
      expect(client.cache.snapshotCursor, 'partial');
      expect(client.cache.consistencyToken, 'token-2');
    },
  );

  test('snapshot never rolls back a newer confirmed ACK version', () async {
    final client = await open(TestTransport(server));
    await client.cache.applyPage(
      SyncPage(
        changes: [
          ServerDocument(id: 'a', data: {'v': 9}, version: 9, deleted: false),
        ],
        cursor: '9',
        hasMore: false,
      ),
      'token-9',
    );
    await client.cache.applySnapshotPage(
      SnapshotPage(
        documents: [
          ServerDocument(id: 'a', data: {'v': 2}, version: 2, deleted: false),
        ],
        cursor: 'final',
        syncCursor: '2',
        cutoverSequence: 2,
        hasMore: false,
      ),
      'token-2',
    );
    expect(client.get('a')!.version, 9);
    expect(client.get('a')!.data!['v'], 9);
  });

  test(
    'waitForPendingWrites captures only original set and waits for true ACK',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final transport = TestTransport(server)
        ..beforeMutation = (_) async {
          entered.complete();
          await release.future;
        };
      final client = await open(transport);
      await client.put('first', {'text': 'captured'});
      var completed = false;
      final waiter = client.waitForPendingWrites().then(
        (_) => completed = true,
      );
      final flushing = client.flush(maxOperations: 1);
      await entered.future;
      await client.put('later', {'text': 'not captured'});
      expect(completed, isFalse);
      release.complete();
      await flushing;
      await waiter;
      expect(completed, isTrue);
      expect(client.pending.single.documentId, 'later');
    },
  );

  test('waiters fail on conflict, discard, signout and close', () async {
    var client = await open(TestTransport(server));
    var id = await client.put('note', {'text': 'discard'});
    var expectation = expectLater(
      client.waitForPendingWrites(),
      throwsA(
        isA<PendingWritesException>().having(
          (error) => error.reason,
          'reason',
          'discarded',
        ),
      ),
    );
    await client.discard(id);
    await expectation;
    server.externalPut('note', {'text': 'remote'});
    id = await client.put('note', {'text': 'from absence'});
    expectation = expectLater(
      client.waitForPendingWrites(),
      throwsA(
        isA<PendingWritesException>().having(
          (error) => error.reason,
          'reason',
          'conflict',
        ),
      ),
    );
    await client.flush();
    await expectation;
    await client.discard(id);
    await client.put('note', {'text': 'signout'});
    expectation = expectLater(
      client.waitForPendingWrites(),
      throwsA(
        isA<PendingWritesException>().having(
          (error) => error.reason,
          'reason',
          'signed_out',
        ),
      ),
    );
    await client.signOut();
    await expectation;
    await client.close();
    client = await open(TestTransport(server));
    await client.resume();
    await client.put('close', {});
    expectation = expectLater(
      client.waitForPendingWrites(),
      throwsA(
        isA<PendingWritesException>().having(
          (error) => error.reason,
          'reason',
          'closed',
        ),
      ),
    );
    await client.close();
    await expectation;
  });

  test(
    'SSE hint resumes with a separate ID and always syncs durable cursor',
    () async {
      server.externalPut('note', {'text': 'initial'});
      final transport = HintTestTransport(server);
      final client = await open(transport);
      await client.sync();
      client.startWatching(pollingInterval: const Duration(seconds: 30));
      await eventually(() => transport.connections.isNotEmpty);
      expect(transport.connections.first, (null, '1'));
      server.externalPut('note', {'text': 'changed'});
      transport.streams.first.add(
        const ChangeHint(
          resumeId: 'events-token',
          consistencyToken: 'stale-hint-token',
        ),
      );
      await eventually(() => client.get('note')?.version == 2);
      expect(transport.cursors.last, '1');
      expect(client.cache.cursor, '2');
      expect(client.cache.consistencyToken, isNot('stale-hint-token'));
      await transport.streams.first.close();
      await eventually(() => transport.connections.length == 2);
      expect(transport.connections.last, ('events-token', '2'));
      client.stopWatching();
    },
  );

  test(
    'SSE auth revocation purges cache and fails captured pending writes',
    () async {
      final transport = HintTestTransport(server);
      final client = await open(transport);
      await client.put('private', {'text': 'alice'});
      final expectation = expectLater(
        client.waitForPendingWrites(),
        throwsA(
          isA<PendingWritesException>().having(
            (error) => error.reason,
            'reason',
            'authorization_changed',
          ),
        ),
      );
      client.startWatching(pollingInterval: const Duration(seconds: 30));
      await eventually(() => transport.connections.isNotEmpty);
      transport.streams.first.addError(
        const TransportException(
          statusCode: 403,
          code: 'forbidden',
          message: 'revoked',
        ),
      );
      await eventually(() => client.status.paused);
      await expectation;
      expect(client.list(), isEmpty);
      expect(client.pending, isEmpty);
    },
  );

  test(
    'learned SSE revocation hides data and blocks writes before a late ACK',
    () async {
      server.externalPut('confirmed', {'text': 'private'});
      final transport = HintTestTransport(server);
      final client = await open(transport);
      await client.sync();
      await client.put('first', {'text': 'in flight'});
      await client.put('second', {'text': 'must not be sent'});
      final entered = Completer<void>();
      final release = Completer<void>();
      transport.beforeMutation = (_) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      client.startWatching(pollingInterval: const Duration(seconds: 30));
      await eventually(() => transport.connections.isNotEmpty);
      final waiter = expectLater(
        client.waitForPendingWrites(),
        throwsA(
          isA<PendingWritesException>().having(
            (error) => error.reason,
            'reason',
            'authorization_changed',
          ),
        ),
      );
      final flush = client.flush();
      await entered.future;
      transport.streams.first.addError(
        const TransportException(
          statusCode: 403,
          code: 'forbidden',
          message: 'revoked',
        ),
      );
      await eventually(() => client.status.paused);
      await waiter;
      expect(release.isCompleted, isFalse);
      expect(client.status.reason, 'forbidden');
      expect(client.get('confirmed'), isNull);
      expect(client.get('first'), isNull);
      expect(client.list(), isEmpty);
      expect(client.pending, isEmpty);
      final query = client.query(LocalQuery());
      expect(query.documents, isEmpty);
      expect(query.metadata.completeAtCursor, isNull);
      expect(() => client.put('late', {'text': 'discarded'}), throwsStateError);
      expect(() => client.delete('confirmed'), throwsStateError);
      expect(() => client.flush(), throwsStateError);
      expect(() => client.sync(), throwsStateError);
      release.complete();
      await flush;
      await eventually(() => client.cache.paused);
      expect(transport.requests, hasLength(1));
      expect(client.cache.list(includeDeleted: true), isEmpty);
      expect(client.cache.pending, isEmpty);
      expect(client.cache.consistencyToken, isNull);
      expect(client.cache.cursor, isNull);
    },
  );

  test('polling fallback catches changes when no SSE hint arrives', () async {
    final transport = HintTestTransport(server);
    final client = await open(transport);
    await client.sync();
    client.startWatching(pollingInterval: const Duration(seconds: 1));
    await eventually(() => transport.connections.isNotEmpty);
    server.externalPut('note', {'text': 'caught by poll'});
    await eventually(() => client.get('note')?.version == 1);
    expect(client.cache.cursor, '1');
    client.stopWatching();
  });
}

class SnapshotTestTransport extends TestTransport implements SnapshotTransport {
  SnapshotTestTransport(super.server);
  final pages = <SnapshotPage>[];
  final snapshotCursors = <String?>[];
  bool snapshotLimit = false;
  @override
  Future<SnapshotPage> snapshot({String? cursor, int limit = 100}) async {
    snapshotCursors.add(cursor);
    if (snapshotLimit) {
      throw const TransportException(
        statusCode: 413,
        code: 'snapshot_limit_exceeded',
        message: 'bounded view',
      );
    }
    return pages.removeAt(0);
  }
}

class HintTestTransport extends TestTransport implements ChangeHintTransport {
  HintTestTransport(super.server);
  final connections = <(String?, String?)>[];
  final streams = <StreamController<ChangeHint>>[];
  @override
  Stream<ChangeHint> watchChanges({String? lastEventId, String? cursor}) {
    connections.add((lastEventId, cursor));
    final controller = StreamController<ChangeHint>();
    streams.add(controller);
    return controller.stream;
  }

  @override
  void close() {
    for (final stream in streams) {
      unawaited(stream.close());
    }
  }
}
