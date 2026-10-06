import 'dart:async';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:test/test.dart';

import 'support/cache_location.dart';
import 'support/testing_transport.dart';

/// Runs unchanged against native SQLite and browser IndexedDB.
void main() {
  late TestCacheLocation location;
  late TestServer server;
  var now = DateTime.utc(2026, 10, 3);
  final clients = <CosmosSyncClient>[];

  Future<CosmosSyncClient> open({
    TestTransport? transport,
    SessionInfo session = scope,
  }) async {
    final client = await CosmosSyncClient.open(
      cache: await location.open(),
      transport: transport ?? TestTransport(server),
      session: session,
      clock: () => now,
    );
    clients.add(client);
    return client;
  }

  setUp(() async {
    location = await createTestCacheLocation();
    server = TestServer();
    now = DateTime.utc(2026, 10, 3);
  });
  tearDown(() async {
    for (final client in clients) {
      await client.close();
    }
    clients.clear();
    await location.cleanup();
  });

  test('verified identity binding survives durable adapter reopen', () async {
    final bound = SessionInfo(
      scopeId: scope.scopeId,
      principalId: scope.principalId,
      permissionVersion: scope.permissionVersion,
      scopeMode: scope.scopeMode,
      identityGeneration: 1,
      identityId: 'a' * 64,
    );
    server.session = bound;
    server.externalPut('confirmed', {'text': 'verified'});
    var client = await open(session: bound);
    await client.sync();
    final operation = await client.put('pending', {'text': 'offline'});
    await client.close();
    client = await open(session: bound);
    expect(client.cache.session!.sameScope(bound), isTrue);
    expect(client.cache.session!.identityGeneration, 1);
    expect(client.cache.session!.identityId, 'a' * 64);
    expect(client.get('confirmed')!.data!['text'], 'verified');
    expect(client.pending.single.operationId, operation);
    await client.flush();
    expect(client.pending, isEmpty);
  });

  for (final change in ['generation', 'credential', 'binding removal']) {
    test('identity $change purges before pending transmission', () async {
      final original = SessionInfo(
        scopeId: scope.scopeId,
        principalId: scope.principalId,
        permissionVersion: scope.permissionVersion,
        scopeMode: scope.scopeMode,
        identityGeneration: 1,
        identityId: 'a' * 64,
      );
      server.session = original;
      final transport = TestTransport(server);
      final client = await open(transport: transport, session: original);
      server.externalPut('confirmed', {'text': 'old context'});
      await client.sync();
      await client.put('pending', {'text': 'must not transmit'});
      final waiting = client.waitForPendingWrites();
      final expectation = expectLater(
        waiting,
        throwsA(
          isA<PendingWritesException>().having(
            (error) => error.reason,
            'reason',
            'authorization_changed',
          ),
        ),
      );
      server.session = SessionInfo(
        scopeId: original.scopeId,
        principalId: original.principalId,
        permissionVersion: original.permissionVersion,
        scopeMode: original.scopeMode,
        identityGeneration: change == 'binding removal'
            ? null
            : change == 'generation'
            ? 2
            : 1,
        identityId: change == 'binding removal'
            ? null
            : change == 'credential'
            ? 'b' * 64
            : original.identityId,
      );
      await expectLater(client.flush(), throwsStateError);
      await expectation;
      expect(transport.requests, isEmpty);
      expect(client.status.paused, isTrue);
      expect(client.get('confirmed'), isNull);
      expect(client.get('pending'), isNull);
      expect(client.pending, isEmpty);
      expect(client.cache.cursor, isNull);
      expect(client.cache.consistencyToken, isNull);
    });
  }

  test(
    'durable offline data and observed bases survive adapter reopen',
    () async {
      var client = await open();
      final id = await client.put('note', {'text': 'durable'});
      expect(client.pending.single.observedVersion, 0);
      expect(client.pending.single.baseVersion, isNull);
      await client.close();
      client = await open();
      expect(client.pending.single.operationId, id);
      expect(client.get('note')!.data!['text'], 'durable');
      await client.flush();
      expect(client.pending, isEmpty);
      expect(client.get('note')!.version, 1);
    },
  );

  test(
    'older in-flight ACK never replaces a subsequent durable local edit',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final transport = TestTransport(server)
        ..beforeMutation = (_) async {
          entered.complete();
          await release.future;
        };
      final client = await open(transport: transport);
      final firstId = await client.put('note', {'text': 'first'});
      final flushing = client.flush(maxOperations: 1);
      await entered.future;
      await client.put('note', {'text': 'second'});
      expect(client.pending.last.predecessorOperationId, firstId);
      release.complete();
      await flushing;
      expect(client.get('note')!.data!['text'], 'second');
      expect(client.get('note')!.version, 1);
      expect(client.pending.single.observedVersion, 1);
      expect(client.pending.single.predecessorOperationId, isNull);
      transport.beforeMutation = null;
      await client.flush();
      expect(server.documents['note']!.data!['text'], 'second');
    },
  );

  test(
    'lost ACK preserves exact payload, ID and base across reopen and pull',
    () async {
      final first = TestTransport(server)..loseNextAcknowledgement = true;
      var client = await open(transport: first);
      final id = await client.put('note', {'text': 'once'});
      await client.flush();
      expect(client.pending.single.baseVersion, 0);
      await client.close();
      now = now.add(const Duration(minutes: 1));
      final replay = TestTransport(server);
      client = await open(transport: replay);
      await client.sync();
      await client.flush();
      expect(replay.requests.single.operationId, id);
      expect(replay.requests.single.baseVersion, 0);
      expect(server.sequence, 1);
    },
  );

  test(
    'pull never silently rebases an offline edit onto a newer remote version',
    () async {
      server.externalPut('note', {'text': 'v1'});
      final transport = TestTransport(server);
      final client = await open(transport: transport);
      await client.sync();
      await client.put('note', {'text': 'offline-v1'});
      server.externalPut('note', {'text': 'remote-v2'});
      await client.sync();
      await client.flush();
      expect(transport.requests.single.baseVersion, 1);
      expect(client.pending.single.state, MutationState.conflict);
      expect(server.documents['note']!.data!['text'], 'remote-v2');
    },
  );

  test(
    'successor binds to actual predecessor ACK, even if a newer version was pulled',
    () async {
      server.externalPut('note', {'text': 'v1'});
      final transport = TestTransport(server)..loseNextAcknowledgement = true;
      final client = await open(transport: transport);
      await client.sync();
      await client.put('note', {'text': 'first'});
      await client.put('note', {'text': 'second'});
      await client.flush();
      server.externalPut('note', {'text': 'remote-v3'});
      now = now.add(const Duration(minutes: 1));
      await client.sync();
      await client.flush();
      expect(transport.requests.map((request) => request.baseVersion), [
        1,
        1,
        2,
      ]);
      expect(client.pending.single.state, MutationState.conflict);
      expect(server.documents['note']!.data!['text'], 'remote-v3');
    },
  );

  test(
    'page cursor, token and monotonic confirmed versions survive reopen',
    () async {
      var client = await open();
      await client.cache.applyPage(
        SyncPage(
          changes: [
            ServerDocument(
              id: 'note',
              data: {'text': 'new'},
              version: 5,
              deleted: false,
            ),
          ],
          cursor: 'cursor-5',
          hasMore: false,
        ),
        'opaque-token',
      );
      await client.cache.applyPage(
        SyncPage(
          changes: [
            ServerDocument(
              id: 'note',
              data: {'text': 'older'},
              version: 2,
              deleted: false,
            ),
          ],
          cursor: 'resume',
          hasMore: false,
        ),
        'opaque-token',
      );
      await client.close();
      client = await open();
      expect(client.get('note')!.version, 5);
      expect(client.cache.cursor, 'resume');
      expect(client.cache.consistencyToken, 'opaque-token');
      expect(client.cache.bootstrapIncomplete, isFalse);
    },
  );

  test(
    'conflict retry preserves queue dependencies and deletion tombstones',
    () async {
      server.externalPut('note', {'text': 'base'});
      var client = await open();
      await client.sync();
      final id = await client.delete('note');
      server.externalPut('note', {'text': 'new'});
      await client.flush();
      final retryId = await client.retryConflict(id);
      expect(retryId, isNot(id));
      await client.close();
      client = await open();
      expect(client.pending.single.data, isNull);
      await client.flush();
      expect(client.get('note')!.deleted, isTrue);
      expect(client.list(), isEmpty);
      expect(client.list(includeDeleted: true), hasLength(1));
    },
  );

  test(
    'shared scope principal switch purges pending data before transmission',
    () async {
      final transport = TestTransport(server);
      var client = await open(transport: transport);
      await client.put('private', {'text': 'alice'});
      server.session = SessionInfo(
        scopeId: scope.scopeId,
        principalId: 'bob',
        permissionVersion: scope.permissionVersion,
      );
      await expectLater(client.flush(), throwsStateError);
      expect(transport.requests, isEmpty);
      expect(client.status.paused, isTrue);
      expect(client.pending, isEmpty);
      expect(client.list(), isEmpty);
      await client.close();
      client = await open();
      expect(client.status.paused, isTrue);
      await client.resume();
      expect(client.session.principalId, 'bob');
    },
  );

  test('signOut waits for ACK then purges without late repopulation', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final transport = TestTransport(server)
      ..beforeMutation = (_) async {
        entered.complete();
        await release.future;
      };
    var client = await open(transport: transport);
    await client.put('private', {'text': 'in flight'});
    final flushing = client.flush();
    await entered.future;
    final signingOut = client.signOut();
    expect(() => client.put('new', {}), throwsStateError);
    release.complete();
    await flushing;
    await signingOut;
    expect(client.pending, isEmpty);
    expect(client.list(), isEmpty);
    await client.close();
    client = await open();
    expect(client.status.paused, isTrue);
    expect(client.list(), isEmpty);
  });

  test('second owner is rejected and close releases ownership', () async {
    final first = await open();
    await expectLater(location.open(), throwsStateError);
    await first.close();
    final second = await open();
    expect(second.list(), isEmpty);
  });
}
