@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../support/testing_transport.dart' show TestServer, TestTransport;

const scope = SessionInfo(
  principalId: 'principal',
  scopeId: 'alice-tenant',
  permissionVersion: '1',
);

void main() {
  late Directory directory;
  late String path;
  late TestServer server;
  final clients = <CosmosSyncClient>[];
  var now = DateTime.utc(2026, 10, 3);

  Future<CosmosSyncClient> open({
    TestTransport? transport,
    SessionInfo session = scope,
  }) async {
    final client = await CosmosSyncClient.open(
      path: path,
      transport: transport ?? TestTransport(server),
      session: session,
      clock: () => now,
    );
    clients.add(client);
    return client;
  }

  setUp(() {
    directory = Directory.systemTemp.createTempSync('cosmos-sync-test-');
    path = '${directory.path}/cache.sqlite';
    server = TestServer();
    now = DateTime.utc(2026, 10, 3);
  });
  tearDown(() async {
    for (final client in clients) {
      await client.close();
    }
    clients.clear();
    directory.deleteSync(recursive: true);
  });

  test(
    'offline reads, writes, immutable data and outbox survive restart',
    () async {
      var client = await open();
      final data = <String, Object?>{
        'title': 'offline',
        'nested': <Object?>['kept'],
      };
      final operationId = await client.put('note', data);
      data['title'] = 'caller changed it';
      (data['nested'] as List)[0] = 'changed';
      expect(client.get('note')!.data, {
        'title': 'offline',
        'nested': ['kept'],
      });
      expect(client.get('note')!.version, 0);
      expect(client.get('note')!.hasPendingWrites, isTrue);
      expect(client.pending.single.baseVersion, isNull);
      await client.close();
      client = await open();
      expect(client.pending.single.operationId, operationId);
      expect(client.get('note')!.data!['title'], 'offline');
      final result = await client.flush();
      expect(result.acknowledged, 1);
      expect(client.get('note')!.hasPendingWrites, isFalse);
      expect(server.documents['note']!.data!['title'], 'offline');
    },
  );

  test('watch emits initial, pending and confirmed states', () async {
    final client = await open();
    final values = <DocumentSnapshot?>[];
    final subscription = client.watch('note').listen(values.add);
    await Future<void>.delayed(Duration.zero);
    await client.put('note', {'title': 'hello'});
    await client.flush();
    await Future<void>.delayed(Duration.zero);
    expect(values.first, isNull);
    expect(values.any((value) => value?.hasPendingWrites == true), isTrue);
    expect(values.last!.hasPendingWrites, isFalse);
    await subscription.cancel();
  });

  test('old ACK leaves a later local edit visible and pending', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final transport = TestTransport(server)
      ..beforeMutation = (request) async {
        entered.complete();
        await release.future;
      };
    final client = await open(transport: transport);
    await client.put('note', {'text': 'first'});
    final flushing = client.flush(maxOperations: 1);
    await entered.future;
    await client.put('note', {'text': 'second'});
    release.complete();
    await flushing;
    expect(client.get('note')!.data!['text'], 'second');
    expect(client.get('note')!.version, 1);
    expect(client.get('note')!.hasPendingWrites, isTrue);
    expect(client.pending.single.baseVersion, isNull);
    transport.beforeMutation = null;
    await client.flush();
    expect(transport.requests.map((request) => request.baseVersion), [0, 1]);
    expect(server.documents['note']!.data!['text'], 'second');
  });

  test(
    'signOut waits for pending ACK, gates new work and purges after it',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final transport = TestTransport(server)
        ..beforeMutation = (_) async {
          entered.complete();
          await release.future;
        };
      final client = await open(transport: transport);
      await client.put('note', {'text': 'in flight'});
      await client.put('later', {'text': 'must not send after logout'});
      final flushing = client.flush();
      await entered.future;
      final signingOut = client.signOut();
      expect(() => client.put('new', {}), throwsStateError);
      expect(() => client.sync(), throwsStateError);
      release.complete();
      await flushing;
      await signingOut;
      expect(transport.requests, hasLength(1));
      expect(client.list(), isEmpty);
      expect(client.pending, isEmpty);
      expect(client.status.paused, isTrue);
      expect(client.status.reason, 'signed_out');
      expect(transport.consistencyToken, isNull);
      await client.close();
      final reopened = await open();
      expect(reopened.list(), isEmpty);
      expect(reopened.status.paused, isTrue);
    },
  );

  test(
    'retry after lost ACK replays exact persisted ID and baseVersion',
    () async {
      final transport = TestTransport(server)..loseNextAcknowledgement = true;
      var client = await open(transport: transport);
      final operationId = await client.put('note', {'text': 'once'});
      final first = await client.flush();
      expect(first.remaining, 1);
      expect(client.pending.single.baseVersion, 0);
      expect(server.sequence, 1);
      expect(() => client.discard(operationId), throwsStateError);
      await client.close();
      now = now.add(const Duration(minutes: 1));
      final replayTransport = TestTransport(server);
      client = await open(transport: replayTransport);
      await client
          .sync(); // Seeing the committed version cannot rewrite the request.
      await client.flush();
      expect(replayTransport.requests.single.operationId, operationId);
      expect(replayTransport.requests.single.baseVersion, 0);
      expect(server.sequence, 1);
      expect(client.pending, isEmpty);
    },
  );

  test(
    '409 exposes conflict and blocks following writes until explicit retry',
    () async {
      server.externalPut('note', {'text': 'base'});
      final transport = TestTransport(server);
      final client = await open(transport: transport);
      await client.sync();
      final conflictedId = await client.put('note', {'text': 'mine'});
      await client.put('note', {'text': 'later'});
      server.externalPut('note', {'text': 'remote'});
      final result = await client.flush();
      expect(result.acknowledged, 0);
      expect(transport.requests, hasLength(1));
      expect(client.pending.first.state, MutationState.conflict);
      expect(client.get('note')!.hasConflict, isTrue);
      expect(client.get('note')!.data!['text'], 'later');
      final freshId = await client.retryConflict(
        conflictedId,
        data: {'text': 'merged'},
      );
      expect(freshId, isNot(conflictedId));
      await client.flush();
      expect(transport.requests.skip(1).map((request) => request.baseVersion), [
        2,
        3,
      ]);
      expect(server.documents['note']!.data!['text'], 'later');
      expect(client.pending, isEmpty);
    },
  );

  test(
    'discard conflict exposes server base and unlocks following edit',
    () async {
      server.externalPut('note', {'text': 'base'});
      final client = await open();
      await client.sync();
      final operationId = await client.put('note', {'text': 'mine'});
      server.externalPut('note', {'text': 'remote'});
      await client.flush();
      await client.discard(operationId);
      expect(client.get('note')!.data!['text'], 'remote');
      expect(client.get('note')!.hasPendingWrites, isFalse);
      await client.put('note', {'text': 'after'});
      await client.flush();
      expect(server.documents['note']!.data!['text'], 'after');
    },
  );

  test(
    'deletion conflict retry is durable and never stores JSON null as data',
    () async {
      server.externalPut('note', {'text': 'base'});
      var client = await open();
      await client.sync();
      final id = await client.delete('note');
      server.externalPut('note', {'text': 'new'});
      await client.flush();
      await client.retryConflict(id);
      await client.close();
      client = await open();
      expect(client.pending.single.data, isNull);
      await client.flush();
      expect(server.documents['note']!.deleted, isTrue);
    },
  );

  test(
    'scope or permission version mismatch purges before any mutation',
    () async {
      final transport = TestTransport(server);
      var client = await open(transport: transport);
      await client.put('private', {'secret': 'alice'});
      server.session = const SessionInfo(
        principalId: 'principal',
        scopeId: 'alice-tenant',
        permissionVersion: '2',
      );
      await expectLater(client.flush(), throwsStateError);
      expect(transport.requests, isEmpty);
      expect(client.status.paused, isTrue);
      expect(client.list(), isEmpty);
      expect(client.pending, isEmpty);
      await client.close();
      client = await open();
      expect(client.status.paused, isTrue);
      expect(
        () => client.put('private', {'text': 'blocked'}),
        throwsStateError,
      );
      await client.resume();
      expect(client.session.permissionVersion, '2');
      expect(client.status.paused, isFalse);
    },
  );

  test(
    'explicit shared selection purges a different offline cache before display',
    () async {
      final sharedA = SessionInfo(
        principalId: 'a' * 64,
        scopeId: 'b' * 64,
        permissionVersion: '2',
        scopeMode: SyncScopeMode.shared,
      );
      final original = await open(session: sharedA);
      await original.put('private', {'text': 'only shared A'});
      await original.close();
      var requests = 0;
      final transport = HttpSyncTransport(
        baseUri: Uri.parse('https://bff.example.test'),
        tokenProvider: () async => 'api-token',
        scopeMode: SyncScopeMode.shared,
        sharedScopeId: 'c' * 64,
        client: MockClient((_) async {
          requests++;
          throw http.ClientException('offline');
        }),
      );
      final selected = await CosmosSyncClient.open(
        path: path,
        transport: transport,
      );
      clients.add(selected);
      expect(requests, 0);
      expect(selected.status.paused, isTrue);
      expect(selected.status.reason, 'scope_changed');
      expect(selected.get('private'), isNull);
      expect(selected.pending, isEmpty);
      expect(selected.cache.cursor, isNull);
    },
  );

  test(
    'explicit shared mode purges a supplied legacy personal session offline',
    () async {
      var requests = 0;
      final transport = HttpSyncTransport(
        baseUri: Uri.parse('https://bff.example.test'),
        tokenProvider: () async => 'api-token',
        scopeMode: SyncScopeMode.shared,
        sharedScopeId: 'b' * 64,
        client: MockClient((_) async {
          requests++;
          throw http.ClientException('offline');
        }),
      );
      final selected = await CosmosSyncClient.open(
        path: path,
        transport: transport,
        session: scope,
      );
      clients.add(selected);
      expect(requests, 0);
      expect(selected.status.paused, isTrue);
      expect(
        () => selected.put('private', {'text': 'wrong mode'}),
        throwsStateError,
      );
    },
  );

  test(
    'matching offline shared selection retains data, generation changes purge before replay',
    () async {
      final shared = SessionInfo(
        principalId: 'a' * 64,
        scopeId: 'b' * 64,
        permissionVersion: '2',
        scopeMode: SyncScopeMode.shared,
      );
      final original = await open(session: shared);
      await original.put('note', {'text': 'available offline'});
      final operation = original.pending.single.operationId;
      await original.close();
      var requests = 0;
      final transport = HttpSyncTransport(
        baseUri: Uri.parse('https://bff.example.test'),
        tokenProvider: () async => 'api-token',
        scopeMode: SyncScopeMode.shared,
        sharedScopeId: shared.scopeId,
        client: MockClient((request) async {
          requests++;
          expect(request.url.path, '/v1/session');
          return http.Response(
            jsonEncode({...shared.toJson(), 'permissionVersion': '4'}),
            200,
          );
        }),
      );
      final reopened = await CosmosSyncClient.open(
        path: path,
        transport: transport,
      );
      clients.add(reopened);
      expect(requests, 0);
      expect(reopened.get('note')!.data!['text'], 'available offline');
      expect(reopened.pending.single.operationId, operation);
      await expectLater(reopened.flush(), throwsStateError);
      expect(requests, 1);
      expect(reopened.status.paused, isTrue);
      expect(reopened.get('note'), isNull);
      expect(reopened.pending, isEmpty);
    },
  );

  test(
    '401 and 403 at preflight or mutation conservatively purge and pause',
    () async {
      for (final code in [401, 403]) {
        final localPath = '$path-$code';
        final transport = TestTransport(server);
        final client = await CosmosSyncClient.open(
          path: localPath,
          transport: transport,
          session: scope,
        );
        clients.add(client);
        await client.put('private', {'secret': 'data'});
        if (code == 401) {
          transport.sessionFailure = TransportException(
            statusCode: code,
            code: 'unauthorized',
            message: 'denied',
          );
        } else {
          transport.mutationFailure = TransportException(
            statusCode: code,
            code: 'forbidden',
            message: 'denied',
          );
        }
        await expectLater(client.flush(), throwsA(isA<TransportException>()));
        expect(client.status.paused, isTrue);
        expect(client.list(), isEmpty);
        expect(client.pending, isEmpty);
      }
    },
  );

  test('429 deadline survives restart and preserves exact request', () async {
    final transport = TestTransport(server)
      ..mutationFailure = const TransportException(
        statusCode: 429,
        code: 'throttled',
        message: 'wait',
        retryAfter: Duration(seconds: 20),
      );
    var client = await open(transport: transport);
    final id = await client.put('note', {'text': 'retry'});
    final first = await client.flush();
    expect(first.retryAt, now.add(const Duration(seconds: 20)));
    expect(client.pending.single.attempts, 1);
    await client.close();
    final replay = TestTransport(server);
    client = await open(transport: replay);
    await client.flush();
    expect(replay.requests, isEmpty);
    now = now.add(const Duration(seconds: 21));
    await client.flush();
    expect(replay.requests.single.operationId, id);
    expect(replay.requests.single.baseVersion, 0);
  });

  test(
    '5xx retains outbox; invalid nonretryable request is exposed rejected',
    () async {
      final transport = TestTransport(server)
        ..mutationFailure = const TransportException(
          statusCode: 503,
          code: 'unavailable',
          message: 'retry',
        );
      final client = await open(transport: transport);
      final id = await client.put('note', {'text': 'keep'});
      await client.flush();
      expect(client.pending.single.state, MutationState.queued);
      now = now.add(const Duration(minutes: 1));
      transport.mutationFailure = const TransportException(
        statusCode: 400,
        code: 'invalid_request',
        message: 'rejected',
      );
      await client.flush();
      expect(client.pending.single.state, MutationState.rejected);
      expect(client.pending.single.errorCode, 'invalid_request');
      await client.discard(id);
      expect(client.get('note'), isNull);
    },
  );

  test(
    '507 capacity preserves retry deadline and exact request across restart',
    () async {
      final transport = TestTransport(server)
        ..mutationFailure = const TransportException(
          statusCode: 507,
          code: 'scope_capacity_exceeded',
          message: 'Operator must restore capacity.',
          retryAfter: Duration(seconds: 20),
        );
      var client = await open(transport: transport);
      final id = await client.put('note', {'text': 'durable capacity wait'});
      final deferred = await client.flush();
      final exact = transport.requests.single.toJson();
      expect(deferred.acknowledged, 0);
      expect(deferred.retryAt, now.add(const Duration(seconds: 20)));
      expect(client.pending.single.operationId, id);
      expect(client.pending.single.state, MutationState.queued);
      expect(client.pending.single.errorCode, 'scope_capacity_exceeded');
      expect(client.get('note')!.hasPendingWrites, isTrue);
      expect(server.sequence, 0);
      expect(() => client.discard(id), throwsStateError);
      await client.close();

      final recovered = TestTransport(server);
      client = await open(transport: recovered);
      expect(client.pending.single.operationId, id);
      expect(client.pending.single.attempts, 1);
      expect(client.pending.single.errorCode, 'scope_capacity_exceeded');
      await client.flush();
      expect(recovered.requests, isEmpty);
      now = now.add(const Duration(seconds: 21));
      expect((await client.flush()).acknowledged, 1);
      expect(recovered.requests.single.toJson(), exact);
      expect(server.sequence, 1);
      expect(client.pending, isEmpty);
      expect(client.get('note')!.hasPendingWrites, isFalse);
    },
  );

  test(
    'initial replay, incremental cursor and retained tombstone survive restart',
    () async {
      server.externalPut('note', {'text': 'remote'});
      final transport = TestTransport(server);
      var client = await open(transport: transport);
      await client.sync(pageSize: 1);
      expect(transport.cursors.first, isNull);
      expect(client.cache.cursor, '1');
      await client.close();
      final resumed = TestTransport(server);
      client = await open(transport: resumed);
      server.externalDelete('note');
      await client.sync();
      expect(resumed.cursors.single, '1');
      expect(client.get('note')!.deleted, isTrue);
      expect(client.list(), isEmpty);
      expect(client.list(includeDeleted: true), hasLength(1));
      await client.put('note', {'text': 'recreated'});
      await client.flush();
      expect(resumed.requests.single.baseVersion, 2);
      expect(client.get('note')!.deleted, isFalse);
    },
  );

  test(
    'older replay ACK and sync pages cannot replace a newer confirmed version',
    () async {
      final client = await open();
      await client.cache.applyPage(
        SyncPage(
          changes: [
            ServerDocument(
              id: 'note',
              data: {'v': 9},
              version: 9,
              deleted: false,
            ),
          ],
          cursor: 'new',
          hasMore: false,
        ),
        'token-new',
      );
      await client.cache.applyPage(
        SyncPage(
          changes: [
            ServerDocument(
              id: 'note',
              data: {'v': 2},
              version: 2,
              deleted: false,
            ),
          ],
          cursor: 'older',
          hasMore: false,
        ),
        'token-older',
      );
      expect(client.get('note')!.version, 9);
      expect(client.get('note')!.data!['v'], 9);
    },
  );

  test(
    '410 sync resets confirmed base and cursor, preserves pending payload',
    () async {
      server.externalPut('note', {'text': 'base'});
      final transport = TestTransport(server);
      final client = await open(transport: transport);
      await client.sync();
      await client.put('note', {'text': 'local'});
      final before = client.pending.single;
      transport.syncFailure = const TransportException(
        statusCode: 410,
        code: 'resync_required',
        message: 'expired',
      );
      await client.sync();
      expect(transport.cursors, [null, '1', null]);
      expect(transport.cursors.last, isNull);
      expect(client.pending.single.operationId, before.operationId);
      expect(client.pending.single.baseVersion, before.baseVersion);
      expect(client.get('note')!.data!['text'], 'local');
      expect(client.get('note')!.version, 1);
    },
  );

  test(
    '410 on mutation resyncs and replays its already prepared identity',
    () async {
      final transport = TestTransport(server)
        ..mutationFailure = const TransportException(
          statusCode: 410,
          code: 'resync_required',
          message: 'rotated',
        );
      final client = await open(transport: transport);
      final id = await client.put('note', {'text': 'exact'});
      await client.flush();
      expect(transport.requests, hasLength(2));
      expect(transport.requests.map((request) => request.operationId), [
        id,
        id,
      ]);
      expect(transport.requests.map((request) => request.baseVersion), [0, 0]);
      expect(client.pending, isEmpty);
    },
  );

  test(
    'partial initial replay prevents writes until bootstrap is complete',
    () async {
      server.externalPut('a', {'text': 'a'});
      server.externalPut('b', {'text': 'b'});
      final transport = TestTransport(server);
      final client = await open(transport: transport);
      await client.sync(pageSize: 1, maxPages: 1);
      expect(client.cache.bootstrapIncomplete, isTrue);
      await client.put('c', {'text': 'c'});
      await client
          .flush(); // Flush completes the remaining bootstrap before sending.
      expect(transport.cursors, [null, '1']);
      expect(client.cache.bootstrapIncomplete, isFalse);
      expect(server.documents['c']!.data!['text'], 'c');
    },
  );

  test(
    'pulling remote changes never silently rebases an offline local edit',
    () async {
      server.externalPut('note', {'text': 'base'});
      final transport = TestTransport(server);
      final client = await open(transport: transport);
      await client.sync();
      await client.put('note', {'text': 'from-v1'});
      expect(client.pending.single.observedVersion, 1);
      server.externalPut('note', {'text': 'remote-v2'});
      await client.sync();
      await client.flush();
      expect(transport.requests.single.baseVersion, 1);
      expect(client.pending.single.state, MutationState.conflict);
      expect(server.documents['note']!.data!['text'], 'remote-v2');
    },
  );

  test(
    'successor depends on predecessor ACK even when cache has a newer version',
    () async {
      server.externalPut('note', {'text': 'base'});
      final transport = TestTransport(server)..loseNextAcknowledgement = true;
      final client = await open(transport: transport);
      await client.sync();
      final firstId = await client.put('note', {'text': 'first'});
      await client.put('note', {'text': 'second'});
      expect(client.pending.last.predecessorOperationId, firstId);
      await client
          .flush(); // First committed as version 2, but its ACK was lost.
      server.externalPut('note', {'text': 'remote-v3'});
      now = now.add(const Duration(minutes: 1));
      await client.sync();
      await client
          .flush(); // Replay ACK v2 binds successor to v2, not cached v3.
      expect(transport.requests.map((request) => request.baseVersion), [
        1,
        1,
        2,
      ]);
      expect(client.pending.single.state, MutationState.conflict);
      expect(client.get('note')!.version, 3);
      expect(server.documents['note']!.data!['text'], 'remote-v3');
    },
  );

  test(
    'unseen offline edit conflicts with a document discovered by bootstrap',
    () async {
      server.externalPut('note', {'text': 'remote'});
      final transport = TestTransport(server);
      final client = await open(transport: transport);
      await client.put('note', {'text': 'unseen-local'});
      await client.flush();
      expect(transport.requests.single.baseVersion, 0);
      expect(client.pending.single.state, MutationState.conflict);
      expect(server.documents['note']!.data!['text'], 'remote');
    },
  );

  test(
    'automatic polling honors Retry-After on sync before making another request',
    () async {
      final transport = TestTransport(server)
        ..syncFailure = const TransportException(
          statusCode: 429,
          code: 'throttled',
          message: 'wait',
          retryAfter: Duration(seconds: 10),
        );
      final client = await open(transport: transport);
      client.startPolling(interval: const Duration(seconds: 1));
      Future<void> waitForRequests(int count) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (transport.cursors.length < count &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(transport.cursors, hasLength(count));
      }

      await waitForRequests(1);
      expect(transport.cursors, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(transport.cursors, hasLength(1));
      now = now.add(const Duration(seconds: 11));
      await waitForRequests(2);
      expect(transport.cursors, hasLength(2));
      client.stopPolling();
    },
  );

  test(
    'opaque consistency envelope is persisted across reopen and cleared on revoke',
    () async {
      final transport = TestTransport(server);
      var client = await open(transport: transport);
      await client.put('note', {'text': 'one'});
      await client.flush();
      expect(client.cache.consistencyToken, 'token-1');
      await client.close();
      final resumed = TestTransport(server);
      client = await open(transport: resumed);
      expect(resumed.consistencyToken, 'token-1');
      resumed.sessionFailure = const TransportException(
        statusCode: 403,
        code: 'forbidden',
        message: 'revoked',
      );
      await expectLater(client.sync(), throwsA(isA<TransportException>()));
      expect(resumed.consistencyToken, isNull);
      expect(client.cache.consistencyToken, isNull);
    },
  );

  test(
    'native cache enforces one writer including canonical path aliases',
    () async {
      final client = await open();
      expect(() => SqliteCache(path), throwsStateError);
      expect(
        () => SqliteCache(
          '${directory.path}/../${directory.uri.pathSegments.where((part) => part.isNotEmpty).last}/cache.sqlite',
        ),
        throwsStateError,
      );
      expect(client.list(), isEmpty);
    },
  );

  test(
    'invalid IDs, oversized JSON and caller attempts to mutate snapshots fail locally',
    () async {
      final client = await open();
      expect(() => client.put('bad/slash', {}), throwsArgumentError);
      expect(
        () => client.put('large', {'text': 'a' * (255 * 1024)}),
        throwsArgumentError,
      );
      await client.put('note', {
        'nested': <Object?>['read-only'],
      });
      expect(
        () => client.get('note')!.data!['changed'] = true,
        throwsUnsupportedError,
      );
      expect(
        () => (client.get('note')!.data!['nested'] as List)[0] = 'changed',
        throwsUnsupportedError,
      );
    },
  );
}
