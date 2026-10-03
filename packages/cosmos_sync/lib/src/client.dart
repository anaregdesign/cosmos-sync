import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'models.dart';
import 'sqlite_cache.dart';

/// Offline local document API with an explicitly triggered durable sync engine.
///
/// Reads and writes are local and synchronous. Network operations are serialized,
/// while new local edits may continue during an in-flight request. Use a single
/// instance per file, preferably in a dedicated isolate for larger workloads.
class CosmosSyncClient {
  CosmosSyncClient._({
    required this.cache,
    required this.transport,
    required SessionInfo session,
    DateTime Function()? clock,
  }) : _session = session,
       _clock = clock ?? (() => DateTime.now().toUtc()) {
    final saved = cache.session;
    if (saved == null) {
      cache.initialize(session);
    } else if (!saved.sameScope(session)) {
      cache.purgeAndPause('scope_changed');
    }
    _restoreConsistencyToken();
  }

  /// Reopens an existing cache offline, or verifies `/session` for a new cache.
  ///
  /// [session] can initialize an offline cache for a previously verified scope.
  /// It must come from this BFF, not from decoded/unvalidated JWT claims. Every
  /// network operation still verifies the current server session before use.
  static Future<CosmosSyncClient> open({
    required String path,
    required SyncTransport transport,
    SessionInfo? session,
    DateTime Function()? clock,
  }) async {
    final cache = SqliteCache(path);
    try {
      final scope = session ?? cache.session ?? await transport.sessionInfo();
      return CosmosSyncClient._(
        cache: cache,
        transport: transport,
        session: scope,
        clock: clock,
      );
    } catch (_) {
      cache.close();
      rethrow;
    }
  }

  final SqliteCache cache;
  final SyncTransport transport;
  SessionInfo _session;
  final DateTime Function() _clock;
  final Random _random = Random.secure();
  final _changes = StreamController<void>.broadcast(sync: true);
  final _statuses = StreamController<SyncStatus>.broadcast(sync: true);
  Future<void> _networkTail = Future.value();
  Timer? _pollTimer;
  bool _pollBusy = false;
  DateTime? _pollNotBefore;
  int _pollFailures = 0;
  bool _closed = false;
  bool _closing = false;
  bool _signingOut = false;
  Future<void>? _signOutFuture;
  Object? _lastError;

  SessionInfo get session => _session;
  SyncStatus get status => SyncStatus(
    paused: cache.paused,
    reason: cache.pauseReason,
    lastError: _lastError,
  );
  List<PendingMutation> get pending => cache.pending;

  DocumentSnapshot? get(String id) {
    _assertOpen();
    return cache.get(id);
  }

  List<DocumentSnapshot> list({bool includeDeleted = false}) {
    _assertOpen();
    return cache.list(includeDeleted: includeDeleted);
  }

  /// Emits immediately, then after durable local writes, ACKs and sync pages.
  Stream<DocumentSnapshot?> watch(String id) => Stream.multi((controller) {
    _assertOpen();
    final subscription = _changes.stream.listen(
      (_) => controller.add(cache.get(id)),
      onDone: controller.close,
    );
    controller.add(cache.get(id));
    controller.onCancel = subscription.cancel;
  });

  Stream<List<DocumentSnapshot>> watchAll({bool includeDeleted = false}) =>
      Stream.multi((controller) {
        _assertOpen();
        final subscription = _changes.stream.listen(
          (_) => controller.add(cache.list(includeDeleted: includeDeleted)),
          onDone: controller.close,
        );
        controller.add(cache.list(includeDeleted: includeDeleted));
        controller.onCancel = subscription.cancel;
      });

  Stream<SyncStatus> get statuses => Stream.multi((controller) {
    _assertOpen();
    final subscription = _statuses.stream.listen(
      controller.add,
      onDone: controller.close,
    );
    controller.add(status);
    controller.onCancel = subscription.cancel;
  });

  /// Replaces a local document; returned replay ID identifies its pending write.
  String put(String id, Map<String, Object?> data) {
    _assertUsable();
    _validateId(id);
    final copied = _validateData(data);
    final operationId = _uuid();
    cache.enqueue(
      operationId: operationId,
      documentId: id,
      kind: MutationKind.put,
      data: copied,
    );
    _notify();
    return operationId;
  }

  /// Creates a local tombstone, retained by the server when acknowledged.
  String delete(String id) {
    _assertUsable();
    _validateId(id);
    final operationId = _uuid();
    cache.enqueue(
      operationId: operationId,
      documentId: id,
      kind: MutationKind.delete,
      data: null,
    );
    _notify();
    return operationId;
  }

  /// Retries a known conflict as a new mutation, optionally with merged data.
  /// Later queued edits to that document retain their existing queue positions.
  String retryConflict(String operationId, {Map<String, Object?>? data}) {
    _assertUsable();
    final newId = _uuid();
    cache.retryConflict(
      operationId,
      newId,
      replacementData: data == null ? null : _validateData(data),
    );
    _notify();
    return newId;
  }

  /// Discards an unattempted/rejected/conflicted write. Unknown in-flight outcomes
  /// must be retried with their original ID to discover whether they committed.
  void discard(String operationId) {
    _assertUsable();
    cache.discard(operationId);
    _notify();
  }

  /// Sends ready writes serially. Retryable failures retain the exact request
  /// and persist a retry deadline; call again, or enable polling, after it passes.
  Future<FlushResult> flush({int maxOperations = 100}) => _serialize(() async {
    _assertUsable();
    if (maxOperations < 1) {
      throw ArgumentError.value(maxOperations, 'maxOperations');
    }
    await _verifySession();
    if (cache.bootstrapIncomplete) {
      await _syncPages(pageSize: 100, maxPages: 100);
      if (cache.bootstrapIncomplete) {
        throw StateError(
          'Initial journal replay is incomplete. Call sync() again before flushing.',
        );
      }
    }
    var acknowledged = 0;
    var restarted = false;
    for (var index = 0; index < maxOperations; index++) {
      if (_signingOut) break;
      final ready = cache.nextReady(_clock());
      if (ready == null) break;
      final mutation = cache.prepare(ready);
      try {
        final document = await transport.mutate(mutation.request);
        if (document.version <= mutation.baseVersion!) {
          throw const TransportException(
            code: 'invalid_response',
            message: 'Mutation response did not advance the requested version.',
          );
        }
        cache.acknowledge(mutation, document, _consistencyToken);
        acknowledged++;
        _lastError = null;
        _notify();
      } on TransportException catch (error) {
        _lastError = error;
        if (error.authorizationFailure) {
          _purgeAndPause(error.code);
          rethrow;
        }
        if (error.statusCode == 409 && error.code == 'conflict') {
          cache.markConflict(mutation, error.current);
          _notify();
          continue;
        }
        if (error.statusCode == 410 && error.code == 'resync_required') {
          if (restarted) rethrow;
          cache.resetForResync();
          _setConsistencyToken(null);
          restarted = true;
          _notify();
          await _syncPages(pageSize: 100, maxPages: 100);
          if (cache.bootstrapIncomplete) {
            throw StateError(
              'Journal replay is incomplete. Call sync() before flushing.',
            );
          }
          index--;
          continue;
        }
        if (error.retryable) {
          final exponent = min(mutation.attempts, 8);
          final backoff = Duration(
            milliseconds: 500 * (1 << exponent) + _random.nextInt(250),
          );
          final delay = error.retryAfter == null || error.retryAfter! < backoff
              ? backoff
              : error.retryAfter!;
          cache.defer(mutation, _clock().add(delay), error.code);
          _notify();
          break;
        }
        cache.markRejected(mutation, error.code);
        _notify();
      }
    }
    return FlushResult(
      acknowledged: acknowledged,
      remaining: cache.pendingCount,
      retryAt: cache.nextRetryAt,
    );
  });

  /// Applies each page and its resume cursor in one SQLite transaction.
  /// No cross-partition or wall-clock ordering is implied by this cursor.
  Future<int> sync({int pageSize = 100, int maxPages = 100}) =>
      _serialize(() async {
        _assertUsable();
        if (pageSize < 1 || pageSize > 100 || maxPages < 1) {
          throw ArgumentError(
            'pageSize must be 1..100; maxPages must be positive.',
          );
        }
        await _verifySession();
        return _syncPages(pageSize: pageSize, maxPages: maxPages);
      });

  Future<int> _syncPages({required int pageSize, required int maxPages}) async {
    var count = 0;
    var restarted = false;
    for (var index = 0; index < maxPages; index++) {
      if (_signingOut) break;
      try {
        final page = await transport.sync(
          cursor: cache.cursor,
          limit: pageSize,
        );
        cache.applyPage(page, _consistencyToken);
        count += page.changes.length;
        _lastError = null;
        _notify();
        if (!page.hasMore) break;
      } on TransportException catch (error) {
        _lastError = error;
        if (error.authorizationFailure) {
          _purgeAndPause(error.code);
          rethrow;
        }
        if (error.statusCode == 410 &&
            error.code == 'resync_required' &&
            !restarted) {
          cache.resetForResync();
          _setConsistencyToken(null);
          restarted = true;
          _notify();
          // Recovery itself does not consume the page budget.
          index--;
          continue;
        }
        _notifyStatus();
        rethrow;
      }
    }
    return count;
  }

  /// Explicitly adopts the currently verified identity after purge/pause.
  /// Any data still associated with the prior session is conservatively cleared.
  Future<void> resume() => _serialize(() async {
    _assertOpen();
    try {
      final verified = await transport.sessionInfo();
      cache.resumeFor(verified);
      _session = verified;
      _lastError = null;
      _setConsistencyToken(null);
      _notify();
    } on TransportException catch (error) {
      if (error.authorizationFailure) _purgeAndPause(error.code);
      rethrow;
    }
  });

  /// Stops new operations immediately, then purges after any in-flight request.
  /// A late ACK can finish before the purge, never repopulate data afterward.
  Future<void> signOut() {
    _assertOpen();
    if (_signOutFuture != null) return _signOutFuture!;
    _signingOut = true;
    stopPolling();
    final next = _networkTail.then((_) => _purgeAndPause('signed_out'));
    _networkTail = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _lastError = error;
        if (!_closed) _notifyStatus();
      },
    );
    _signOutFuture = next.whenComplete(() {
      _signingOut = false;
      _signOutFuture = null;
    });
    return _signOutFuture!;
  }

  /// Optional polling hints. Each cycle resumes sync then flushes due writes.
  /// Network errors are reported through [statuses], never swallowed silently.
  void startPolling({Duration interval = const Duration(seconds: 15)}) {
    _assertUsable();
    if (interval < const Duration(seconds: 1)) {
      throw ArgumentError('Polling interval must be at least one second.');
    }
    stopPolling();
    _pollTimer = Timer.periodic(interval, (_) async {
      if (_pollBusy ||
          _closing ||
          cache.paused ||
          (_pollNotBefore != null && _clock().isBefore(_pollNotBefore!))) {
        return;
      }
      _pollBusy = true;
      try {
        await sync();
        final result = await flush();
        _pollNotBefore = result.retryAt;
        _pollFailures = 0;
      } catch (error) {
        _lastError = error;
        if (error is TransportException && error.retryable) {
          final backoff = Duration(seconds: 1 << min(_pollFailures++, 8));
          var delay = backoff > interval ? backoff : interval;
          if (error.retryAfter != null && error.retryAfter! > delay) {
            delay = error.retryAfter!;
          }
          _pollNotBefore = _clock().add(delay);
        }
        if (!_closed) _notifyStatus();
      } finally {
        _pollBusy = false;
      }
    });
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Waits for an in-flight operation before closing storage and transport.
  Future<void> close() async {
    if (_closed || _closing) return;
    _closing = true;
    stopPolling();
    await _networkTail;
    _closed = true;
    await _changes.close();
    await _statuses.close();
    cache.close();
    transport.close();
  }

  Future<void> _verifySession() async {
    try {
      final actual = await transport.sessionInfo();
      if (!_session.sameScope(actual)) {
        _purgeAndPause('scope_changed');
        throw StateError(
          'Authorization scope changed. Cache purged; call resume() explicitly.',
        );
      }
      _restoreConsistencyToken();
    } on TransportException catch (error) {
      if (error.authorizationFailure) _purgeAndPause(error.code);
      rethrow;
    }
  }

  void _purgeAndPause(String reason) {
    cache.purgeAndPause(reason);
    _setConsistencyToken(null);
    stopPolling();
    _notify();
  }

  String? get _consistencyToken {
    final value = transport;
    return value is ConsistencyTokenTransport
        ? (value as ConsistencyTokenTransport).consistencyToken
        : null;
  }

  void _setConsistencyToken(String? token) {
    final value = transport;
    if (value is ConsistencyTokenTransport) {
      (value as ConsistencyTokenTransport).consistencyToken = token;
    }
  }

  void _restoreConsistencyToken() =>
      _setConsistencyToken(cache.consistencyToken);

  Future<T> _serialize<T>(Future<T> Function() action) {
    _assertOpen();
    if (_signingOut) throw StateError('Sign-out is in progress.');
    final next = _networkTail.then((_) => action());
    _networkTail = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _lastError = error;
        if (!_closed) _notifyStatus();
      },
    );
    return next;
  }

  void _notify() {
    if (!_closed) _changes.add(null);
    _notifyStatus();
  }

  void _notifyStatus() {
    if (!_closed) _statuses.add(status);
  }

  void _assertOpen() {
    if (_closed || _closing) throw StateError('Client is closed.');
  }

  void _assertUsable() {
    _assertOpen();
    if (_signingOut) throw StateError('Sign-out is in progress.');
    if (cache.paused) {
      throw StateError(
        'Synchronization is paused: ${cache.pauseReason}. Call resume() after signing in.',
      );
    }
  }

  void _validateId(String id) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id)) {
      throw ArgumentError.value(
        id,
        'id',
        'Use 1..128 ASCII letters, numbers, dot, underscore or hyphen; start with a letter/number.',
      );
    }
  }

  Map<String, Object?> _validateData(Map<String, Object?> data) {
    final copied = immutableJson(data);
    // Reserve room for operation ID, document ID, version and JSON field names
    // Keep a conservative local margin below the BFF's 256 KiB data limit
    // and 512 KiB total request-body bound.
    if (utf8.encode(jsonEncode(copied)).length > 255 * 1024) {
      throw ArgumentError('Document exceeds the 255 KiB local data limit.');
    }
    return copied;
  }

  String _uuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
