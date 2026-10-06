import 'dart:async';
import 'package:cosmos_sync/cosmos_sync.dart';

class TestServer {
  String principal = 'alice';
  int? identityGeneration;
  String? identityId;
  bool offline = false;
  bool revoked = false;
  bool capacityExceeded = false;
  int sequence = 0;
  final documents = <String, ServerDocument>{};
  final requests = <MutationRequest>[];
  Completer<ServerDocument>? inFlight;
  final started = Completer<void>();
}

class TestTransport implements SyncTransport {
  TestTransport(this.server);
  final TestServer server;
  @override
  Future<SessionInfo> sessionInfo() async {
    if (server.offline) {
      throw const TransportException(code: 'network', message: 'Offline');
    }
    if (server.revoked) {
      throw const TransportException(
        statusCode: 403,
        code: 'permission_denied',
        message: 'Revoked',
      );
    }
    return SessionInfo(
      scopeId: 'scope',
      principalId: server.principal,
      permissionVersion: '1',
      identityGeneration: server.identityGeneration,
      identityId: server.identityId,
    );
  }

  @override
  Future<ServerDocument> mutate(MutationRequest request) async {
    server.requests.add(request);
    if (!server.started.isCompleted) server.started.complete();
    if (server.inFlight != null) return server.inFlight!.future;
    if (server.capacityExceeded) {
      throw const TransportException(
        statusCode: 507,
        code: 'scope_capacity_exceeded',
        message: 'Capacity',
      );
    }
    final document = ServerDocument(
      id: request.documentId,
      data: request.data,
      version: ++server.sequence,
      deleted: request.kind == MutationKind.delete,
    );
    server.documents[document.id] = document;
    return document;
  }

  @override
  Future<SyncPage> sync({String? cursor, int limit = 100}) async => SyncPage(
    changes: server.documents.values.toList(),
    cursor: 'cursor-${server.sequence}',
    hasMore: false,
  );
  @override
  void close() {}
}
