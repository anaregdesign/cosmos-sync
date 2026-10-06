import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'models.dart';
import 'cache_store.dart';
import 'cache_platform_stub.dart'
    if (dart.library.io) 'cache_platform_native.dart'
    if (dart.library.js_interop) 'cache_platform_web.dart'
    as platform;
import 'query.dart';

/// Offline local document API with an explicitly triggered durable sync engine.
///
/// Reads are local and synchronous; writes complete after durable persistence.
/// Network operations are serialized,
/// while new local edits may continue during an in-flight request. Use a single
/// instance per file, preferably in a dedicated isolate for larger workloads.
class CosmosSyncClient {
  CosmosSyncClient._({
    required this.cache,
    required this.transport,
    required this._session,
    DateTime Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().toUtc()) {
    _restoreConsistencyToken();
  }

  /// Reopens an existing cache offline, or verifies `/session` for a new cache.
  ///
  /// [session] can initialize an offline cache for a previously verified scope.
  /// It must come from this BFF, not from decoded/unvalidated JWT claims. Every
  /// network operation still verifies the current server session before use.
  static Future<CosmosSyncClient> open({
    String? path,
    CacheStore? cache,
    required SyncTransport transport,
    SessionInfo? session,
    DateTime Function()? clock,
  }) async {
    if ((path == null) == (cache == null)) {
      throw ArgumentError('Provide exactly one of path or an opened cache.');
    }
    final store = cache ?? await platform.openCache(path!);
    try {
      final scope = session ?? store.session ?? await transport.sessionInfo();
      final saved = store.session;
      final selection = transport;
      if (selection is ScopeSelectionTransport &&
          !(selection as ScopeSelectionTransport).matchesSelectedScope(scope)) {
        await store.purgeAndPause('scope_changed');
      } else if (saved == null) {
        await store.initialize(scope);
      } else if (!saved.sameScope(scope)) {
        await store.purgeAndPause('scope_changed');
      }
      return CosmosSyncClient._(
        cache: store,
        transport: transport,
        session: scope,
        clock: clock,
      );
    } catch (_) {
      await store.close();
      rethrow;
    }
  }

  final CacheStore cache;
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
  StreamSubscription<ChangeHint>? _hintSubscription;
  Timer? _hintReconnectTimer;
  int _hintGeneration = 0;
  int _hintFailures = 0;
  String? _hintResumeId;
  bool _hintSyncBusy = false;
  bool _hintSyncAgain = false;
  bool _closed = false;
  bool _closing = false;
  bool _signingOut = false;
  bool _transitioning = false;
  String? _revocationReason;
  Future<void>? _signOutFuture;
  Object? _lastError;
  final _pendingWaiters = <_PendingWritesWaiter>[];

  SessionInfo get session => _session;
  SyncStatus get status => SyncStatus(
    paused: cache.paused || _transitioning || _revocationReason != null,
    reason: _revocationReason ?? cache.pauseReason,
    lastError: _lastError,
  );
  List<PendingMutation> get pending =>
      _revocationReason == null ? cache.pending : const [];

  /// Waits for true server ACKs for the currently committed pending write set.
  /// Later writes do not extend this waiter. Conflicts, discard, auth changes
  /// and close fail it; local persistence alone never reports server success.
  Future<void> waitForPendingWrites() {
    _assertUsable();
    final ids = cache.pending.map((mutation) => mutation.operationId).toSet();
    if (ids.isEmpty) return Future<void>.value();
    final waiter = _PendingWritesWaiter(ids);
    _pendingWaiters.add(waiter);
    _checkPendingWaiters();
    return waiter.completer.future.whenComplete(
      () => _pendingWaiters.remove(waiter),
    );
  }

  DocumentSnapshot? get(String id) {
    _assertOpen();
    return _revocationReason == null ? cache.get(id) : null;
  }

  List<DocumentSnapshot> list({bool includeDeleted = false}) {
    _assertOpen();
    return _revocationReason == null
        ? cache.list(includeDeleted: includeDeleted)
        : const [];
  }

  /// Evaluates a deterministic query over this client's committed local view.
  /// Cache completeness is tied to a durable cursor, never to current connectivity.
  LocalQuerySnapshot query(LocalQuery query) {
    _assertOpen();
    return query.evaluate(
      list(includeDeleted: true),
      metadata: QueryCacheMetadata(
        bootstrapComplete: !cache.bootstrapIncomplete,
        cursor: cache.cursor,
        paused: cache.paused || _transitioning || _signingOut,
        scopeKey: jsonEncode([
          _session.scopeId,
          _session.principalId,
          _session.permissionVersion,
          _session.scopeMode.name,
          if (_session.identityGeneration != null) ...[
            _session.identityGeneration,
            _session.identityId,
          ],
        ]),
      ),
    );
  }

  Stream<LocalQuerySnapshot> watchQuery(LocalQuery localQuery) =>
      Stream.multi((controller) {
        _assertOpen();
        StreamSubscription<void>? subscription;
        var invalidated = false;
        void emit() {
          if (invalidated) return;
          try {
            controller.add(query(localQuery));
          } catch (error, stack) {
            invalidated = true;
            controller.addError(error, stack);
            unawaited(subscription?.cancel());
            controller.close();
          }
        }

        subscription = _changes.stream.listen(
          (_) => emit(),
          onDone: controller.close,
        );
        controller.onCancel = subscription.cancel;
        emit();
      });

  /// Emits immediately, then after durable local writes, ACKs and sync pages.
  Stream<DocumentSnapshot?> watch(String id) => Stream.multi((controller) {
    _assertOpen();
    final subscription = _changes.stream.listen(
      (_) => controller.add(get(id)),
      onDone: controller.close,
    );
    controller.add(get(id));
    controller.onCancel = subscription.cancel;
  });

  Stream<List<DocumentSnapshot>> watchAll({bool includeDeleted = false}) =>
      Stream.multi((controller) {
        _assertOpen();
        final subscription = _changes.stream.listen(
          (_) => controller.add(list(includeDeleted: includeDeleted)),
          onDone: controller.close,
        );
        controller.add(list(includeDeleted: includeDeleted));
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
  Future<String> put(String id, Map<String, Object?> data) {
    _assertUsable();
    _validateId(id);
    final copied = _validateData(data);
    final operationId = _uuid();
    return Future<void>.value(
      cache.enqueue(
        operationId: operationId,
        documentId: id,
        kind: MutationKind.put,
        data: copied,
      ),
    ).then((_) {
      _notify();
      return operationId;
    });
  }

  /// Creates a local tombstone, retained by the server when acknowledged.
  Future<String> delete(String id) {
    _assertUsable();
    _validateId(id);
    final operationId = _uuid();
    return Future<void>.value(
      cache.enqueue(
        operationId: operationId,
        documentId: id,
        kind: MutationKind.delete,
        data: null,
      ),
    ).then((_) {
      _notify();
      return operationId;
    });
  }

  /// Retries a known conflict as a new mutation, optionally with merged data.
  /// Later queued edits to that document retain their existing queue positions.
  Future<String> retryConflict(
    String operationId, {
    Map<String, Object?>? data,
  }) {
    _assertUsable();
    final newId = _uuid();
    return Future<void>.value(
      cache.retryConflict(
        operationId,
        newId,
        replacementData: data == null ? null : _validateData(data),
      ),
    ).then((_) {
      _notify();
      return newId;
    });
  }

  /// Discards an unattempted/rejected/conflicted write. Unknown in-flight outcomes
  /// must be retried with their original ID to discover whether they committed.
  Future<void> discard(String operationId) {
    _assertUsable();
    return Future<void>.value(
      cache.discard(operationId),
    ).then((_) => _notify());
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
      if (_signingOut || _transitioning) break;
      final ready = cache.nextReady(_clock());
      if (ready == null) break;
      final mutation = await cache.prepare(ready);
      try {
        final document = await transport.mutate(mutation.request);
        if (document.version <= mutation.baseVersion!) {
          throw const TransportException(
            code: 'invalid_response',
            message: 'Mutation response did not advance the requested version.',
          );
        }
        await cache.acknowledge(mutation, document, _consistencyToken);
        for (final waiter in _pendingWaiters) {
          waiter.remaining.remove(mutation.operationId);
        }
        acknowledged++;
        _lastError = null;
        _notify();
      } on TransportException catch (error) {
        _lastError = error;
        if (error.authorizationFailure) {
          await _purgeAndPause(error.code);
          rethrow;
        }
        if (error.statusCode == 409 && error.code == 'conflict') {
          await cache.markConflict(mutation, error.current);
          _notify();
          continue;
        }
        if (error.statusCode == 410 && error.code == 'resync_required') {
          if (restarted) rethrow;
          await cache.resetForResync();
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
          await cache.defer(mutation, _clock().add(delay), error.code);
          _notify();
          break;
        }
        await cache.markRejected(mutation, error.code);
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
    var snapshotFallback = cache.journalBootstrap;
    for (var index = 0; index < maxPages; index++) {
      if (_signingOut || _transitioning) break;
      try {
        final value = transport;
        if (cache.bootstrapIncomplete &&
            value is SnapshotTransport &&
            !snapshotFallback) {
          final page = await (value as SnapshotTransport).snapshot(
            cursor: cache.snapshotCursor,
            limit: pageSize,
          );
          await cache.applySnapshotPage(page, _consistencyToken);
          count += page.documents.length;
          _lastError = null;
          _notify();
          continue;
        }
        final page = await transport.sync(
          cursor: cache.cursor,
          limit: pageSize,
        );
        await cache.applyPage(page, _consistencyToken);
        count += page.changes.length;
        _lastError = null;
        _notify();
        if (!page.hasMore) break;
      } on TransportException catch (error) {
        _lastError = error;
        if (error.authorizationFailure) {
          await _purgeAndPause(error.code);
          rethrow;
        }
        if (error.statusCode == 413 &&
            error.code == 'snapshot_limit_exceeded' &&
            !snapshotFallback) {
          await cache.resetForResync(journalOnly: true);
          _setConsistencyToken(null);
          snapshotFallback = true;
          _notify();
          index--;
          continue;
        }
        if (error.statusCode == 410 &&
            error.code == 'resync_required' &&
            !restarted) {
          await cache.resetForResync();
          _setConsistencyToken(null);
          restarted = true;
          snapshotFallback = false;
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
    _transitioning = true;
    stopWatching();
    try {
      final verified = await transport.sessionInfo();
      await cache.resumeFor(verified);
      _session = verified;
      _lastError = null;
      _setConsistencyToken(null);
      _notify();
    } on TransportException catch (error) {
      if (error.authorizationFailure) await _purgeAndPause(error.code);
      rethrow;
    } finally {
      _transitioning = false;
    }
  });

  /// Stops new operations immediately, then purges after any in-flight request.
  /// A late ACK can finish before the purge, never repopulate data afterward.
  Future<void> signOut() {
    _assertOpen();
    if (_signOutFuture != null) return _signOutFuture!;
    _signingOut = true;
    _failPendingWaiters('signed_out');
    stopWatching();
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

  /// Listens for non-authoritative change hints, with durable-cursor polling as
  /// fallback. Hint resume IDs are kept only for this lifecycle and never become
  /// cache cursors. A transport without SSE capability simply uses polling.
  void startWatching({Duration pollingInterval = const Duration(seconds: 15)}) {
    _assertUsable();
    stopWatching();
    startPolling(interval: pollingInterval);
    if (transport is ChangeHintTransport) {
      unawaited(_connectHintStream(_hintGeneration));
    }
  }

  void stopWatching() {
    _hintGeneration++;
    _hintReconnectTimer?.cancel();
    _hintReconnectTimer = null;
    final subscription = _hintSubscription;
    _hintSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    _hintResumeId = null;
    _hintFailures = 0;
    _hintSyncAgain = false;
    stopPolling();
  }

  Future<void> _connectHintStream(int generation) async {
    if (_closing || _closed || generation != _hintGeneration || cache.paused) {
      return;
    }
    try {
      await _serialize(() async {
        _assertUsable();
        await _verifySession();
      });
      if (_closing || generation != _hintGeneration || cache.paused) return;
      final capability = transport as ChangeHintTransport;
      _hintSubscription = capability
          .watchChanges(lastEventId: _hintResumeId, cursor: cache.cursor)
          .listen(
            (hint) {
              if (generation != _hintGeneration) return;
              _hintResumeId = hint.resumeId;
              _hintFailures = 0;
              _requestHintSync(generation);
            },
            onError: (Object error, StackTrace stack) {
              _handleHintError(error, generation);
            },
            onDone: () => _scheduleHintReconnect(generation),
            cancelOnError: true,
          );
    } catch (error) {
      _handleHintError(error, generation);
    }
  }

  void _handleHintError(Object error, int generation) {
    if (_closed || _closing || generation != _hintGeneration) return;
    _lastError = error;
    if (error is TransportException && error.authorizationFailure) {
      // Learn revocation immediately; purge waits for the in-flight response so
      // an ACK cannot subsequently repopulate storage. Visible client data is
      // hidden throughout that wait, and no later request may be started.
      _transitioning = true;
      _revocationReason = error.code;
      _failPendingWaiters('authorization_changed');
      stopWatching();
      _notify();
      final purge = _networkTail.then((_) => _purgeAndPause(error.code));
      _networkTail = purge.then<void>(
        (_) {},
        onError: (Object failure, StackTrace stack) {
          _lastError = failure;
          if (!_closed) _notifyStatus();
        },
      );
      return;
    }
    _notifyStatus();
    if (error is TransportException && error.statusCode == 410) {
      _hintResumeId = null;
      _requestHintSync(generation);
    }
    _scheduleHintReconnect(
      generation,
      retryAfter: error is TransportException ? error.retryAfter : null,
    );
  }

  void _scheduleHintReconnect(int generation, {Duration? retryAfter}) {
    if (_closed ||
        _closing ||
        generation != _hintGeneration ||
        cache.paused ||
        _hintReconnectTimer != null) {
      return;
    }
    var delay = Duration(seconds: 1 << min(_hintFailures++, 8));
    if (retryAfter != null && retryAfter > delay) delay = retryAfter;
    _hintReconnectTimer = Timer(delay, () {
      _hintReconnectTimer = null;
      unawaited(_connectHintStream(generation));
    });
  }

  void _requestHintSync(int generation) {
    if (_hintSyncBusy) {
      _hintSyncAgain = true;
      return;
    }
    _hintSyncBusy = true;
    unawaited(() async {
      try {
        do {
          _hintSyncAgain = false;
          if (_closed ||
              _closing ||
              generation != _hintGeneration ||
              cache.paused) {
            break;
          }
          await sync();
          if (_closed ||
              _closing ||
              generation != _hintGeneration ||
              cache.paused) {
            break;
          }
          await flush();
        } while (_hintSyncAgain);
      } catch (error) {
        _lastError = error;
        if (!_closed) _notifyStatus();
      } finally {
        _hintSyncBusy = false;
        // A restarted watcher may have received a new hint while the previous
        // generation was still finishing its request. Transfer that wakeup.
        if (_hintSyncAgain &&
            generation != _hintGeneration &&
            _pollTimer != null &&
            !_closed &&
            !_closing &&
            !cache.paused) {
          _requestHintSync(_hintGeneration);
        }
      }
    }());
  }

  /// Waits for an in-flight operation before closing storage and transport.
  Future<void> close() async {
    if (_closed || _closing) return;
    _closing = true;
    _failPendingWaiters('closed');
    stopWatching();
    await _networkTail;
    _closed = true;
    await _changes.close();
    await _statuses.close();
    await cache.close();
    transport.close();
  }

  Future<void> _verifySession() async {
    try {
      final actual = await transport.sessionInfo();
      if (!_session.sameScope(actual)) {
        await _purgeAndPause('scope_changed');
        throw StateError(
          'Authorization scope changed. Cache purged; call resume() explicitly.',
        );
      }
      _restoreConsistencyToken();
    } on TransportException catch (error) {
      if (error.authorizationFailure) await _purgeAndPause(error.code);
      rethrow;
    }
  }

  Future<void> _purgeAndPause(String reason) async {
    _transitioning = true;
    _revocationReason = reason;
    _failPendingWaiters('authorization_changed');
    stopWatching();
    _notify();
    try {
      await cache.purgeAndPause(reason);
      _setConsistencyToken(null);
      _revocationReason = null;
      _notify();
    } finally {
      _transitioning = false;
    }
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
    if (_transitioning) {
      throw StateError('Authorization transition is in progress.');
    }
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
    _checkPendingWaiters();
    if (!_closed) _changes.add(null);
    _notifyStatus();
  }

  void _notifyStatus() {
    if (!_closed) _statuses.add(status);
  }

  void _checkPendingWaiters() {
    if (_pendingWaiters.isEmpty || _closed) return;
    final pendingById = {
      for (final mutation in cache.pending) mutation.operationId: mutation,
    };
    for (final waiter in _pendingWaiters) {
      if (waiter.completer.isCompleted) continue;
      if (waiter.remaining.isEmpty) {
        waiter.completer.complete();
        continue;
      }
      for (final id in waiter.remaining) {
        final mutation = pendingById[id];
        if (mutation == null || mutation.state != MutationState.queued) {
          waiter.completer.completeError(
            PendingWritesException(
              reason: mutation?.state.name ?? 'discarded',
              operationId: id,
            ),
          );
          break;
        }
      }
    }
  }

  void _failPendingWaiters(String reason) {
    for (final waiter in _pendingWaiters) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(PendingWritesException(reason: reason));
      }
    }
  }

  void _assertOpen() {
    if (_closed || _closing) throw StateError('Client is closed.');
  }

  void _assertUsable() {
    _assertOpen();
    if (_signingOut) throw StateError('Sign-out is in progress.');
    if (_transitioning) {
      throw StateError('Authorization transition is in progress.');
    }
    if (cache.paused || _revocationReason != null) {
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

class _PendingWritesWaiter {
  _PendingWritesWaiter(this.remaining);
  final Set<String> remaining;
  final completer = Completer<void>();
}
