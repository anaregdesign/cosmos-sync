import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';

/// Runnable native cache example. DemoTransport is not a production BFF.
Future<void> main() async {
  final directory = Directory.systemTemp.createTempSync('cosmos-sync-example-');
  final path = '${directory.path}/cache.sqlite';
  const scope = SessionInfo(
    principalId: 'principal',
    scopeId: 'demo-user',
    permissionVersion: '1',
  );
  final server = DemoServer();
  var client = await CosmosSyncClient.open(
    path: path,
    transport: DemoTransport(server),
    session: scope,
  );
  try {
    await client.put('note-1', {'text': 'Saved locally while offline'});
    print('Offline pending: ${client.get('note-1')!.hasPendingWrites}');
    await client.close();
    client = await CosmosSyncClient.open(
      path: path,
      transport: DemoTransport(server),
    );
    print('After restart: ${client.get('note-1')!.data!['text']}');
    await client.flush();
    print('Acknowledged version: ${client.get('note-1')!.version}');
    await client.delete('note-1');
    await client.flush();
    print('Deletion tombstone: ${client.get('note-1')!.deleted}');
  } finally {
    await client.close();
    directory.deleteSync(recursive: true);
  }
}

class DemoServer {
  int sequence = 0;
  final documents = <String, ServerDocument>{};
  final receipts = <String, ServerDocument>{};
  final journal = <ServerDocument>[];
}

class DemoTransport implements SyncTransport {
  DemoTransport(this.server);
  final DemoServer server;

  @override
  Future<SessionInfo> sessionInfo() async => const SessionInfo(
    principalId: 'principal',
    scopeId: 'demo-user',
    permissionVersion: '1',
  );

  @override
  Future<ServerDocument> mutate(MutationRequest request) async {
    final receipt = server.receipts[request.operationId];
    if (receipt != null) return receipt;
    final current = server.documents[request.documentId];
    if ((current?.version ?? 0) != request.baseVersion) {
      throw TransportException(
        statusCode: 409,
        code: 'conflict',
        message: 'Changed remotely',
        current: current,
      );
    }
    final document = ServerDocument(
      id: request.documentId,
      data: request.data,
      version: ++server.sequence,
      deleted: request.kind == MutationKind.delete,
    );
    server.documents[document.id] = document;
    server.receipts[request.operationId] = document;
    server.journal.add(document);
    return document;
  }

  @override
  Future<SyncPage> sync({String? cursor, int limit = 100}) async {
    final after = cursor == null ? 0 : int.parse(cursor);
    final changes = server.journal
        .where((document) => document.version > after)
        .take(limit)
        .toList();
    final next = changes.isEmpty ? after : changes.last.version;
    return SyncPage(
      changes: changes,
      cursor: '$next',
      hasMore: next < server.sequence,
    );
  }

  @override
  void close() {}
}
