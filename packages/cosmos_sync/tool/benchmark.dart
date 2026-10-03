// Native-only, non-cloud evidence collection. No HTTP, OIDC, Cosmos or RU work.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cosmos_sync/cosmos_sync.dart';

const _session = SessionInfo(
  scopeId: 'benchmark-scope',
  principalId: 'benchmark-principal',
  permissionVersion: '1',
);

Future<void> main(List<String> arguments) async {
  final count = _option(arguments, 'documents', 1000, 1, 10000);
  final payloadBytes = _option(arguments, 'payload-bytes', 256, 1, 4096);
  final repetitions = _option(arguments, 'query-repetitions', 10, 1, 1000);
  final allowed = {'documents', 'payload-bytes', 'query-repetitions'};
  if (arguments.any(
    (argument) =>
        !argument.startsWith('--') ||
        !argument.contains('=') ||
        !allowed.contains(argument.substring(2).split('=').first),
  )) {
    throw ArgumentError(
      'Use --documents=1..10000 --payload-bytes=1..4096 '
      '--query-repetitions=1..1000.',
    );
  }
  final directory = Directory.systemTemp.createTempSync(
    'cosmos-sync-benchmark-',
  );
  final path = '${directory.path}/cache.sqlite';
  final server = _ServerFixture();
  final phases = <Map<String, Object?>>[];
  final resources = <CosmosSyncClient>[];
  final payload = List.filled(payloadBytes, 'x').join();
  final sampleData = <String, Object?>{'group': 3, 'score': 3, 'text': payload};
  final payloadJsonBytes = utf8.encode(jsonEncode(sampleData)).length;

  Future<T> measure<T>(
    String name,
    int operations,
    Future<T> Function() action,
  ) async {
    stderr.writeln('benchmark: $name ($operations operations)');
    final rssBefore = ProcessInfo.currentRss;
    final watch = Stopwatch()..start();
    final value = await action();
    watch.stop();
    final seconds = watch.elapsedMicroseconds / 1000000;
    phases.add({
      'phase': name,
      'operations': operations,
      'milliseconds': watch.elapsedMicroseconds / 1000,
      'operationsPerSecond': seconds > 0 ? operations / seconds : null,
      'rssBeforeBytes': rssBefore,
      'rssAfterBytes': ProcessInfo.currentRss,
      'maxRssBytes': ProcessInfo.maxRss,
      'sqliteFiles': _disk(directory),
    });
    return value;
  }

  try {
    var client = await measure('open_empty', 1, () async {
      final value = await CosmosSyncClient.open(
        path: path,
        transport: _Transport(server),
      );
      resources.add(value);
      return value;
    });
    await measure('durable_enqueue', count, () async {
      for (var index = 0; index < count; index++) {
        await client.put(_id(index), {
          'group': index % 10,
          'score': index,
          'text': payload,
        });
      }
    });
    _check(client.cache.pendingCount == count, 'enqueue count');
    final firstOperation = client.pending.first.operationId;
    await measure('close_pending', 1, client.close);
    client = await measure('reopen_pending', 1, () async {
      final value = await CosmosSyncClient.open(
        path: path,
        transport: _Transport(server),
      );
      resources.add(value);
      return value;
    });
    _check(client.cache.pendingCount == count, 'restart outbox count');
    _check(
      client.pending.first.operationId == firstOperation,
      'restart replay ID',
    );
    _check(
      client.get(_id(count - 1))?.hasPendingWrites == true,
      'restart overlay',
    );

    final flushed = await measure(
      'durable_flush_in_process',
      count,
      () => client.flush(maxOperations: count),
    );
    _check(
      flushed.acknowledged == count && flushed.remaining == 0,
      'flush ACKs',
    );
    _check(server.journal.length == count, 'server journal count');
    final synced = await measure(
      'replay_after_acks',
      count,
      () => client.sync(maxPages: (count / 100).ceil() + 1),
    );
    _check(
      synced == count && client.cache.cursor == 'seq:$count',
      'ACK replay cursor',
    );

    final query = LocalQuery(
      filters: [QueryFilter.eq(QueryField.named('group'), 3)],
      orderBy: [QueryOrder(QueryField.named('score'), descending: true)],
      limit: 100,
    );
    final expected = min(100, count < 4 ? 0 : 1 + (count - 4) ~/ 10);
    // One explicit warmup query is outside measured query repetitions.
    _check(client.query(query).documents.length == expected, 'query warmup');
    await measure('local_scan_sort_query', repetitions, () async {
      for (var index = 0; index < repetitions; index++) {
        final snapshot = client.query(query);
        _check(snapshot.documents.length == expected, 'query count');
        _check(
          !snapshot.isIncomplete && !snapshot.hasPendingWrites,
          'query coverage',
        );
      }
    });
    await measure('close_confirmed', 1, client.close);

    final replayPath = '${directory.path}/replay.sqlite';
    final replay = await CosmosSyncClient.open(
      path: replayPath,
      transport: _Transport(server),
    );
    resources.add(replay);
    final initialCount = await measure(
      'initial_journal_replay',
      count,
      () => replay.sync(maxPages: (count / 100).ceil() + 1),
    );
    _check(
      initialCount == count && replay.cache.cursor == 'seq:$count',
      'initial replay',
    );
    _check(replay.cache.pendingCount == 0, 'replay outbox');
    await replay.close();

    final snapshotPath = '${directory.path}/snapshot.sqlite';
    final initial = await CosmosSyncClient.open(
      path: snapshotPath,
      transport: _SnapshotTransport(server),
    );
    resources.add(initial);
    final snapshotCount = await measure(
      'initial_snapshot_install',
      count,
      () => initial.sync(maxPages: (count / 100).ceil() + 1),
    );
    _check(
      snapshotCount == count && initial.cache.cursor == 'seq:$count',
      'snapshot cursor',
    );
    _check(!initial.cache.bootstrapIncomplete, 'snapshot completion');
    _check(
      initial.get(_id(count - 1))?.version == count,
      'snapshot final version',
    );
    await initial.close();

    stdout.writeln(
      jsonEncode({
        'benchmark': 'native-sqlite-offline-v1',
        'timestampUtc': DateTime.now().toUtc().toIso8601String(),
        'environment': {
          'dart': Platform.version,
          'os': Platform.operatingSystem,
          'osVersion': Platform.operatingSystemVersion,
          'logicalProcessors': Platform.numberOfProcessors,
        },
        'fixture': {
          'documents': count,
          'outboxPeak': count,
          'pageSize': 100,
          'textBytes': payloadBytes,
          'sampleDocumentJsonBytes': payloadJsonBytes,
          'queryRepetitions': repetitions,
          'queryWarmup': 1,
          'queryResultLimit': 100,
          'transport': 'in-process; no HTTP, OIDC, Cosmos, network or RU',
          'snapshot': 'fixed fixture cutover; excludes server-side fold cost',
          'memory': 'RSS, not managed heap; includes in-process server fixture',
        },
        'phases': phases,
        'closedSqliteFiles': _disk(directory),
        'checks':
            'accepted writes, replay ID, restart overlay, ACKs, journal count, '
            'cursor, query coverage/count and snapshot count/version passed',
      }),
    );
  } finally {
    for (final client in resources) {
      await client.close();
    }
    directory.deleteSync(recursive: true);
  }
}

int _option(
  List<String> arguments,
  String name,
  int fallback,
  int low,
  int high,
) {
  final values = arguments.where((argument) => argument.startsWith('--$name='));
  if (values.length > 1) throw ArgumentError('Duplicate --$name.');
  final value = values.isEmpty
      ? fallback
      : int.tryParse(values.single.split('=').last);
  if (value == null || value < low || value > high) {
    throw ArgumentError('--$name must be $low..$high.');
  }
  return value;
}

String _id(int index) => 'document-${index.toString().padLeft(6, '0')}';

void _check(bool condition, String name) {
  if (!condition) {
    throw StateError('Benchmark correctness check failed: $name.');
  }
}

Map<String, Object?> _disk(Directory directory) {
  final sizes = <String, int>{};
  for (final file in directory.listSync().whereType<File>()) {
    if (file.path.endsWith('.sqlite') ||
        file.path.endsWith('.sqlite-wal') ||
        file.path.endsWith('.sqlite-shm')) {
      sizes[file.uri.pathSegments.last] = file.lengthSync();
    }
  }
  return {
    'bytesByFile': sizes,
    'totalBytes': sizes.values.fold<int>(0, (sum, size) => sum + size),
  };
}

class _ServerFixture {
  final documents = <String, ServerDocument>{};
  final journal = <ServerDocument>[];
  final receipts = <String, (String, ServerDocument)>{};
}

class _Transport implements SyncTransport {
  _Transport(this.server);
  final _ServerFixture server;

  @override
  Future<SessionInfo> sessionInfo() async => _session;

  @override
  Future<ServerDocument> mutate(MutationRequest request) async {
    final body = jsonEncode(request.toJson());
    final receipt = server.receipts[request.operationId];
    if (receipt != null) {
      _check(receipt.$1 == body, 'immutable retry body');
      return receipt.$2;
    }
    final current = server.documents[request.documentId];
    if ((current?.version ?? 0) != request.baseVersion) {
      throw TransportException(
        code: 'conflict',
        message: 'In-process benchmark version conflict.',
        statusCode: 409,
        current: current,
      );
    }
    final document = ServerDocument(
      id: request.documentId,
      data: request.data,
      version: server.journal.length + 1,
      deleted: request.kind == MutationKind.delete,
    );
    server.documents[document.id] = document;
    server.journal.add(document);
    server.receipts[request.operationId] = (body, document);
    return document;
  }

  @override
  Future<SyncPage> sync({String? cursor, int limit = 100}) async {
    final after = cursor == null ? 0 : int.parse(cursor.substring(4));
    final end = min(after + limit, server.journal.length);
    return SyncPage(
      changes: server.journal.sublist(after, end),
      cursor: 'seq:$end',
      hasMore: end < server.journal.length,
    );
  }

  @override
  void close() {}
}

class _SnapshotTransport extends _Transport implements SnapshotTransport {
  _SnapshotTransport(super.server)
    : cutover = server.journal.length,
      snapshotDocuments = server.documents.values.toList()
        ..sort((a, b) => a.id.compareTo(b.id));

  final int cutover;
  final List<ServerDocument> snapshotDocuments;

  @override
  Future<SnapshotPage> snapshot({String? cursor, int limit = 100}) async {
    final offset = cursor == null ? 0 : int.parse(cursor.split(':').last);
    final end = min(offset + limit, snapshotDocuments.length);
    return SnapshotPage(
      documents: snapshotDocuments.sublist(offset, end),
      cursor: 'snapshot:$cutover:$end',
      syncCursor: 'seq:$cutover',
      cutoverSequence: cutover,
      hasMore: end < snapshotDocuments.length,
    );
  }
}
