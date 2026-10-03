import 'dart:async';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:flutter/foundation.dart';

import '../data/workspace_repository.dart';

/// UI state for one verified workspace. The SDK owns queue/cursor semantics.
class WorkspaceController extends ChangeNotifier {
  WorkspaceController({required this.repository});

  final WorkspaceRepository repository;
  CosmosSyncClient? _client;
  StreamSubscription<List<DocumentSnapshot>>? _documentsSubscription;
  StreamSubscription<SyncStatus>? _statusSubscription;
  List<DocumentSnapshot> documents = const [];
  List<PendingMutation> pending = const [];
  SyncStatus? status;
  bool busy = false;
  bool offline = false;
  bool connected = false;
  bool _closed = false;
  String? message;
  SessionInfo? get session => _client?.session;
  bool get bootstrapComplete => _client?.cache.bootstrapIncomplete == false;
  bool get canEdit => connected && !busy && status?.paused != true;

  Future<void> connect({
    required ConnectionConfig config,
    required String credentialBinding,
    required Future<String> Function() tokenProvider,
    bool offline = false,
  }) => _command(() async {
    await disconnect();
    this.offline = offline;
    final client = await repository.open(
      config: config,
      credentialBinding: credentialBinding,
      tokenProvider: tokenProvider,
      offline: offline,
    );
    _client = client;
    connected = true;
    _documentsSubscription = client.watchAll().listen((value) {
      documents = value;
      _refresh();
    });
    _statusSubscription = client.statuses.listen((value) {
      status = value;
      if (value.paused) {
        message =
            'Access paused: ${value.reason ?? 'authorization changed'}. '
            'Cached data has been cleared; sign in again.';
      } else if (value.lastError != null) {
        message = 'Connection unavailable. Local edits remain durable.';
      }
      _refresh();
    });
    if (!offline) {
      client.startWatching();
      await _synchronize();
    } else {
      message =
          'Offline cache opened. Writes are saved locally until reconnect.';
    }
  });

  Future<void> put(String id, Map<String, Object?> data) => _command(() async {
    await _requireClient().put(id, data);
    message = 'Saved locally. Waiting for server acknowledgement.';
    _refresh();
    if (!offline) await _synchronize();
  });

  Future<void> delete(String id) => _command(() async {
    await _requireClient().delete(id);
    message = 'Deletion saved locally. Waiting for server acknowledgement.';
    _refresh();
    if (!offline) await _synchronize();
  });

  Future<void> synchronize() => _command(_synchronize);

  Future<void> _synchronize() async {
    if (offline) return;
    final client = _requireClient();
    await client.sync();
    final result = await client.flush();
    message = result.remaining == 0
        ? 'Up to date. Server acknowledged all pending writes.'
        : '${result.remaining} pending write(s). '
              'Review conflicts or wait for the retry deadline.';
    _refresh();
  }

  Future<void> setOffline(bool value) => _command(() async {
    final client = _requireClient();
    offline = value;
    if (value) {
      client.stopWatching();
      message =
          'Automatic network activity paused. Local edits remain available.';
    } else {
      client.startWatching();
      await _synchronize();
    }
  });

  Future<void> keepLocal(PendingMutation mutation) => _command(() async {
    await _requireClient().retryConflict(
      mutation.operationId,
      data: mutation.kind == MutationKind.put ? mutation.data : null,
    );
    _refresh();
    if (!offline) await _synchronize();
  });

  Future<void> useServer(PendingMutation mutation) => _command(() async {
    await _requireClient().discard(mutation.operationId);
    message = 'Local operation discarded. Later queued edits are preserved.';
    _refresh();
    if (!offline) await _synchronize();
  });

  Future<void> disconnect({bool purge = false}) async {
    connected = false;
    await _documentsSubscription?.cancel();
    await _statusSubscription?.cancel();
    _documentsSubscription = null;
    _statusSubscription = null;
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        if (purge) await client.signOut();
      } finally {
        await client.close();
      }
    }
    documents = const [];
    pending = const [];
    status = null;
    if (purge) await repository.purge();
    _refresh();
  }

  CosmosSyncClient _requireClient() =>
      _client ?? (throw StateError('Connect to a workspace first.'));

  Future<void> _command(Future<void> Function() action) async {
    if (busy || _closed) return;
    busy = true;
    message = null;
    _refresh();
    try {
      await action();
    } catch (error) {
      // Never surface raw provider URLs, headers or token responses.
      message = error is TransportException
          ? 'BFF request failed (${error.statusCode ?? 'network'}, ${error.code}). '
                'Local writes remain pending unless access was revoked.'
          : error is FormatException || error is ArgumentError
          ? 'Invalid document or connection settings.'
          : 'Operation unavailable. Check connection and authentication settings.';
    } finally {
      busy = false;
      _refresh();
    }
  }

  void _refresh() {
    if (_client != null) {
      documents = _client!.list();
      pending = _client!.pending;
      status = _client!.status;
    }
    if (!_closed) notifyListeners();
  }

  /// Owners must await disconnect before disposing this notifier.
  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
