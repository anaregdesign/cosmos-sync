import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:cosmos_sync_flutter_smoke/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('durable offline SDK runs in a native Flutter application', (
    tester,
  ) async {
    final finished = Completer<void>();
    Object? failure;
    await tester.pumpWidget(
      SmokeApp(
        runValidation: () async {
          try {
            await _validateOfflineContract();
          } catch (error) {
            failure = error;
            rethrow;
          } finally {
            finished.complete();
          }
        },
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('run-validation')));
      await finished.future.timeout(const Duration(seconds: 45));
    });
    await tester.pumpAndSettle();
    expect(failure, isNull, reason: '$failure');
    expect(find.text('Passed'), findsOneWidget);
  });
}

Future<void> _validateOfflineContract() async {
  final support = await getApplicationSupportDirectory();
  final directory = await Directory(
    '${support.path}/cosmos-sync-validation-${DateTime.now().microsecondsSinceEpoch}',
  ).create(recursive: true);
  final path = '${directory.path}/offline.sqlite';
  final server = _Server();
  var now = DateTime.utc(2026, 10, 3);
  CosmosSyncClient? client;
  StreamSubscription<LocalQuerySnapshot>? watch;
  try {
    var transport = _Transport(server);
    client = await CosmosSyncClient.open(
      path: path,
      transport: transport,
      clock: () => now,
    );
    final operation = await client.put('note', {'text': 'offline', 'rank': 1});
    expect(client.get('note')!.hasPendingWrites, isTrue);
    expect(server.sequence, 0);
    await client.close();

    transport = _Transport(server)..loseNextAcknowledgement = true;
    client = await CosmosSyncClient.open(
      path: path,
      transport: transport,
      clock: () => now,
    );
    expect(client.pending.single.operationId, operation);
    expect(client.get('note')!.data!['text'], 'offline');
    final ambiguous = await client.flush();
    expect(ambiguous.acknowledged, 0);
    expect(client.pending.single.attempts, 1);
    expect(server.sequence, 1);
    final exactRequest = jsonEncode(transport.requests.single.toJson());
    await client.close();

    now = now.add(const Duration(minutes: 1));
    transport = _Transport(server);
    client = await CosmosSyncClient.open(
      path: path,
      transport: transport,
      clock: () => now,
    );
    expect(client.pending.single.operationId, operation);
    expect((await client.flush()).acknowledged, 1);
    expect(jsonEncode(transport.requests.single.toJson()), exactRequest);
    expect(
      server.sequence,
      1,
      reason: 'Exact receipt replay cannot write twice.',
    );
    expect(client.get('note')!.hasPendingWrites, isFalse);
    await client.sync(pageSize: 1);

    final stale = await client.put('note', {'text': 'local', 'rank': 2});
    server.externalPut('note', {'text': 'remote', 'rank': 3});
    await client.sync(pageSize: 1);
    await client.flush();
    expect(client.pending.single.operationId, stale);
    expect(client.pending.single.state, MutationState.conflict);
    expect(client.get('note')!.data!['text'], 'local');
    await client.close();

    transport = _Transport(server);
    client = await CosmosSyncClient.open(
      path: path,
      transport: transport,
      clock: () => now,
    );
    expect(client.pending.single.state, MutationState.conflict);
    await client.retryConflict(stale, data: {'text': 'merged', 'rank': 4});
    expect((await client.flush()).acknowledged, 1);
    await client.sync(pageSize: 1);

    final query = LocalQuery(
      filters: [QueryFilter.gte(QueryField.named('rank'), 4)],
      orderBy: [QueryOrder(QueryField.named('rank'))],
      limit: 10,
    );
    final observed = <LocalQuerySnapshot>[];
    watch = client.watchQuery(query).listen(observed.add);
    await Future<void>.delayed(Duration.zero);
    expect(client.query(query).documents.single.id, 'note');
    expect(client.query(query).completeAtCursor, isNotNull);
    await client.put('other', {'text': 'pending', 'rank': 5});
    await Future<void>.delayed(Duration.zero);
    expect(observed.last.documents.map((document) => document.id), [
      'note',
      'other',
    ]);
    expect(observed.last.hasPendingWrites, isTrue);
    await client.flush();
    await client.delete('note');
    expect(client.get('note')!.deleted, isTrue);
    await client.flush();
    await client.sync(pageSize: 1);
    expect(client.query(query).documents.map((document) => document.id), [
      'other',
    ]);
    await client.put('note', {'text': 'recreated', 'rank': 6});
    await client.flush();
    expect(client.get('note')!.deleted, isFalse);
    expect(client.get('note')!.data!['text'], 'recreated');
    await watch.cancel();
    watch = null;

    await client.put('private', {'text': 'must purge', 'rank': 7});
    transport.revoked = true;
    await expectLater(client.sync(), throwsA(isA<TransportException>()));
    expect(client.status.paused, isTrue);
    expect(client.list(), isEmpty);
    expect(client.pending, isEmpty);
    await client.close();
    client = null;

    client = await CosmosSyncClient.open(
      path: path,
      transport: _Transport(server),
      clock: () => now,
    );
    expect(client.status.paused, isTrue);
    expect(client.list(), isEmpty);
    expect(client.pending, isEmpty);
    debugPrint('COSMOS_SYNC_NATIVE_PASS ${Platform.operatingSystem}');
  } finally {
    await watch?.cancel();
    await client?.close();
    await directory.delete(recursive: true);
  }
}

class _Server {
  static const session = SessionInfo(
    scopeId: 'fixture-scope',
    principalId: 'fixture-principal',
    permissionVersion: '1',
  );
  int sequence = 0;
  final documents = <String, ServerDocument>{};
  final journal = <ServerDocument>[];
  final receipts = <String, (String, ServerDocument)>{};

  ServerDocument apply(MutationRequest request) {
    final payload = jsonEncode(request.toJson());
    final receipt = receipts[request.operationId];
    if (receipt != null) {
      if (receipt.$1 != payload) {
        throw const TransportException(
          statusCode: 409,
          code: 'idempotency_mismatch',
          message: 'Operation payload changed.',
        );
      }
      return receipt.$2;
    }
    final current = documents[request.documentId];
    if (request.baseVersion != (current?.version ?? 0)) {
      throw TransportException(
        statusCode: 409,
        code: 'conflict',
        message: 'Observed version is stale.',
        current: current,
      );
    }
    final result = ServerDocument(
      id: request.documentId,
      data: request.data,
      version: ++sequence,
      deleted: request.kind == MutationKind.delete,
    );
    documents[result.id] = result;
    journal.add(result);
    receipts[request.operationId] = (payload, result);
    return result;
  }

  void externalPut(String id, Map<String, Object?> data) {
    final document = ServerDocument(
      id: id,
      data: data,
      version: ++sequence,
      deleted: false,
    );
    documents[id] = document;
    journal.add(document);
  }
}

class _Transport implements SyncTransport, ConsistencyTokenTransport {
  _Transport(this.server);
  final _Server server;
  final requests = <MutationRequest>[];
  bool loseNextAcknowledgement = false;
  bool revoked = false;
  @override
  String? consistencyToken;

  @override
  Future<SessionInfo> sessionInfo() async {
    if (revoked) {
      throw const TransportException(
        statusCode: 403,
        code: 'forbidden',
        message: 'Fixture grant revoked.',
      );
    }
    return _Server.session;
  }

  @override
  Future<ServerDocument> mutate(MutationRequest request) async {
    requests.add(request);
    final result = server.apply(request);
    consistencyToken = 'fixture-session-${server.sequence}';
    if (loseNextAcknowledgement) {
      loseNextAcknowledgement = false;
      throw const TransportException(
        code: 'network_error',
        message: 'Fixture loses the first acknowledged response.',
      );
    }
    return result;
  }

  @override
  Future<SyncPage> sync({String? cursor, int limit = 100}) async {
    final after = cursor == null ? 0 : int.parse(cursor);
    final changes = server.journal
        .where((document) => document.version > after)
        .take(limit)
        .toList();
    final next = changes.isEmpty ? after : changes.last.version;
    consistencyToken = 'fixture-session-${server.sequence}';
    return SyncPage(
      changes: changes,
      cursor: '$next',
      hasMore: next < server.sequence,
    );
  }

  @override
  void close() {}
}
