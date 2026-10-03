import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'models.dart';

/// Native, synchronous SQLite storage. Use one client/writer per file.
///
/// Pages and resume cursors commit in the same transaction. A process-level
/// guard within one isolate and an advisory OS lock catch common duplicate opens.
/// Apps must enforce one isolate owner per file; POSIX locks are process-scoped.
/// The file is unencrypted; the app must choose an app-private directory.
class SqliteCache {
  SqliteCache(String path) {
    var opened = false;
    if (path == ':memory:') {
      _path = path;
    } else {
      final file = File(path).absolute;
      file.parent.createSync(recursive: true);
      _path = file.existsSync()
          ? file.resolveSymbolicLinksSync()
          : '${file.parent.resolveSymbolicLinksSync()}${Platform.pathSeparator}${file.uri.pathSegments.last}';
    }
    if (_path != ':memory:' && !_openPaths.add(_path)) {
      throw StateError('A Cosmos Sync cache is already open at $_path.');
    }
    try {
      if (_path != ':memory:') {
        File(_path).parent.createSync(recursive: true);
        _lock = File('$_path.cosmos-sync.lock').openSync(mode: FileMode.append);
        _lock!.lockSync(FileLock.exclusive);
      }
      _db = sqlite3.open(_path);
      opened = true;
      _db.execute('PRAGMA journal_mode=WAL');
      _db.execute('PRAGMA synchronous=FULL');
      _db.execute('PRAGMA busy_timeout=5000');
      final version =
          _db.select('PRAGMA user_version').first.values.first as int;
      if (version < 0 || version > 2) {
        throw StateError('Unsupported cache schema version: $version.');
      }
      _db.execute('''
        CREATE TABLE IF NOT EXISTS metadata (
          key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL
        )
      ''');
      _db.execute('''
        CREATE TABLE IF NOT EXISTS documents (
          id TEXT PRIMARY KEY NOT NULL,
          data TEXT,
          version INTEGER NOT NULL CHECK (version > 0),
          deleted INTEGER NOT NULL CHECK (deleted IN (0, 1))
        )
      ''');
      _db.execute('''
        CREATE TABLE IF NOT EXISTS outbox (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          operation_id TEXT NOT NULL UNIQUE,
          document_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          data TEXT,
          base_version INTEGER,
          observed_version INTEGER NOT NULL DEFAULT 0,
          predecessor_id TEXT,
          state TEXT NOT NULL DEFAULT 'queued',
          attempts INTEGER NOT NULL DEFAULT 0,
          next_attempt_ms INTEGER,
          error_code TEXT
        )
      ''');
      _db.execute('''
        CREATE INDEX IF NOT EXISTS outbox_document_sequence
        ON outbox(document_id, sequence)
      ''');
      if (version == 1) {
        _transaction(() {
          _db.execute(
            'ALTER TABLE outbox ADD COLUMN observed_version INTEGER NOT NULL DEFAULT 0',
          );
          _db.execute('ALTER TABLE outbox ADD COLUMN predecessor_id TEXT');
          // Unprepared old preview writes have no trustworthy observed base.
          // Conservatively use absence (0) so they conflict rather than rebase.
          _db.execute(
            'UPDATE outbox SET observed_version=coalesce(base_version, 0)',
          );
          _db.execute('''
            UPDATE outbox SET predecessor_id=(
              SELECT previous.operation_id FROM outbox previous
              WHERE previous.document_id=outbox.document_id
                AND previous.sequence < outbox.sequence
              ORDER BY previous.sequence DESC LIMIT 1
            ) WHERE base_version IS NULL
          ''');
          _db.execute('PRAGMA user_version=2');
        });
      } else {
        _db.execute('PRAGMA user_version=2');
      }
    } catch (_) {
      if (opened) _db.close();
      _lock?.closeSync();
      _openPaths.remove(_path);
      rethrow;
    }
  }

  static final Set<String> _openPaths = {};
  late final String _path;
  late final Database _db;
  RandomAccessFile? _lock;
  bool _closed = false;

  SessionInfo? get session {
    final value = _metadata('session');
    return value == null
        ? null
        : SessionInfo.fromJson((jsonDecode(value) as Map).cast());
  }

  bool get paused => _metadata('paused') == 'true';
  String? get pauseReason => _metadata('pause_reason');
  String? get cursor => _metadata('cursor');
  String? get consistencyToken => _metadata('consistency_token');
  bool get bootstrapIncomplete => _metadata('bootstrap_incomplete') == 'true';

  /// Binds an empty cache to a verified or explicitly provided offline scope.
  void initialize(SessionInfo scope) {
    _transaction(() {
      _setMetadata('session', jsonEncode(scope.toJson()));
      _setMetadata('paused', 'false');
      _setMetadata('pause_reason', null);
      _setMetadata('bootstrap_incomplete', 'true');
    });
  }

  /// Conservatively removes readable data, pending writes and cursors.
  void purgeAndPause(String reason) {
    _transaction(() {
      _db.execute('DELETE FROM documents');
      _db.execute('DELETE FROM outbox');
      _setMetadata('cursor', null);
      _setMetadata('consistency_token', null);
      _setMetadata('paused', 'true');
      _setMetadata('pause_reason', reason);
    });
  }

  /// Explicitly adopts a newly verified scope after a purge/pause.
  void resumeFor(SessionInfo scope) {
    _transaction(() {
      _db.execute('DELETE FROM documents');
      _db.execute('DELETE FROM outbox');
      _setMetadata('cursor', null);
      _setMetadata('consistency_token', null);
      _setMetadata('session', jsonEncode(scope.toJson()));
      _setMetadata('paused', 'false');
      _setMetadata('pause_reason', null);
      _setMetadata('bootstrap_incomplete', 'true');
    });
  }

  List<PendingMutation> get pending => _db
      .select('SELECT * FROM outbox ORDER BY sequence')
      .map(_pendingFromRow)
      .toList(growable: false);

  int get pendingCount =>
      _db.select('SELECT count(*) AS count FROM outbox').first['count'] as int;

  DocumentSnapshot? get(String id) {
    final base = _db.select('SELECT * FROM documents WHERE id = ?', [id]);
    final overlays = _db.select(
      'SELECT * FROM outbox WHERE document_id = ? ORDER BY sequence DESC',
      [id],
    );
    if (base.isEmpty && overlays.isEmpty) return null;
    final latest = overlays.isEmpty ? null : _pendingFromRow(overlays.first);
    final deleted = latest != null
        ? latest.kind == MutationKind.delete
        : base.first['deleted'] == 1;
    return DocumentSnapshot(
      id: id,
      data: latest != null ? latest.data : _decodeData(base.first['data']),
      version: base.isEmpty ? 0 : base.first['version'] as int,
      deleted: deleted,
      hasPendingWrites: latest != null,
      hasConflict: overlays.any((row) => row['state'] == 'conflict'),
    );
  }

  List<DocumentSnapshot> list({bool includeDeleted = false}) {
    final ids = _db.select('''
      SELECT id FROM documents UNION SELECT document_id AS id FROM outbox
      ORDER BY id
    ''');
    return ids
        .map((row) => get(row['id'] as String)!)
        .where((document) => includeDeleted || !document.deleted)
        .toList(growable: false);
  }

  void enqueue({
    required String operationId,
    required String documentId,
    required MutationKind kind,
    required Map<String, Object?>? data,
  }) {
    _transaction(() {
      final previous = _db.select(
        'SELECT operation_id FROM outbox WHERE document_id = ? ORDER BY sequence DESC LIMIT 1',
        [documentId],
      );
      final confirmed = _db.select(
        'SELECT version FROM documents WHERE id = ?',
        [documentId],
      );
      _db.execute(
        '''
      INSERT INTO outbox(operation_id, document_id, kind, data, observed_version, predecessor_id)
      VALUES (?, ?, ?, ?, ?, ?)
    ''',
        [
          operationId,
          documentId,
          kind.name,
          data == null ? null : jsonEncode(data),
          confirmed.isEmpty ? 0 : confirmed.first['version'] as int,
          previous.isEmpty ? null : previous.first['operation_id'] as String,
        ],
      );
    });
  }

  /// Returns only a document's first queued write, never following a conflict.
  PendingMutation? nextReady(DateTime now) {
    final rows = _db.select(
      '''
      SELECT current.* FROM outbox current
      WHERE current.state = 'queued'
        AND (current.next_attempt_ms IS NULL OR current.next_attempt_ms <= ?)
        AND NOT EXISTS (
          SELECT 1 FROM outbox earlier
          WHERE earlier.document_id = current.document_id
            AND earlier.sequence < current.sequence
        )
      ORDER BY current.sequence LIMIT 1
    ''',
      [now.millisecondsSinceEpoch],
    );
    return rows.isEmpty ? null : _pendingFromRow(rows.first);
  }

  DateTime? get nextRetryAt {
    final rows = _db.select('''
      SELECT min(current.next_attempt_ms) AS next FROM outbox current
      WHERE current.state = 'queued'
        AND current.next_attempt_ms IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM outbox earlier
          WHERE earlier.document_id = current.document_id
            AND earlier.sequence < current.sequence
        )
    ''');
    final next = rows.first['next'] as int?;
    return next == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(next, isUtc: true);
  }

  /// Locks a request's exact baseVersion before any network transmission.
  PendingMutation prepare(PendingMutation mutation) => _transaction(() {
    mutation = _findPending(mutation.operationId);
    if (mutation.predecessorOperationId != null) {
      throw StateError(
        'Cannot prepare a mutation before its predecessor is acknowledged.',
      );
    }
    if (mutation.baseVersion == null) {
      _db.execute(
        'UPDATE outbox SET base_version = ? WHERE operation_id = ? AND base_version IS NULL',
        [mutation.observedVersion, mutation.operationId],
      );
    }
    return _findPending(mutation.operationId);
  });

  void acknowledge(
    PendingMutation mutation,
    ServerDocument document,
    String? token,
  ) {
    if (document.id != mutation.documentId) {
      throw FormatException('Mutation reply has an unexpected document id.');
    }
    _transaction(() {
      _upsert(document);
      // Bind successors to this ACK, never to a newer pulled server base.
      _db.execute(
        'UPDATE outbox SET observed_version = ?, predecessor_id = NULL WHERE predecessor_id = ? AND base_version IS NULL',
        [document.version, mutation.operationId],
      );
      _db.execute('DELETE FROM outbox WHERE operation_id = ?', [
        mutation.operationId,
      ]);
      _setMetadata('consistency_token', token);
    });
  }

  void defer(PendingMutation mutation, DateTime until, String code) {
    _db.execute(
      '''
      UPDATE outbox SET attempts = attempts + 1, next_attempt_ms = ?, error_code = ?
      WHERE operation_id = ?
    ''',
      [until.millisecondsSinceEpoch, code, mutation.operationId],
    );
  }

  void markConflict(PendingMutation mutation, ServerDocument? current) {
    if (current != null && current.id != mutation.documentId) {
      throw FormatException('Conflict reply has an unexpected document id.');
    }
    _transaction(() {
      if (current == null) {
        _db.execute('DELETE FROM documents WHERE id = ?', [
          mutation.documentId,
        ]);
      } else {
        _upsert(current);
      }
      _db.execute(
        '''
        UPDATE outbox SET state = 'conflict', error_code = 'conflict',
          next_attempt_ms = NULL WHERE operation_id = ?
      ''',
        [mutation.operationId],
      );
    });
  }

  void markRejected(PendingMutation mutation, String code) {
    _db.execute(
      "UPDATE outbox SET state = 'rejected', error_code = ?, next_attempt_ms = NULL WHERE operation_id = ?",
      [code, mutation.operationId],
    );
  }

  /// Keeps its queue position but assigns a fresh replay identity and base.
  void retryConflict(
    String operationId,
    String newOperationId, {
    Map<String, Object?>? replacementData,
  }) {
    final mutation = _findPending(operationId);
    if (mutation.state != MutationState.conflict) {
      throw StateError('Only a conflicted mutation can be retried.');
    }
    if (replacementData != null && mutation.kind != MutationKind.put) {
      throw ArgumentError('A deletion conflict cannot have replacement data.');
    }
    _transaction(() {
      final confirmed = _db.select(
        'SELECT version FROM documents WHERE id = ?',
        [mutation.documentId],
      );
      _db.execute(
        '''
      UPDATE outbox SET operation_id = ?, data = ?, base_version = NULL,
        observed_version = ?, predecessor_id = NULL,
        state = 'queued', attempts = 0, next_attempt_ms = NULL, error_code = NULL
      WHERE operation_id = ?
    ''',
        [
          newOperationId,
          mutation.kind == MutationKind.delete
              ? null
              : jsonEncode(replacementData ?? mutation.data),
          confirmed.isEmpty ? 0 : confirmed.first['version'] as int,
          operationId,
        ],
      );
      _db.execute(
        'UPDATE outbox SET predecessor_id = ? WHERE predecessor_id = ?',
        [newOperationId, operationId],
      );
    });
  }

  void discard(String operationId) {
    final mutation = _findPending(operationId);
    if (mutation.baseVersion != null &&
        mutation.state == MutationState.queued) {
      throw StateError(
        'An attempted write may have committed; retry it until its outcome is known.',
      );
    }
    _transaction(() {
      // Discarding never rebases later edits onto newly pulled remote content.
      _db.execute(
        'UPDATE outbox SET observed_version = ?, predecessor_id = NULL WHERE predecessor_id = ? AND base_version IS NULL',
        [mutation.observedVersion, operationId],
      );
      _db.execute('DELETE FROM outbox WHERE operation_id = ?', [operationId]);
    });
  }

  void applyPage(SyncPage page, String? token) {
    if (page.cursor.isEmpty) throw FormatException('Empty sync cursor.');
    _transaction(() {
      for (final document in page.changes) {
        _upsert(document);
      }
      _setMetadata('cursor', page.cursor);
      _setMetadata('consistency_token', token);
      if (!page.hasMore) _setMetadata('bootstrap_incomplete', 'false');
    });
  }

  /// Restarts retained-journal replay without rewriting already attempted writes.
  void resetForResync() {
    _transaction(() {
      _db.execute('DELETE FROM documents');
      _setMetadata('cursor', null);
      _setMetadata('consistency_token', null);
      _setMetadata('bootstrap_incomplete', 'true');
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.close();
    _lock?.closeSync();
    _openPaths.remove(_path);
  }

  void _upsert(ServerDocument document) => _db.execute(
    '''
    INSERT INTO documents(id, data, version, deleted) VALUES (?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET data=excluded.data,
      version=excluded.version, deleted=excluded.deleted
    WHERE excluded.version > documents.version
  ''',
    [
      document.id,
      document.data == null ? null : jsonEncode(document.data),
      document.version,
      document.deleted ? 1 : 0,
    ],
  );

  PendingMutation _findPending(String operationId) {
    final rows = _db.select('SELECT * FROM outbox WHERE operation_id = ?', [
      operationId,
    ]);
    if (rows.isEmpty) {
      throw StateError('Unknown pending operation: $operationId.');
    }
    return _pendingFromRow(rows.first);
  }

  PendingMutation _pendingFromRow(Row row) => PendingMutation(
    sequence: row['sequence'] as int,
    operationId: row['operation_id'] as String,
    documentId: row['document_id'] as String,
    kind: MutationKind.values.byName(row['kind'] as String),
    data: _decodeData(row['data']),
    state: MutationState.values.byName(row['state'] as String),
    attempts: row['attempts'] as int,
    baseVersion: row['base_version'] as int?,
    observedVersion: row['observed_version'] as int,
    predecessorOperationId: row['predecessor_id'] as String?,
    nextAttemptAt: row['next_attempt_ms'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            row['next_attempt_ms'] as int,
            isUtc: true,
          ),
    errorCode: row['error_code'] as String?,
  );

  Map<String, Object?>? _decodeData(Object? value) =>
      value == null ? null : (jsonDecode(value as String) as Map).cast();

  String? _metadata(String key) {
    final rows = _db.select('SELECT value FROM metadata WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void _setMetadata(String key, String? value) {
    if (value == null) {
      _db.execute('DELETE FROM metadata WHERE key = ?', [key]);
    } else {
      _db.execute(
        'INSERT INTO metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
        [key, value],
      );
    }
  }

  T _transaction<T>(T Function() action) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }
}
