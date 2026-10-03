import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'cache_store.dart';
import 'models.dart';

/// Durable browser storage with one lifetime owner per database and origin.
///
/// Requires a secure context, native IndexedDB with strict transaction
/// durability, and Web Locks. Unsupported environments fail at [open]. No
/// volatile fallback is provided. Browser storage can still be evicted by the
/// user or browser; strict durability does not make it a backup.
///
/// Confirmed documents, outbox records, and metadata are separate IndexedDB
/// records. A write publishes its synchronous read view only after the native
/// transaction completes. Opening loads the committed records into memory;
/// writes copy and compare the in-memory maps, but persist only changed records.
class IndexedDbCache implements CacheStore {
  IndexedDbCache._(
    this._database,
    this._state,
    this._releaseLock,
    this._lockLifetime,
    this._transactionHookForTesting,
  );

  /// Acquires an exclusive Web Lock without waiting for another tab to close.
  ///
  /// [transactionHookForTesting] is a synchronous fault-injection hook, called
  /// after queuing writes and before their transaction commits. It is intended
  /// only for tests which abort the supplied native transaction.
  static Future<IndexedDbCache> open(
    String name, {
    void Function(web.IDBTransaction)? transactionHookForTesting,
  }) async {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Cannot be empty.');
    }
    if (!web.window.isSecureContext) {
      throw UnsupportedError(
        'IndexedDB cache requires a secure browser context.',
      );
    }
    final locks = web.window.navigator.getProperty<JSAny?>('locks'.toJS);
    final indexedDb = web.window.getProperty<JSAny?>('indexedDB'.toJS);
    if (locks == null || indexedDb == null) {
      throw UnsupportedError(
        'IndexedDB cache requires native IndexedDB and Web Locks.',
      );
    }
    final acquired = Completer<bool>();
    final release = Completer<JSAny?>();
    final lockLifetime = (locks as web.LockManager)
        .request(
          'cosmos-sync:indexeddb:$name',
          web.LockOptions(mode: 'exclusive', ifAvailable: true),
          ((web.Lock? lock) {
            acquired.complete(lock != null);
            return lock == null
                ? Future<JSAny?>.value(null).toJS
                : release.future.toJS;
          }).toJS,
        )
        .toDart;
    // Attach a rejection handler immediately; open() waits for acquisition,
    // while the request promise deliberately remains pending for the lifetime.
    unawaited(
      lockLifetime.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (!acquired.isCompleted) acquired.completeError(error, stack);
        },
      ),
    );
    if (!await acquired.future) {
      await lockLifetime;
      throw StateError(
        'A Cosmos Sync cache is already open in this origin: $name.',
      );
    }
    web.IDBDatabase? database;
    try {
      database = await _openDatabase(name);
      var versionChanged = false;
      database.onversionchange = ((web.Event _) {
        versionChanged = true;
        database!.close();
      }).toJS;
      final state = await _readState(database);
      if (versionChanged) {
        throw StateError('IndexedDB changed while opening the cache.');
      }
      final cache = IndexedDbCache._(
        database,
        state,
        release,
        lockLifetime,
        transactionHookForTesting,
      );
      // Probe actual strict-durability support before exposing a cache. Persist
      // the small schema/metadata record even for a newly created empty cache.
      await cache._persistDiff(
        state,
        state,
        forceMetadata: true,
        runTestHook: false,
      );
      if (versionChanged) {
        throw StateError('IndexedDB changed while opening the cache.');
      }
      database.onversionchange = ((web.Event _) {
        unawaited(cache.close());
      }).toJS;
      database.onclose = ((web.Event _) {
        cache._databaseLost = true;
        unawaited(cache.close());
      }).toJS;
      return cache;
    } catch (_) {
      database?.close();
      release.complete(null);
      await lockLifetime;
      rethrow;
    }
  }

  static const _storeNames = ['metadata', 'documents', 'outbox'];
  final web.IDBDatabase _database;
  final Completer<JSAny?> _releaseLock;
  final Future<JSAny?> _lockLifetime;
  final void Function(web.IDBTransaction)? _transactionHookForTesting;
  _CacheState _state;
  Future<void> _writeTail = Future.value();
  Future<void>? _closeFuture;
  bool _closing = false;
  bool _closed = false;
  bool _databaseLost = false;

  void _checkReadable() {
    if (_closed || _databaseLost) {
      throw StateError('IndexedDB cache is closed.');
    }
  }

  @override
  SessionInfo? get session {
    _checkReadable();
    return _state.session;
  }

  @override
  bool get paused {
    _checkReadable();
    return _state.paused;
  }

  @override
  String? get pauseReason {
    _checkReadable();
    return _state.pauseReason;
  }

  @override
  String? get cursor {
    _checkReadable();
    return _state.cursor;
  }

  @override
  String? get snapshotCursor {
    _checkReadable();
    return _state.snapshotCursor;
  }

  @override
  int? get snapshotCutoverSequence {
    _checkReadable();
    return _state.snapshotCutoverSequence;
  }

  @override
  String? get consistencyToken {
    _checkReadable();
    return _state.consistencyToken;
  }

  @override
  bool get bootstrapIncomplete {
    _checkReadable();
    return _state.bootstrapIncomplete;
  }

  @override
  bool get journalBootstrap {
    _checkReadable();
    return _state.journalBootstrap;
  }

  @override
  List<PendingMutation> get pending {
    _checkReadable();
    return _orderedPending(_state);
  }

  @override
  int get pendingCount {
    _checkReadable();
    return _state.outbox.length;
  }

  @override
  DocumentSnapshot? get(String id) {
    _checkReadable();
    final base = _state.documents[id];
    final overlays = _orderedPending(
      _state,
    ).where((item) => item.documentId == id).toList();
    if (base == null && overlays.isEmpty) return null;
    final latest = overlays.isEmpty ? null : overlays.last;
    return DocumentSnapshot(
      id: id,
      data: latest != null ? latest.data : base!.data,
      version: base?.version ?? 0,
      deleted: latest != null
          ? latest.kind == MutationKind.delete
          : base!.deleted,
      hasPendingWrites: latest != null,
      hasConflict: overlays.any((item) => item.state == MutationState.conflict),
    );
  }

  @override
  List<DocumentSnapshot> list({bool includeDeleted = false}) {
    _checkReadable();
    final ids = {
      ..._state.documents.keys,
      ..._state.outbox.values.map((item) => item.documentId),
    }.toList()..sort();
    return ids
        .map((id) => get(id)!)
        .where((item) => includeDeleted || !item.deleted)
        .toList(growable: false);
  }

  @override
  PendingMutation? nextReady(DateTime now) {
    _checkReadable();
    final seen = <String>{};
    for (final item in _orderedPending(_state)) {
      if (!seen.add(item.documentId)) continue;
      if (item.state == MutationState.queued &&
          (item.nextAttemptAt == null || !item.nextAttemptAt!.isAfter(now))) {
        return item;
      }
    }
    return null;
  }

  @override
  DateTime? get nextRetryAt {
    _checkReadable();
    DateTime? earliest;
    final seen = <String>{};
    for (final item in _orderedPending(_state)) {
      if (!seen.add(item.documentId) || item.state != MutationState.queued) {
        continue;
      }
      final time = item.nextAttemptAt;
      if (time != null && (earliest == null || time.isBefore(earliest))) {
        earliest = time;
      }
    }
    return earliest;
  }

  @override
  Future<void> initialize(SessionInfo scope) => _write((next) {
    next
      ..session = scope
      ..paused = false
      ..pauseReason = null
      ..journalBootstrap = false
      ..bootstrapIncomplete = true;
  });

  @override
  Future<void> purgeAndPause(String reason) => _write((next) {
    next.documents.clear();
    next.outbox.clear();
    next
      ..cursor = null
      ..snapshotCursor = null
      ..snapshotCutoverSequence = null
      ..consistencyToken = null
      ..journalBootstrap = false
      ..paused = true
      ..pauseReason = reason;
  });

  @override
  Future<void> resumeFor(SessionInfo scope) => _write((next) {
    next.documents.clear();
    next.outbox.clear();
    next
      ..cursor = null
      ..snapshotCursor = null
      ..snapshotCutoverSequence = null
      ..consistencyToken = null
      ..journalBootstrap = false
      ..session = scope
      ..paused = false
      ..pauseReason = null
      ..bootstrapIncomplete = true;
  });

  @override
  Future<void> enqueue({
    required String operationId,
    required String documentId,
    required MutationKind kind,
    required Map<String, Object?>? data,
  }) {
    // Take the caller's JSON snapshot before this write waits behind another.
    final copiedData = data == null ? null : immutableJson(data);
    return _write((next) {
      if (next.outbox.containsKey(operationId)) {
        throw StateError('Duplicate pending operation: $operationId.');
      }
      if (next.nextSequence >= 9007199254740991) {
        throw StateError('IndexedDB outbox sequence exhausted.');
      }
      final previous = _orderedPending(
        next,
      ).where((item) => item.documentId == documentId).lastOrNull;
      next.outbox[operationId] = PendingMutation(
        sequence: next.nextSequence++,
        operationId: operationId,
        documentId: documentId,
        kind: kind,
        data: copiedData,
        state: MutationState.queued,
        attempts: 0,
        baseVersion: null,
        observedVersion: next.documents[documentId]?.version ?? 0,
        predecessorOperationId: previous?.operationId,
        nextAttemptAt: null,
      );
    });
  }

  @override
  Future<PendingMutation> prepare(PendingMutation mutation) => _write((next) {
    final current = _findPending(next, mutation.operationId);
    if (current.predecessorOperationId != null) {
      throw StateError(
        'Cannot prepare a mutation before its predecessor is acknowledged.',
      );
    }
    final prepared = current.baseVersion == null
        ? _copyMutation(current, baseVersion: current.observedVersion)
        : current;
    next.outbox[current.operationId] = prepared;
    return prepared;
  });

  @override
  Future<void> acknowledge(
    PendingMutation mutation,
    ServerDocument document,
    String? token,
  ) => _write((next) {
    if (document.id != mutation.documentId) {
      throw FormatException('Mutation reply has an unexpected document id.');
    }
    _upsert(next, document);
    _releaseSuccessors(next, mutation.operationId, document.version);
    next.outbox.remove(mutation.operationId);
    next.consistencyToken = token;
  });

  @override
  Future<void> defer(PendingMutation mutation, DateTime until, String code) =>
      _write((next) {
        final current = next.outbox[mutation.operationId];
        if (current == null) return;
        next.outbox[current.operationId] = _copyMutation(
          current,
          attempts: current.attempts + 1,
          nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(
            until.millisecondsSinceEpoch,
            isUtc: true,
          ),
          errorCode: code,
        );
      });

  @override
  Future<void> markConflict(
    PendingMutation mutation,
    ServerDocument? current,
  ) => _write((next) {
    if (current != null && current.id != mutation.documentId) {
      throw FormatException('Conflict reply has an unexpected document id.');
    }
    if (current == null) {
      next.documents.remove(mutation.documentId);
    } else {
      _upsert(next, current);
    }
    final pending = next.outbox[mutation.operationId];
    if (pending != null) {
      next.outbox[pending.operationId] = _copyMutation(
        pending,
        state: MutationState.conflict,
        errorCode: 'conflict',
        nextAttemptAt: null,
      );
    }
  });

  @override
  Future<void> markRejected(PendingMutation mutation, String code) =>
      _write((next) {
        final current = next.outbox[mutation.operationId];
        if (current != null) {
          next.outbox[current.operationId] = _copyMutation(
            current,
            state: MutationState.rejected,
            errorCode: code,
            nextAttemptAt: null,
          );
        }
      });

  @override
  Future<void> retryConflict(
    String operationId,
    String newOperationId, {
    Map<String, Object?>? replacementData,
  }) {
    final copiedData = replacementData == null
        ? null
        : immutableJson(replacementData);
    return _write((next) {
      final mutation = _findPending(next, operationId);
      if (mutation.state != MutationState.conflict) {
        throw StateError('Only a conflicted mutation can be retried.');
      }
      if (copiedData != null && mutation.kind != MutationKind.put) {
        throw ArgumentError(
          'A deletion conflict cannot have replacement data.',
        );
      }
      if (newOperationId != operationId &&
          next.outbox.containsKey(newOperationId)) {
        throw StateError('Duplicate pending operation: $newOperationId.');
      }
      next.outbox.remove(operationId);
      next.outbox[newOperationId] = _copyMutation(
        mutation,
        operationId: newOperationId,
        data: copiedData,
        baseVersion: null,
        observedVersion: next.documents[mutation.documentId]?.version ?? 0,
        predecessorOperationId: null,
        state: MutationState.queued,
        attempts: 0,
        nextAttemptAt: null,
        errorCode: null,
      );
      for (final item in next.outbox.values.toList()) {
        if (item.predecessorOperationId == operationId) {
          next.outbox[item.operationId] = _copyMutation(
            item,
            predecessorOperationId: newOperationId,
          );
        }
      }
    });
  }

  @override
  Future<void> discard(String operationId) => _write((next) {
    final mutation = _findPending(next, operationId);
    if (mutation.baseVersion != null &&
        mutation.state == MutationState.queued) {
      throw StateError(
        'An attempted write may have committed; retry it until its outcome is known.',
      );
    }
    _releaseSuccessors(next, operationId, mutation.observedVersion);
    next.outbox.remove(operationId);
  });

  @override
  Future<void> applyPage(SyncPage page, String? token) => _write((next) {
    if (page.cursor.isEmpty) throw FormatException('Empty sync cursor.');
    for (final document in page.changes) {
      _upsert(next, document);
    }
    next
      ..cursor = page.cursor
      ..consistencyToken = token;
    if (!page.hasMore) {
      next.bootstrapIncomplete = false;
      next.journalBootstrap = false;
    }
  });

  @override
  Future<void> applySnapshotPage(SnapshotPage page, String? token) => _write((
    next,
  ) {
    if (page.cursor.isEmpty ||
        page.syncCursor.isEmpty ||
        page.cutoverSequence < 0) {
      throw FormatException('Invalid snapshot cursor or cutover sequence.');
    }
    if (next.snapshotCutoverSequence != null &&
        next.snapshotCutoverSequence != page.cutoverSequence) {
      throw FormatException('Snapshot cutover changed between pages.');
    }
    for (final document in page.documents) {
      if (document.version > page.cutoverSequence) {
        throw FormatException('Snapshot document is newer than its cutover.');
      }
      _upsert(next, document);
    }
    next.consistencyToken = token;
    if (page.hasMore) {
      next
        ..snapshotCursor = page.cursor
        ..snapshotCutoverSequence = page.cutoverSequence
        ..bootstrapIncomplete = true;
    } else {
      next
        ..cursor = page.syncCursor
        ..snapshotCursor = null
        ..snapshotCutoverSequence = null
        ..journalBootstrap = false
        ..bootstrapIncomplete = false;
    }
  });

  @override
  Future<void> resetForResync({bool journalOnly = false}) => _write((next) {
    next.documents.clear();
    next
      ..cursor = null
      ..snapshotCursor = null
      ..snapshotCutoverSequence = null
      ..consistencyToken = null
      ..journalBootstrap = journalOnly
      ..bootstrapIncomplete = true;
  });

  Future<T> _write<T>(T Function(_CacheState) action) {
    if (_closing || _closed || _databaseLost) {
      return Future.error(StateError('IndexedDB cache is closed.'));
    }
    final operation = _writeTail.then((_) async {
      if (_databaseLost) throw StateError('IndexedDB connection was lost.');
      final next = _state.copy();
      final result = action(next);
      await _persistDiff(_state, next);
      // A request's success event is insufficient. Only transaction completion
      // publishes its metadata/documents/outbox as one committed read view.
      _state = next;
      return result;
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _persistDiff(
    _CacheState before,
    _CacheState after, {
    bool forceMetadata = false,
    bool runTestHook = true,
  }) async {
    final transaction = _database.transaction(
      _storeNames.map((name) => name.toJS).toList().toJS,
      'readwrite',
      web.IDBTransactionOptions(durability: 'strict'),
    );
    final completion = _transactionCompletion(transaction);
    try {
      if (transaction.durability != 'strict') {
        throw UnsupportedError(
          'IndexedDB strict transaction durability is required.',
        );
      }
      final metadataBefore = jsonEncode(before.metadataJson());
      final metadataAfter = jsonEncode(after.metadataJson());
      if (forceMetadata || metadataBefore != metadataAfter) {
        transaction
            .objectStore('metadata')
            .put(metadataAfter.toJS, 'state'.toJS);
      }
      _persistRecords(
        transaction.objectStore('documents'),
        before.documents,
        after.documents,
        (document) => document.toJson(),
      );
      _persistRecords(
        transaction.objectStore('outbox'),
        before.outbox,
        after.outbox,
        _mutationJson,
      );
      if (runTestHook) _transactionHookForTesting?.call(transaction);
    } catch (error, stack) {
      try {
        transaction.abort();
      } catch (_) {
        // The supplied test hook may already have aborted the transaction.
      }
      try {
        await completion;
      } catch (_) {}
      Error.throwWithStackTrace(error, stack);
    }
    await completion;
  }

  void _persistRecords<T>(
    web.IDBObjectStore store,
    Map<String, T> before,
    Map<String, T> after,
    Map<String, Object?> Function(T) encode,
  ) {
    if (after.isEmpty && before.isNotEmpty) {
      store.clear();
      return;
    }
    for (final key in before.keys) {
      if (!after.containsKey(key)) store.delete(key.toJS);
    }
    for (final entry in after.entries) {
      if (!identical(before[entry.key], entry.value)) {
        store.put(jsonEncode(encode(entry.value)).toJS, entry.key.toJS);
      }
    }
  }

  @override
  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closing = true;
    return _closeFuture = _finishClose();
  }

  Future<void> _finishClose() async {
    await _writeTail;
    _database.close();
    _closed = true;
    _releaseLock.complete(null);
    await _lockLifetime;
  }

  static Future<web.IDBDatabase> _openDatabase(String name) {
    final completer = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(name, 1);
    request.onupgradeneeded = ((web.Event _) {
      try {
        final database = request.result as web.IDBDatabase;
        for (final name in _storeNames) {
          database.createObjectStore(name);
        }
      } catch (error, stack) {
        request.transaction?.abort();
        if (!completer.isCompleted) completer.completeError(error, stack);
      }
    }).toJS;
    request.onsuccess = ((web.Event _) {
      final database = request.result as web.IDBDatabase;
      if (completer.isCompleted) {
        database.close();
      } else {
        completer.complete(database);
      }
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError(
            'Could not open IndexedDB: ${request.error?.name ?? 'UnknownError'}.',
          ),
        );
      }
    }).toJS;
    request.onblocked = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('IndexedDB open is blocked by another connection.'),
        );
      }
    }).toJS;
    return completer.future;
  }

  static Future<_CacheState> _readState(web.IDBDatabase database) async {
    final transaction = database.transaction(
      _storeNames.map((name) => name.toJS).toList().toJS,
      'readonly',
    );
    final results = await Future.wait<Object?>([
      _requestResult(transaction.objectStore('metadata').get('state'.toJS)),
      _requestResult(transaction.objectStore('documents').getAll()),
      _requestResult(transaction.objectStore('outbox').getAll()),
      _transactionCompletion(transaction),
    ]);
    final state = results[0] == null
        ? _CacheState()
        : _CacheState.fromMetadata(_jsonString(results[0] as JSAny));
    if (results[0] == null &&
        ((results[1] as JSArray<JSAny?>).toDart.isNotEmpty ||
            (results[2] as JSArray<JSAny?>).toDart.isNotEmpty)) {
      throw FormatException('IndexedDB cache records have no scope metadata.');
    }
    for (final value in (results[1] as JSArray<JSAny?>).toDart) {
      final document = ServerDocument.fromJson(_jsonString(value!));
      if (state.documents.containsKey(document.id)) {
        throw FormatException('Duplicate cached document.');
      }
      state.documents[document.id] = document;
    }
    final sequences = <int>{};
    for (final value in (results[2] as JSArray<JSAny?>).toDart) {
      final mutation = _mutationFromJson(_jsonString(value!));
      if (state.outbox.containsKey(mutation.operationId) ||
          !sequences.add(mutation.sequence) ||
          mutation.sequence < 1 ||
          mutation.sequence >= state.nextSequence ||
          mutation.observedVersion < 0 ||
          (mutation.baseVersion != null && mutation.baseVersion! < 0)) {
        throw FormatException('Invalid cached outbox record.');
      }
      state.outbox[mutation.operationId] = mutation;
    }
    for (final mutation in state.outbox.values) {
      if (mutation.predecessorOperationId == null) continue;
      final previous = state.outbox[mutation.predecessorOperationId];
      if (previous == null ||
          previous.documentId != mutation.documentId ||
          previous.sequence >= mutation.sequence ||
          mutation.baseVersion != null) {
        throw FormatException('Invalid cached outbox dependency.');
      }
    }
    return state;
  }

  static Future<JSAny?> _requestResult(web.IDBRequest request) {
    final completer = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) => completer.complete(
      request.result,
    )).toJS;
    request.onerror = ((web.Event _) => completer.completeError(
      StateError(
        'IndexedDB read failed: ${request.error?.name ?? 'UnknownError'}.',
      ),
    )).toJS;
    return completer.future;
  }

  static Future<void> _transactionCompletion(web.IDBTransaction transaction) {
    final completer = Completer<void>();
    transaction.oncomplete = ((web.Event _) => completer.complete()).toJS;
    transaction.onabort = ((web.Event _) => completer.completeError(
      StateError(
        'IndexedDB transaction aborted: ${transaction.error?.name ?? 'AbortError'}.',
      ),
    )).toJS;
    // Let request errors abort their transaction; never preventDefault here.
    return completer.future;
  }

  static Map<String, Object?> _jsonString(JSAny value) =>
      (jsonDecode((value as JSString).toDart) as Map).cast<String, Object?>();

  static List<PendingMutation> _orderedPending(_CacheState state) =>
      state.outbox.values.toList()
        ..sort((a, b) => a.sequence.compareTo(b.sequence));

  static PendingMutation _findPending(_CacheState state, String operationId) =>
      state.outbox[operationId] ??
      (throw StateError('Unknown pending operation: $operationId.'));

  static void _upsert(_CacheState state, ServerDocument document) {
    if (document.version > (state.documents[document.id]?.version ?? 0)) {
      state.documents[document.id] = document;
    }
  }

  static void _releaseSuccessors(
    _CacheState state,
    String operationId,
    int version,
  ) {
    for (final mutation in state.outbox.values.toList()) {
      if (mutation.predecessorOperationId == operationId &&
          mutation.baseVersion == null) {
        state.outbox[mutation.operationId] = _copyMutation(
          mutation,
          observedVersion: version,
          predecessorOperationId: null,
        );
      }
    }
  }

  static Map<String, Object?> _mutationJson(PendingMutation mutation) => {
    'sequence': mutation.sequence,
    'operationId': mutation.operationId,
    'documentId': mutation.documentId,
    'kind': mutation.kind.name,
    'data': mutation.data,
    'state': mutation.state.name,
    'attempts': mutation.attempts,
    'baseVersion': mutation.baseVersion,
    'observedVersion': mutation.observedVersion,
    'predecessorOperationId': mutation.predecessorOperationId,
    'nextAttemptMs': mutation.nextAttemptAt?.millisecondsSinceEpoch,
    'errorCode': mutation.errorCode,
  };

  static PendingMutation _mutationFromJson(Map<String, Object?> json) =>
      PendingMutation(
        sequence: json['sequence'] as int,
        operationId: json['operationId'] as String,
        documentId: json['documentId'] as String,
        kind: MutationKind.values.byName(json['kind'] as String),
        data: (json['data'] as Map?)?.cast<String, Object?>(),
        state: MutationState.values.byName(json['state'] as String),
        attempts: json['attempts'] as int,
        baseVersion: json['baseVersion'] as int?,
        observedVersion: json['observedVersion'] as int,
        predecessorOperationId: json['predecessorOperationId'] as String?,
        nextAttemptAt: json['nextAttemptMs'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                json['nextAttemptMs'] as int,
                isUtc: true,
              ),
        errorCode: json['errorCode'] as String?,
      );

  static const _unchanged = Object();
  static PendingMutation _copyMutation(
    PendingMutation mutation, {
    String? operationId,
    Map<String, Object?>? data,
    MutationState? state,
    int? attempts,
    Object? baseVersion = _unchanged,
    int? observedVersion,
    Object? predecessorOperationId = _unchanged,
    Object? nextAttemptAt = _unchanged,
    Object? errorCode = _unchanged,
  }) => PendingMutation(
    sequence: mutation.sequence,
    operationId: operationId ?? mutation.operationId,
    documentId: mutation.documentId,
    kind: mutation.kind,
    data: data ?? mutation.data,
    state: state ?? mutation.state,
    attempts: attempts ?? mutation.attempts,
    baseVersion: identical(baseVersion, _unchanged)
        ? mutation.baseVersion
        : baseVersion as int?,
    observedVersion: observedVersion ?? mutation.observedVersion,
    predecessorOperationId: identical(predecessorOperationId, _unchanged)
        ? mutation.predecessorOperationId
        : predecessorOperationId as String?,
    nextAttemptAt: identical(nextAttemptAt, _unchanged)
        ? mutation.nextAttemptAt
        : nextAttemptAt as DateTime?,
    errorCode: identical(errorCode, _unchanged)
        ? mutation.errorCode
        : errorCode as String?,
  );
}

class _CacheState {
  _CacheState();
  factory _CacheState.fromMetadata(Map<String, Object?> json) {
    if (json['formatVersion'] != 1) {
      throw StateError('Unsupported IndexedDB cache format.');
    }
    final state = _CacheState()
      ..session = json['session'] == null
          ? null
          : SessionInfo.fromJson(
              (json['session'] as Map).cast<String, Object?>(),
            )
      ..paused = json['paused'] as bool
      ..pauseReason = json['pauseReason'] as String?
      ..cursor = json['cursor'] as String?
      ..snapshotCursor = json['snapshotCursor'] as String?
      ..snapshotCutoverSequence = json['snapshotCutoverSequence'] as int?
      ..consistencyToken = json['consistencyToken'] as String?
      ..bootstrapIncomplete = json['bootstrapIncomplete'] as bool
      ..journalBootstrap = json['journalBootstrap'] as bool? ?? false
      ..nextSequence = json['nextSequence'] as int;
    if (state.nextSequence < 1 || state.nextSequence > 9007199254740991) {
      throw FormatException('Invalid IndexedDB outbox sequence.');
    }
    if ((state.snapshotCursor == null) !=
            (state.snapshotCutoverSequence == null) ||
        (state.snapshotCutoverSequence != null &&
            state.snapshotCutoverSequence! < 0)) {
      throw FormatException('Invalid IndexedDB snapshot progress.');
    }
    return state;
  }

  SessionInfo? session;
  bool paused = false;
  String? pauseReason;
  String? cursor;
  String? snapshotCursor;
  int? snapshotCutoverSequence;
  String? consistencyToken;
  bool bootstrapIncomplete = false;
  bool journalBootstrap = false;
  int nextSequence = 1;
  final Map<String, ServerDocument> documents = {};
  final Map<String, PendingMutation> outbox = {};

  Map<String, Object?> metadataJson() => {
    'formatVersion': 1,
    'session': session?.toJson(),
    'paused': paused,
    'pauseReason': pauseReason,
    'cursor': cursor,
    'snapshotCursor': snapshotCursor,
    'snapshotCutoverSequence': snapshotCutoverSequence,
    'consistencyToken': consistencyToken,
    'bootstrapIncomplete': bootstrapIncomplete,
    'journalBootstrap': journalBootstrap,
    'nextSequence': nextSequence,
  };

  _CacheState copy() => _CacheState()
    ..session = session
    ..paused = paused
    ..pauseReason = pauseReason
    ..cursor = cursor
    ..snapshotCursor = snapshotCursor
    ..snapshotCutoverSequence = snapshotCutoverSequence
    ..consistencyToken = consistencyToken
    ..bootstrapIncomplete = bootstrapIncomplete
    ..journalBootstrap = journalBootstrap
    ..nextSequence = nextSequence
    ..documents.addAll(documents)
    ..outbox.addAll(outbox);
}
