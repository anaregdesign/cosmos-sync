import 'dart:async';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';

/// Shared recorded-token acceptance; it neither logs in nor mints tokens.
class RecordedDataJourney {
  RecordedDataJourney({
    required this.directory,
    required this.documentId,
    required this.transportFactory,
    required this.stage,
    this.directoryMode = false,
    this.purgeOnSignout = false,
    this.initialVerifiedSession,
  });

  final Directory directory;
  final String documentId;
  final HttpSyncTransport Function(bool Function() networkAllowed, bool peer)
  transportFactory;
  final Future<void> Function(String) stage;
  final bool directoryMode;
  final bool purgeOnSignout;
  final SessionInfo? initialVerifiedSession;

  Future<void> run() async {
    await directory.create(recursive: true);
    CosmosSyncClient? writer;
    CosmosSyncClient? peer;
    StreamSubscription<ChangeHint>? hints;
    StreamSubscription<DocumentSnapshot?>? watch;
    var networkAllowed = true;
    HttpSyncTransport transport({bool peer = false}) =>
        transportFactory(() => networkAllowed, peer);
    void document(CosmosSyncClient client, String value) {
      final current = client.get(documentId);
      _check(
        current != null &&
            !current.deleted &&
            !current.hasPendingWrites &&
            current.data?['value'] == value,
      );
    }

    try {
      writer = await CosmosSyncClient.open(
        path: '${directory.path}/writer.sqlite',
        transport: transport(),
        session: initialVerifiedSession,
      );
      final verified = writer.session;
      _check(
        !directoryMode ||
            verified.identityGeneration != null &&
                verified.identityGeneration! >= 1 &&
                verified.identityId != null &&
                verified.scopeMode == SyncScopeMode.user,
      );
      await writer.sync(maxPages: 4);
      _check(writer.query(LocalQuery()).metadata.bootstrapComplete);
      await stage('session_bootstrapped');

      networkAllowed = false;
      final operation = await writer.put(documentId, {
        'fixture': 'bounded-hosted-validation',
        'value': 'offline-create',
      });
      _check(writer.get(documentId)!.hasPendingWrites);
      _check(writer.pending.single.operationId == operation);
      await stage('offline_write_durable');
      await writer.close();
      writer = await CosmosSyncClient.open(
        path: '${directory.path}/writer.sqlite',
        transport: transport(),
        session: verified,
      );
      _check(
        writer.pending.single.operationId == operation &&
            writer.get(documentId)!.data?['value'] == 'offline-create' &&
            writer.session.principalId == verified.principalId &&
            writer.session.scopeId == verified.scopeId &&
            writer.session.identityGeneration == verified.identityGeneration &&
            writer.session.identityId == verified.identityId,
      );
      await stage('offline_cache_reopened');

      networkAllowed = true;
      final waiter = writer.waitForPendingWrites();
      unawaited(waiter.catchError((Object _) {}));
      final created = await writer.flush(maxOperations: 1);
      _check(created.acknowledged == 1 && created.remaining == 0);
      await waiter;
      document(writer, 'offline-create');
      await stage('create_acknowledged');

      final remote = transport(peer: true);
      peer = await CosmosSyncClient.open(
        path: '${directory.path}/peer.sqlite',
        transport: remote,
      );
      _check(
        peer.session.principalId == verified.principalId &&
            peer.session.scopeId == verified.scopeId &&
            peer.session.identityGeneration == verified.identityGeneration &&
            peer.session.identityId == verified.identityId,
      );
      await peer.sync(maxPages: 4);
      document(peer, 'offline-create');
      await stage('peer_received_create');
      final stale = await peer.put(documentId, {
        'fixture': 'bounded-hosted-validation',
        'value': 'stale-peer-edit',
      });
      final hint = Completer<void>();
      hints = remote
          .watchChanges(cursor: peer.cache.cursor)
          .listen(
            (_) {
              if (!hint.isCompleted) hint.complete();
            },
            onError: (Object _) {
              if (!hint.isCompleted) {
                hint.completeError(StateError('Recorded change hint failed.'));
              }
            },
          );
      final hintReady = hint.future.timeout(const Duration(seconds: 20));
      unawaited(hintReady.catchError((Object _) {}));
      await writer.put(documentId, {
        'fixture': 'bounded-hosted-validation',
        'value': 'online-update',
      });
      final updated = await writer.flush(maxOperations: 1);
      _check(updated.acknowledged == 1 && updated.remaining == 0);
      document(writer, 'online-update');
      await stage('update_acknowledged');
      await hintReady;
      await hints.cancel();
      hints = null;
      await stage('server_hint_received');
      final conflicted = await peer.flush(maxOperations: 1);
      _check(
        conflicted.acknowledged == 0 &&
            conflicted.remaining == 1 &&
            peer.pending.single.state == MutationState.conflict &&
            peer.pending.single.errorCode == 'conflict' &&
            peer.get(documentId)!.hasConflict,
      );
      await stage('stale_write_conflicted');
      await peer.discard(stale);
      _check(peer.pending.isEmpty);
      document(peer, 'online-update');
      await stage('server_version_chosen');
      await peer.sync(maxPages: 4);
      document(peer, 'online-update');
      await stage('remote_update_synchronized');
      final tombstone = Completer<void>();
      watch = peer.watch(documentId).listen((current) {
        if (current?.deleted == true &&
            current?.hasPendingWrites == false &&
            !tombstone.isCompleted) {
          tombstone.complete();
        }
      });
      await writer.delete(documentId);
      final deleted = await writer.flush(maxOperations: 1);
      _check(deleted.acknowledged == 1 && deleted.remaining == 0);
      _check(
        writer.get(documentId)!.deleted &&
            !writer.get(documentId)!.hasPendingWrites,
      );
      await stage('delete_acknowledged');
      await peer.sync(maxPages: 4);
      await tombstone.future.timeout(const Duration(seconds: 2));
      _check(peer.get(documentId)!.deleted);
      await stage('remote_tombstone_watched');
      await writer.close();
      writer = await CosmosSyncClient.open(
        path: '${directory.path}/writer.sqlite',
        transport: transport(),
      );
      await writer.sync(maxPages: 4);
      _check(writer.pending.isEmpty && writer.get(documentId)!.deleted);
      await stage('cache_reopened_with_tombstone');
      if (purgeOnSignout) {
        await writer.signOut();
        await peer.signOut();
        _check(
          writer.pending.isEmpty &&
              writer.list(includeDeleted: true).isEmpty &&
              peer.pending.isEmpty &&
              peer.list(includeDeleted: true).isEmpty,
        );
        await stage('directory_signout_purged');
      }
    } finally {
      await hints?.cancel();
      await watch?.cancel();
      await peer?.close();
      await writer?.close();
    }
  }
}

Future<SessionInfo> verifyDirectoryIdentity({
  required HttpSyncTransport transport,
  required String issuer,
  required String clientId,
  required String callback,
  required String namespace,
  required Future<void> Function(String) stage,
}) async {
  final capabilities = await transport.identityCapabilities();
  final target = capabilities.targetFor(
    issuer: issuer,
    clientId: clientId,
    callback: callback,
  );
  _check(target.provider == 'entra' && target.namespace == namespace);
  await stage('directory_capabilities_verified');
  final session = await transport.sessionInfo();
  final account = await transport.accountIdentities();
  _check(
    session.identityGeneration == account.identityGeneration &&
        session.identityId == account.currentIdentityId &&
        session.principalId == account.account.accountId &&
        session.scopeId == account.account.personalScopeId &&
        session.scopeMode == SyncScopeMode.user,
  );
  await stage('directory_registered_session_verified');
  return session;
}

void _check(bool condition) {
  if (!condition) throw StateError('Recorded data journey assertion failed.');
}
