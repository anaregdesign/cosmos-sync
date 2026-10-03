@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:test/test.dart';

const identity = SessionInfo(
  scopeId: 'shared-scope',
  principalId: 'alice',
  permissionVersion: '1',
  scopeMode: SyncScopeMode.tenant,
);

ServerDocument confirmed(String id, int version, Map<String, Object?> data) =>
    ServerDocument(id: id, data: data, version: version, deleted: false);

void main() {
  late Directory directory;
  late String path;
  late QueryTransport transport;
  late CosmosSyncClient client;
  final subscriptions = <StreamSubscription<LocalQuerySnapshot>>[];

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('cosmos-query-client-');
    path = '${directory.path}/cache.sqlite';
    transport = QueryTransport();
    client = await CosmosSyncClient.open(
      path: path,
      transport: transport,
      session: identity,
    );
  });

  tearDown(() async {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    subscriptions.clear();
    await client.close();
    directory.deleteSync(recursive: true);
  });

  Future<List<LocalQuerySnapshot>> watch(LocalQuery query) async {
    final events = <LocalQuerySnapshot>[];
    subscriptions.add(client.watchQuery(query).listen(events.add));
    await Future<void>.delayed(Duration.zero);
    return events;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test(
    'watch emits initial incomplete view, partial page and coverage-only completion',
    () async {
      transport.pages.addAll([
        SyncPage(
          changes: [
            confirmed('a', 1, {'score': 1}),
          ],
          cursor: 'partial',
          hasMore: true,
        ),
        SyncPage(changes: [], cursor: 'complete', hasMore: false),
      ]);
      final events = await watch(LocalQuery());
      expect(events.single.isIncomplete, isTrue);
      await client.sync(maxPages: 1);
      await settle();
      expect(events.last.documents.single.id, 'a');
      expect(events.last.isIncomplete, isTrue);
      await client.sync(maxPages: 1);
      await settle();
      expect(events.last.documents.single.id, 'a');
      expect(events.last.completeAtCursor, 'complete');
      expect(events.every((event) => event.fromCache), isTrue);
      expect(events, hasLength(3));
    },
  );

  test(
    'pending delete/recreate and conflict update query results after durable writes',
    () async {
      transport.pages.add(
        SyncPage(
          changes: [
            confirmed('a', 1, {'status': 'open', 'score': 9}),
          ],
          cursor: 'initial',
          hasMore: false,
        ),
      );
      await client.sync();
      final query = LocalQuery(
        filters: [QueryFilter.eq(QueryField.named('status'), 'open')],
      );
      final events = await watch(query);
      await client.delete('a');
      await settle();
      expect(events.last.documents, isEmpty);
      expect(events.last.hasPendingWrites, isTrue);
      await client.discard(client.pending.single.operationId);
      await client.put('a', {'status': 'open', 'score': 1});
      transport.mutation = (request) async => throw TransportException(
        code: 'conflict',
        message: 'Concurrent update.',
        statusCode: 409,
        current: confirmed('a', 2, {'status': 'closed', 'score': 5}),
      );
      await client.flush();
      await settle();
      expect(events.last.documents.single.data!['score'], 1);
      expect(events.last.hasConflicts, isTrue);
      expect(events.last.documents.single.hasConflict, isTrue);
      await client.discard(client.pending.single.operationId);
      await settle();
      expect(events.last.documents, isEmpty);
      expect(events.last.hasPendingWrites, isFalse);
      expect(events.last.hasConflicts, isFalse);
      await client.put('a', {'status': 'open', 'score': 2});
      expect(client.query(query).documents.single.data!['score'], 2);
    },
  );

  test(
    'old ACK cannot reorder away a newer local overlay while watch updates metadata',
    () async {
      await client.sync();
      await client.put('a', {'score': 10});
      final entered = Completer<void>();
      final release = Completer<void>();
      transport.mutation = (request) async {
        entered.complete();
        await release.future;
        return confirmed(
          request.documentId,
          request.baseVersion + 1,
          request.data!,
        );
      };
      final query = LocalQuery(
        orderBy: [QueryOrder(QueryField.named('score'))],
      );
      final events = await watch(query);
      final flushing = client.flush(maxOperations: 1);
      await entered.future;
      await client.put('a', {'score': 1});
      release.complete();
      await flushing;
      await settle();
      expect(events.last.documents.single.data!['score'], 1);
      expect(events.last.documents.single.version, 1);
      expect(events.last.hasPendingWrites, isTrue);
      expect(client.pending, hasLength(1));
      transport.mutation = null;
      await client.flush();
      await settle();
      expect(events.last.documents.single.data!['score'], 1);
      expect(events.last.hasPendingWrites, isFalse);
    },
  );

  test(
    'cache reopening offline retains query overlays and saved coverage',
    () async {
      transport.pages.add(
        SyncPage(
          changes: [
            confirmed('a', 1, {'score': 5}),
          ],
          cursor: 'durable',
          hasMore: false,
        ),
      );
      await client.sync();
      await client.put('a', {'score': 2});
      await client.close();
      transport.authorizationError = const TransportException(
        code: 'offline',
        message: 'No network.',
      );
      // Reopen from saved verified session without a network request.
      client = await CosmosSyncClient.open(path: path, transport: transport);
      final snapshot = client.query(
        LocalQuery(orderBy: [QueryOrder(QueryField.named('score'))]),
      );
      expect(snapshot.documents.single.data!['score'], 2);
      expect(snapshot.hasPendingWrites, isTrue);
      expect(snapshot.completeAtCursor, 'durable');
      expect(snapshot.fromCache, isTrue);
    },
  );

  test(
    'expired sync cursor invalidates coverage and keeps pending overlay during replay',
    () async {
      transport.pages.add(
        SyncPage(
          changes: [
            confirmed('base', 1, {'score': 5}),
          ],
          cursor: 'old',
          hasMore: false,
        ),
      );
      await client.sync();
      await client.put('pending', {'score': 2});
      final events = await watch(LocalQuery());
      transport.syncError = const TransportException(
        code: 'resync_required',
        message: 'Generation changed.',
        statusCode: 410,
      );
      transport.pages.add(
        SyncPage(
          changes: [
            confirmed('new', 1, {'score': 1}),
          ],
          cursor: 'replay-partial',
          hasMore: true,
        ),
      );
      await client.sync(maxPages: 1);
      await settle();
      expect(
        events.any(
          (event) =>
              event.isIncomplete &&
              event.documents.map((d) => d.id).toList().join(',') == 'pending',
        ),
        isTrue,
      );
      expect(events.last.isIncomplete, isTrue);
      expect(events.last.documents.map((d) => d.id), ['new', 'pending']);
      expect(events.last.hasPendingWrites, isTrue);
      transport.pages.add(
        SyncPage(changes: [], cursor: 'replay-complete', hasMore: false),
      );
      await client.sync();
      expect(client.query(LocalQuery()).completeAtCursor, 'replay-complete');
    },
  );

  test(
    'authorization revocation emits empty paused query and removes coverage/outbox',
    () async {
      transport.pages.add(
        SyncPage(
          changes: [
            confirmed('a', 1, {'score': 5}),
          ],
          cursor: 'authorized',
          hasMore: false,
        ),
      );
      await client.sync();
      await client.put('pending', {'score': 2});
      final events = await watch(LocalQuery());
      transport.authorizationError = const TransportException(
        code: 'forbidden',
        message: 'Grant revoked.',
        statusCode: 403,
      );
      await expectLater(client.sync(), throwsA(isA<TransportException>()));
      await settle();
      expect(events.last.documents, isEmpty);
      expect(events.last.isIncomplete, isTrue);
      expect(events.last.metadata.paused, isTrue);
      expect(events.last.hasPendingWrites, isFalse);
      expect(client.pending, isEmpty);
    },
  );

  test(
    'shared-scope principal switch rejects previous query pagination cursor',
    () async {
      transport.pages.add(
        SyncPage(
          changes: [confirmed('a', 1, {}), confirmed('b', 1, {})],
          cursor: 'shared',
          hasMore: false,
        ),
      );
      await client.sync();
      final first = client.query(LocalQuery(limit: 1));
      final after = LocalQuery(startAfter: first.nextCursor);
      expect(client.query(after).documents.single.id, 'b');
      await client.signOut();
      transport.identity = const SessionInfo(
        scopeId: 'shared-scope',
        principalId: 'bob',
        permissionVersion: '1',
        scopeMode: SyncScopeMode.tenant,
      );
      await client.resume();
      expect(() => client.query(after), throwsArgumentError);
      expect(client.query(LocalQuery()).isIncomplete, isTrue);
    },
  );

  test(
    'paginated query watch reports scope invalidation as a stream error then closes',
    () async {
      transport.pages.add(
        SyncPage(
          changes: [confirmed('a', 1, {}), confirmed('b', 2, {})],
          cursor: 'shared',
          hasMore: false,
        ),
      );
      await client.sync();
      final cursor = client.query(LocalQuery(limit: 1)).nextCursor;
      final errors = <Object>[];
      final done = Completer<void>();
      subscriptions.add(
        client
            .watchQuery(LocalQuery(startAfter: cursor))
            .listen((_) {}, onError: errors.add, onDone: done.complete),
      );
      await settle();
      await client.signOut();
      transport.identity = const SessionInfo(
        scopeId: 'shared-scope',
        principalId: 'bob',
        permissionVersion: '1',
        scopeMode: SyncScopeMode.tenant,
      );
      await client.resume();
      await done.future;
      expect(errors.single, isA<ArgumentError>());
    },
  );
}

class QueryTransport implements SyncTransport {
  SessionInfo identity = const SessionInfo(
    scopeId: 'shared-scope',
    principalId: 'alice',
    permissionVersion: '1',
    scopeMode: SyncScopeMode.tenant,
  );
  final pages = <SyncPage>[];
  TransportException? authorizationError;
  TransportException? syncError;
  Future<ServerDocument> Function(MutationRequest)? mutation;

  @override
  Future<SessionInfo> sessionInfo() async {
    if (authorizationError != null) throw authorizationError!;
    return identity;
  }

  @override
  Future<ServerDocument> mutate(MutationRequest request) async {
    if (mutation != null) return mutation!(request);
    return ServerDocument(
      id: request.documentId,
      data: request.data,
      version: request.baseVersion + 1,
      deleted: request.kind == MutationKind.delete,
    );
  }

  @override
  Future<SyncPage> sync({String? cursor, int limit = 100}) async {
    if (syncError != null) {
      final error = syncError!;
      syncError = null;
      throw error;
    }
    return pages.isEmpty
        ? SyncPage(
            changes: [],
            cursor: cursor ?? 'empty-bootstrap',
            hasMore: false,
          )
        : pages.removeAt(0);
  }

  @override
  void close() {}
}
