import 'dart:convert';

import 'package:cosmos_sync/cosmos_sync.dart';

const scope = SessionInfo(
  scopeId: 'alice-tenant',
  principalId: 'principal',
  permissionVersion: '1',
);

class TestServer {
  SessionInfo session = scope;
  int sequence = 0;
  final documents = <String, ServerDocument>{};
  final journal = <ServerDocument>[];
  final receipts = <String, (String, ServerDocument)>{};

  ServerDocument apply(MutationRequest request) {
    final json = jsonEncode(request.toJson());
    final receipt = receipts[request.operationId];
    if (receipt != null) {
      if (receipt.$1 != json) {
        throw const TransportException(
          statusCode: 409,
          code: 'idempotency_mismatch',
          message: 'different request',
        );
      }
      return receipt.$2;
    }
    final current = documents[request.documentId];
    if (request.baseVersion != (current?.version ?? 0)) {
      throw TransportException(
        statusCode: 409,
        code: 'conflict',
        message: 'stale',
        current: current,
      );
    }
    final document = ServerDocument(
      id: request.documentId,
      data: request.data,
      version: ++sequence,
      deleted: request.kind == MutationKind.delete,
    );
    documents[document.id] = document;
    journal.add(document);
    receipts[request.operationId] = (json, document);
    return document;
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

  void externalDelete(String id) {
    final document = ServerDocument(
      id: id,
      data: null,
      version: ++sequence,
      deleted: true,
    );
    documents[id] = document;
    journal.add(document);
  }
}

class TestTransport implements SyncTransport, ConsistencyTokenTransport {
  TestTransport(this.server);
  final TestServer server;
  final requests = <MutationRequest>[];
  final cursors = <String?>[];
  Future<void> Function(MutationRequest request)? beforeMutation;
  TransportException? sessionFailure;
  TransportException? mutationFailure;
  TransportException? syncFailure;
  bool loseNextAcknowledgement = false;
  @override
  String? consistencyToken;

  @override
  Future<SessionInfo> sessionInfo() async {
    final error = sessionFailure;
    if (error != null) throw error;
    return server.session;
  }

  @override
  Future<ServerDocument> mutate(MutationRequest request) async {
    requests.add(request);
    await beforeMutation?.call(request);
    final error = mutationFailure;
    mutationFailure = null;
    if (error != null) throw error;
    final document = server.apply(request);
    consistencyToken = 'token-${server.sequence}';
    if (loseNextAcknowledgement) {
      loseNextAcknowledgement = false;
      throw const TransportException(
        code: 'network_error',
        message: 'lost ACK',
      );
    }
    return document;
  }

  @override
  Future<SyncPage> sync({String? cursor, int limit = 100}) async {
    cursors.add(cursor);
    final error = syncFailure;
    syncFailure = null;
    if (error != null) throw error;
    final after = cursor == null ? 0 : int.parse(cursor);
    final changes = server.journal
        .where((document) => document.version > after)
        .take(limit)
        .toList();
    final next = changes.isEmpty ? after : changes.last.version;
    consistencyToken = 'token-${server.sequence}';
    return SyncPage(
      changes: changes,
      cursor: '$next',
      hasMore: next < server.sequence,
    );
  }

  @override
  void close() {}
}
