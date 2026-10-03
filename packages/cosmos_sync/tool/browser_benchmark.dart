// Real browser storage timing only: no transport, OIDC, Cosmos, network or RU.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:cosmos_sync/src/indexed_db_cache.dart';
import 'package:web/web.dart' as web;

const _session = SessionInfo(
  scopeId: 'benchmark-scope',
  principalId: 'benchmark-principal',
  permissionVersion: '1',
);

Future<void> main() async {
  final result = <String, Object?>{};
  late IndexedDbCache cache;
  IndexedDbCache? cacheForCleanup;
  final name = 'cosmos-sync-benchmark-${DateTime.now().microsecondsSinceEpoch}';
  try {
    final count = int.tryParse(Uri.base.queryParameters['documents'] ?? '1000');
    if (count == null || count < 1 || count > 1000) {
      throw ArgumentError('documents must be 1..1000');
    }
    const repetitions = 10;
    final payload = List.filled(256, 'x').join();
    final phases = <Map<String, Object?>>[];
    Future<T> measure<T>(
      String phase,
      int operations,
      Future<T> Function() work,
    ) async {
      final watch = Stopwatch()..start();
      final value = await work();
      watch.stop();
      phases.add({
        'phase': phase,
        'operations': operations,
        'milliseconds': watch.elapsedMicroseconds / 1000,
      });
      return value;
    }

    cache = await measure('open_empty', 1, () => IndexedDbCache.open(name));
    cacheForCleanup = cache;
    await cache.initialize(_session);
    final beforeStorage = await _storage();
    await measure('durable_enqueue', count, () async {
      for (var index = 0; index < count; index++) {
        await cache.enqueue(
          operationId: 'operation-$index',
          documentId: _id(index),
          kind: MutationKind.put,
          data: {'group': index % 10, 'score': index, 'text': payload},
        );
      }
    });
    _check(cache.pendingCount == count, 'durable enqueue count');
    final expectedPending = cache.pending.map(_pendingJson).toList();
    _check(
      cache.get(_id(count - 1))?.hasPendingWrites == true,
      'pending overlay',
    );
    final pendingStorage = await _storage();
    await measure('close_pending', 1, cache.close);
    cache = await measure('reopen_pending', 1, () => IndexedDbCache.open(name));
    cacheForCleanup = cache;
    _check(cache.pendingCount == count, 'reopen count');
    _check(
      jsonEncode(cache.pending.map(_pendingJson).toList()) ==
          jsonEncode(expectedPending),
      'exact durable outbox',
    );
    _check(cache.session?.sameScope(_session) == true, 'reopen session');
    final pending = cache.pending;
    final documents = <ServerDocument>[];
    await measure('prepare_and_commit_fixture_acks', count, () async {
      for (var index = 0; index < pending.length; index++) {
        final prepared = await cache.prepare(pending[index]);
        _check(prepared.baseVersion == 0, 'original absent precondition');
        final document = ServerDocument(
          id: prepared.documentId,
          data: prepared.data,
          version: index + 1,
          deleted: false,
        );
        await cache.acknowledge(prepared, document, 'fixture-consistency');
        documents.add(document);
      }
    });
    _check(
      cache.pendingCount == 0 && cache.list().length == count,
      'confirmed views',
    );
    await measure('commit_journal_pages', count, () async {
      for (var offset = 0; offset < count; offset += 100) {
        final end = min(offset + 100, count);
        await cache.applyPage(
          SyncPage(
            changes: documents.sublist(offset, end),
            cursor: 'sequence:$end',
            hasMore: end < count,
          ),
          'fixture-consistency',
        );
      }
    });
    _check(
      cache.cursor == 'sequence:$count' && !cache.bootstrapIncomplete,
      'committed coverage',
    );
    final confirmedStorage = await _storage();
    final query = LocalQuery(
      filters: [QueryFilter.eq(QueryField.named('group'), 3)],
      orderBy: [QueryOrder(QueryField.named('score'), descending: true)],
      limit: 100,
    );
    final expected = min(100, (count + 6) ~/ 10);
    LocalQuerySnapshot evaluate() => query.evaluate(
      cache.list(includeDeleted: true),
      metadata: QueryCacheMetadata(
        bootstrapComplete: !cache.bootstrapIncomplete,
        cursor: cache.cursor,
        scopeKey: 'benchmark-scope-and-principal',
      ),
    );
    _check(evaluate().documents.length == expected, 'query warmup');
    final samples = <double>[];
    for (var index = 0; index < repetitions; index++) {
      final watch = Stopwatch()..start();
      final snapshot = evaluate();
      watch.stop();
      _check(
        snapshot.documents.length == expected &&
            !snapshot.isIncomplete &&
            !snapshot.hasPendingWrites,
        'query result and metadata',
      );
      samples.add(watch.elapsedMicroseconds / 1000);
    }
    final sorted = [...samples]..sort();
    await measure('close_confirmed', 1, cache.close);
    cache = await measure(
      'reopen_confirmed',
      1,
      () => IndexedDbCache.open(name),
    );
    cacheForCleanup = cache;
    _check(
      cache.list().length == count && cache.pendingCount == 0,
      'confirmed restart',
    );
    _check(
      cache.get(_id(count - 1))?.version == count &&
          cache.cursor == 'sequence:$count' &&
          !cache.bootstrapIncomplete,
      'restart version and cursor',
    );
    result.addAll({
      'status': 'PASS',
      'benchmark': 'chromium-indexeddb-offline-v1',
      'timestampUtc': DateTime.now().toUtc().toIso8601String(),
      'environment': {
        'userAgent': web.window.navigator.userAgent,
        'secureContext': web.window.isSecureContext,
      },
      'fixture': {
        'documents': count,
        'outboxPeak': count,
        'textBytes': 256,
        'sampleJsonBytes': utf8
            .encode(jsonEncode({'group': 3, 'score': 3, 'text': payload}))
            .length,
        'queryRepetitions': repetitions,
        'queryWarmup': 1,
        'queryLimit': 100,
        'acks': 'direct fixture cache commits, no server transport',
      },
      'phases': phases,
      'queryMilliseconds': {
        'samples': samples,
        'median': (sorted[4] + sorted[5]) / 2,
        'min': sorted.first,
        'max': sorted.last,
      },
      'originStorageEstimate': {
        'before': beforeStorage,
        'pending': pendingStorage,
        'confirmed': confirmedStorage,
        'meaning':
            'approximate entire origin usage/quota, not isolated IndexedDB file size',
      },
      'checks':
          'exact reopened outbox, original base, ACK count, views, versions, cursor, query rows and coverage passed',
    });
  } catch (error) {
    result.addAll({'status': 'FAIL', 'error': '$error'});
  } finally {
    try {
      await cacheForCleanup?.close();
      await _deleteDatabase(name);
    } catch (error) {
      result.addAll({'status': 'FAIL', 'cleanupError': '$error'});
    }
    await web.window
        .fetch(
          '/result'.toJS,
          web.RequestInit(method: 'POST', body: jsonEncode(result).toJS),
        )
        .toDart;
  }
}

String _id(int index) => 'document-${index.toString().padLeft(6, '0')}';
Map<String, Object?> _pendingJson(PendingMutation mutation) => {
  'sequence': mutation.sequence,
  'operationId': mutation.operationId,
  'documentId': mutation.documentId,
  'data': mutation.data,
  'state': mutation.state.name,
  'observedVersion': mutation.observedVersion,
  'baseVersion': mutation.baseVersion,
  'attempts': mutation.attempts,
};
void _check(bool condition, String description) {
  if (!condition) throw StateError('Benchmark check failed: $description');
}

Future<Map<String, Object?>> _storage() async {
  try {
    final estimate = await web.window.navigator.storage.estimate().toDart;
    return {'usageBytes': estimate.usage, 'quotaBytes': estimate.quota};
  } catch (error) {
    return {'unavailable': '$error'};
  }
}

Future<void> _deleteDatabase(String name) {
  final finished = Completer<void>();
  final request = web.window.indexedDB.deleteDatabase(name);
  request.onsuccess = ((web.Event _) => finished.complete()).toJS;
  request.onerror = ((web.Event _) => finished.completeError(
    StateError('Database deletion failed.'),
  )).toJS;
  request.onblocked = ((web.Event _) => finished.completeError(
    StateError('Database deletion blocked.'),
  )).toJS;
  return finished.future;
}
