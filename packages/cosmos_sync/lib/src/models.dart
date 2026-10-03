import 'dart:convert';

/// Server-verified authorization scope. It contains no Cosmos credential.
enum SyncScopeMode { user, tenant }

class SessionInfo {
  const SessionInfo({
    required this.scopeId,
    required this.principalId,
    required this.permissionVersion,
    this.scopeMode = SyncScopeMode.user,
  });

  factory SessionInfo.fromJson(
    Map<String, Object?> json, {
    bool allowLegacy = false,
  }) => SessionInfo(
    scopeId: json['scopeId'] as String,
    principalId: allowLegacy
        ? (json['principalId'] as String? ?? 'legacy-unverified')
        : json['principalId'] as String,
    permissionVersion: json['permissionVersion'] as String,
    scopeMode: SyncScopeMode.values.byName(
      allowLegacy
          ? (json['scopeMode'] as String? ?? 'user')
          : json['scopeMode'] as String,
    ),
  );

  final String scopeId;
  final String principalId;
  final String permissionVersion;
  final SyncScopeMode scopeMode;

  Map<String, Object?> toJson() => {
    'scopeId': scopeId,
    'principalId': principalId,
    'permissionVersion': permissionVersion,
    'scopeMode': scopeMode.name,
  };

  bool sameScope(SessionInfo other) =>
      scopeId == other.scopeId &&
      principalId == other.principalId &&
      permissionVersion == other.permissionVersion &&
      scopeMode == other.scopeMode;
}

/// A confirmed document or retained server deletion tombstone.
class ServerDocument {
  ServerDocument({
    required this.id,
    required Map<String, Object?>? data,
    required this.version,
    required this.deleted,
  }) : data = data == null ? null : immutableJson(data) {
    if (id.isEmpty ||
        version < 1 ||
        version > 9007199254740991 ||
        (deleted ? data != null : data == null)) {
      throw FormatException('Invalid server document.');
    }
  }

  factory ServerDocument.fromJson(Map<String, Object?> json) => ServerDocument(
    id: json['id'] as String,
    data: (json['data'] as Map?)?.cast<String, Object?>(),
    version: json['version'] as int,
    deleted: json['deleted'] as bool,
  );

  final String id;
  final Map<String, Object?>? data;
  final int version;
  final bool deleted;

  Map<String, Object?> toJson() => {
    'id': id,
    'data': data,
    'version': version,
    'deleted': deleted,
  };
}

enum MutationKind { put, delete }

/// An immutable wire request, persisted exactly before its first transmission.
class MutationRequest {
  MutationRequest({
    required this.operationId,
    required this.documentId,
    required this.kind,
    required Map<String, Object?>? data,
    required this.baseVersion,
  }) : data = data == null ? null : immutableJson(data) {
    if (baseVersion < 0 || baseVersion > 9007199254740991) {
      throw FormatException('Invalid mutation base version.');
    }
  }

  final String operationId;
  final String documentId;
  final MutationKind kind;
  final Map<String, Object?>? data;
  final int baseVersion;

  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'documentId': documentId,
    'kind': kind.name,
    'data': data,
    'baseVersion': baseVersion,
  };
}

class SyncPage {
  SyncPage({
    required List<ServerDocument> changes,
    required this.cursor,
    required this.hasMore,
  }) : changes = List.unmodifiable(changes) {
    if (cursor.isEmpty) throw FormatException('Invalid sync cursor.');
  }

  factory SyncPage.fromJson(Map<String, Object?> json) => SyncPage(
    changes: (json['changes'] as List)
        .map((value) => ServerDocument.fromJson((value as Map).cast()))
        .toList(),
    cursor: json['cursor'] as String,
    hasMore: json['hasMore'] as bool,
  );

  final List<ServerDocument> changes;
  final String cursor;
  final bool hasMore;
}

/// A stable initial view at one partition sequence, with a separate resume cursor.
class SnapshotPage {
  SnapshotPage({
    required List<ServerDocument> documents,
    required this.cursor,
    required this.syncCursor,
    required this.cutoverSequence,
    required this.hasMore,
  }) : documents = List.unmodifiable(documents) {
    if (cursor.isEmpty ||
        syncCursor.isEmpty ||
        cutoverSequence < 0 ||
        cutoverSequence > 9007199254740991 ||
        documents.any((document) => document.version > cutoverSequence)) {
      throw FormatException('Invalid snapshot page.');
    }
  }
  factory SnapshotPage.fromJson(Map<String, Object?> json) => SnapshotPage(
    documents: (json['documents'] as List)
        .map((value) => ServerDocument.fromJson((value as Map).cast()))
        .toList(),
    cursor: json['cursor'] as String,
    syncCursor: json['syncCursor'] as String,
    cutoverSequence: json['cutoverSequence'] as int,
    hasMore: json['hasMore'] as bool,
  );
  final List<ServerDocument> documents;
  final String cursor;
  final String syncCursor;
  final int cutoverSequence;
  final bool hasMore;
}

abstract interface class SnapshotTransport {
  Future<SnapshotPage> snapshot({String? cursor, int limit = 100});
}

/// An SSE hint ID resumes only the hint stream; it is never a sync cursor.
class ChangeHint {
  const ChangeHint({required this.resumeId, this.consistencyToken});
  final String resumeId;
  final String? consistencyToken;
}

abstract interface class ChangeHintTransport {
  Stream<ChangeHint> watchChanges({String? lastEventId, String? cursor});
}

abstract interface class SyncTransport {
  Future<SessionInfo> sessionInfo();
  Future<ServerDocument> mutate(MutationRequest request);
  Future<SyncPage> sync({String? cursor, int limit = 100});
  void close();
}

/// Optional opaque BFF consistency envelope, persisted alongside ACKs/pages.
abstract interface class ConsistencyTokenTransport {
  String? get consistencyToken;
  set consistencyToken(String? value);
}

class TransportException implements Exception {
  const TransportException({
    required this.code,
    required this.message,
    this.statusCode,
    this.retryAfter,
    this.current,
  });

  final int? statusCode;
  final String code;
  final String message;
  final Duration? retryAfter;
  final ServerDocument? current;

  bool get retryable =>
      statusCode == null || statusCode == 429 || (statusCode ?? 0) >= 500;

  bool get authorizationFailure => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'TransportException($statusCode, $code): $message';
}

enum MutationState { queued, conflict, rejected }

/// A durable local write. Later writes to a conflicted document remain blocked.
class PendingMutation {
  PendingMutation({
    required this.sequence,
    required this.operationId,
    required this.documentId,
    required this.kind,
    required Map<String, Object?>? data,
    required this.state,
    required this.attempts,
    required this.baseVersion,
    required this.observedVersion,
    required this.predecessorOperationId,
    required this.nextAttemptAt,
    this.errorCode,
  }) : data = data == null ? null : immutableJson(data);

  final int sequence;
  final String operationId;
  final String documentId;
  final MutationKind kind;
  final Map<String, Object?>? data;
  final MutationState state;
  final int attempts;
  final int? baseVersion;

  /// Version observed when editing, or the acknowledged predecessor's version.
  final int observedVersion;

  /// Unacknowledged previous edit to the same document, if any.
  final String? predecessorOperationId;
  final DateTime? nextAttemptAt;
  final String? errorCode;

  MutationRequest get request => MutationRequest(
    operationId: operationId,
    documentId: documentId,
    kind: kind,
    data: data,
    baseVersion: baseVersion ?? (throw StateError('Not prepared for sending.')),
  );
}

/// A local view: latest pending write overlays the latest confirmed base.
class DocumentSnapshot {
  DocumentSnapshot({
    required this.id,
    required Map<String, Object?>? data,
    required this.version,
    required this.deleted,
    required this.hasPendingWrites,
    required this.hasConflict,
  }) : data = data == null ? null : immutableJson(data);

  final String id;
  final Map<String, Object?>? data;

  /// Last confirmed server version; 0 means no confirmed base yet.
  final int version;
  final bool deleted;
  final bool hasPendingWrites;
  final bool hasConflict;
}

class FlushResult {
  const FlushResult({
    required this.acknowledged,
    required this.remaining,
    this.retryAt,
  });

  final int acknowledged;
  final int remaining;
  final DateTime? retryAt;
}

class SyncStatus {
  const SyncStatus({required this.paused, this.reason, this.lastError});
  final bool paused;
  final String? reason;
  final Object? lastError;
}

class PendingWritesException implements Exception {
  const PendingWritesException({required this.reason, this.operationId});
  final String reason;
  final String? operationId;
  @override
  String toString() =>
      'PendingWritesException($reason${operationId == null ? '' : ', $operationId'})';
}

/// Deeply copied JSON prevents caller mutation after persistence or sending.
Map<String, Object?> immutableJson(Map<String, Object?> value) {
  Object? freeze(Object? item) => switch (item) {
    Map value => Map<String, Object?>.unmodifiable(
      value.cast<String, Object?>().map(
        (key, value) => MapEntry(key, freeze(value)),
      ),
    ),
    List value => List<Object?>.unmodifiable(value.map(freeze)),
    int value when value < -9007199254740991 || value > 9007199254740991 =>
      throw const FormatException(
        'JSON integers must fit the exact portable range ±(2^53−1).',
      ),
    double value
        when !value.isFinite ||
            (value.abs() > 9007199254740991 &&
                value == value.truncateToDouble()) =>
      throw const FormatException(
        'JSON numbers must be finite and preserve portable integer precision.',
      ),
    _ => item,
  };
  // Check raw numbers before serialization can change their representation.
  final decoded = jsonDecode(jsonEncode(freeze(value))) as Map<String, dynamic>;
  return freeze(decoded) as Map<String, Object?>;
}
