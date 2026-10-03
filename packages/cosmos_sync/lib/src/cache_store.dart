import 'dart:async';

import 'models.dart';

/// A fully opened, single-owner durable cache with committed synchronous reads.
///
/// Every mutating method is atomic and must finish durable storage before its
/// return value/Future completes. Failed writes must leave all readable state
/// unchanged. Clients await FutureOr operations on both native and Web adapters.
abstract interface class CacheStore {
  SessionInfo? get session;
  bool get paused;
  String? get pauseReason;
  String? get cursor;
  String? get consistencyToken;
  bool get bootstrapIncomplete;
  bool get journalBootstrap;
  String? get snapshotCursor;
  int? get snapshotCutoverSequence;
  List<PendingMutation> get pending;
  int get pendingCount;
  DateTime? get nextRetryAt;

  DocumentSnapshot? get(String id);
  List<DocumentSnapshot> list({bool includeDeleted = false});
  PendingMutation? nextReady(DateTime now);

  FutureOr<void> initialize(SessionInfo scope);
  FutureOr<void> purgeAndPause(String reason);
  FutureOr<void> resumeFor(SessionInfo scope);
  FutureOr<void> enqueue({
    required String operationId,
    required String documentId,
    required MutationKind kind,
    required Map<String, Object?>? data,
  });
  FutureOr<PendingMutation> prepare(PendingMutation mutation);
  FutureOr<void> acknowledge(
    PendingMutation mutation,
    ServerDocument document,
    String? token,
  );
  FutureOr<void> defer(PendingMutation mutation, DateTime until, String code);
  FutureOr<void> markConflict(
    PendingMutation mutation,
    ServerDocument? current,
  );
  FutureOr<void> markRejected(PendingMutation mutation, String code);
  FutureOr<void> retryConflict(
    String operationId,
    String newOperationId, {
    Map<String, Object?>? replacementData,
  });
  FutureOr<void> discard(String operationId);
  FutureOr<void> applyPage(SyncPage page, String? token);
  FutureOr<void> applySnapshotPage(SnapshotPage page, String? token);
  FutureOr<void> resetForResync({bool journalOnly = false});
  FutureOr<void> close();
}
