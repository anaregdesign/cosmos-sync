import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:http/io_client.dart';

// Only the disposable Go fixture is accepted. No real provider users, Azure
// resources or certificate validation bypasses are involved in this probe.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Pass the disposable Go fixture ready JSON path.');
  }
  final fixture = (jsonDecode(File(args.single).readAsStringSync()) as Map)
      .cast<String, Object?>();
  final endpoint = Uri.parse(fixture['url'] as String);
  if (endpoint.scheme != 'https' ||
      !{'localhost', '127.0.0.1', '::1'}.contains(endpoint.host)) {
    throw ArgumentError('The authorization fixture requires loopback HTTPS.');
  }
  final tokens = (fixture['tokens'] as Map).cast<String, String>();
  final certificate = File(fixture['certificate'] as String).readAsBytesSync();
  final directory = Directory.systemTemp.createTempSync(
    'cosmos-sync-authorization-cache-',
  );
  final transports = <HttpSyncTransport>[];
  final clients = <CosmosSyncClient>[];

  HttpSyncTransport transport(String principal, {String? sharedScopeId}) {
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(certificate);
    final result = HttpSyncTransport(
      baseUri: endpoint,
      tokenProvider: () async => tokens[principal]!,
      client: IOClient(HttpClient(context: context)),
      requestTimeout: const Duration(seconds: 4),
      scopeMode: sharedScopeId == null
          ? SyncScopeMode.user
          : SyncScopeMode.shared,
      sharedScopeId: sharedScopeId,
    );
    transports.add(result);
    return result;
  }

  Future<CosmosSyncClient> open(String name, HttpSyncTransport value) async {
    final client = await CosmosSyncClient.open(
      path: '${directory.path}/$name.db',
      transport: value,
    );
    clients.add(client);
    return client;
  }

  try {
    final owner = transport('owner');
    final member = transport('member');
    final outsider = transport('ungranted');
    await expectTransport(
      () => transport('wrongAudience').account(),
      status: 401,
      code: 'unauthorized',
    );
    final ownerAccount = await owner.account();
    final memberAccount = await member.account();
    final outsiderAccount = await outsider.account();
    check(
      {
            ownerAccount.accountId,
            memberAccount.accountId,
            outsiderAccount.accountId,
          }.length ==
          3,
      'Verified subjects must remain separate even with matching email claims.',
    );
    check(
      (await owner.account()).accountId == ownerAccount.accountId,
      'Account registration must be stable.',
    );
    final ownerPersonal = await open('owner-personal', owner);
    final memberPersonal = await open('member-personal', member);
    check(
      ownerPersonal.session.scopeId == ownerAccount.personalScopeId &&
          ownerPersonal.session.principalId == ownerAccount.accountId,
      'Personal session must match the server-issued account namespace.',
    );
    await ownerPersonal.put('private-note', {'visibility': 'owner-only'});
    check((await ownerPersonal.flush()).acknowledged == 1, 'Personal ACK.');
    await memberPersonal.sync();
    check(memberPersonal.list().isEmpty, 'Personal data crossed accounts.');

    // Persist and rehydrate the exact management request, as required after an
    // unknown response or app exit. A new operation ID would create a new scope.
    final create = CreateSharedScopeRequest.create();
    final requestFile = File('${directory.path}/create-request.json')
      ..writeAsStringSync(jsonEncode(create.toJson()), flush: true);
    final replayCreate = CreateSharedScopeRequest.fromJson(
      (jsonDecode(requestFile.readAsStringSync()) as Map).cast(),
    );
    var policy = await owner.createSharedScope(create);
    final initial = await owner.createSharedScope(replayCreate);
    check(
      policy.scopeId == initial.scopeId &&
          policy.ownerAccountId == ownerAccount.accountId &&
          policy.revision == 1 &&
          policy.members.isEmpty,
      'Shared creation and exact replay must retain the fixed creator.',
    );
    final sharedId = policy.scopeId;
    await expectTransport(
      () => transport('ungranted', sharedScopeId: sharedId).sessionInfo(),
      status: 403,
      code: 'forbidden',
    );
    await expectTransport(
      () => member.setSharedScopeMember(
        sharedId,
        SetSharedScopeMemberRequest.create(
          accountId: memberAccount.accountId,
          role: SharedScopeRole.writer,
          baseRevision: policy.revision,
        ),
      ),
      status: 403,
      code: 'forbidden',
    );
    await expectTransport(
      () => owner.setSharedScopeMember(
        sharedId,
        SetSharedScopeMemberRequest.create(
          accountId: ownerAccount.accountId,
          role: SharedScopeRole.none,
          baseRevision: policy.revision,
        ),
      ),
      status: 409,
      code: 'immutable_owner',
    );
    final grantReader = SetSharedScopeMemberRequest.create(
      accountId: memberAccount.accountId,
      role: SharedScopeRole.reader,
      baseRevision: policy.revision,
    );
    policy = await owner.setSharedScopeMember(sharedId, grantReader);
    final ownerSharedTransport = transport('owner', sharedScopeId: sharedId);
    final ownerShared = await open('owner-shared', ownerSharedTransport);
    final readerTransport = transport('member', sharedScopeId: sharedId);
    final reader = await open('reader', readerTransport);
    await ownerShared.put('shared-note', {'value': 'owner'});
    await ownerShared.flush();
    await reader.sync();
    check(reader.get('shared-note')?.data?['value'] == 'owner', 'Reader pull.');
    await expectTransport(
      () => readerTransport.sharedScopeMembers(sharedId),
      status: 403,
      code: 'forbidden',
    );
    await reader.put('reader-denied', {'value': 'never accepted'});
    await expectTransport(reader.flush, status: 403, code: 'forbidden');
    check(
      reader.status.paused && reader.pending.isEmpty && reader.list().isEmpty,
      'A server write denial must purge and pause the SDK cache/outbox.',
    );

    policy = await owner.setSharedScopeMember(
      sharedId,
      SetSharedScopeMemberRequest.create(
        accountId: memberAccount.accountId,
        role: SharedScopeRole.writer,
        baseRevision: policy.revision,
      ),
    );
    final replayReader = await owner.setSharedScopeMember(
      sharedId,
      grantReader,
    );
    check(
      replayReader.revision == 2 &&
          replayReader.members.single.role == SharedScopeRole.reader,
      'Management replay must return its original snapshot after later edits.',
    );
    await expectTransport(
      () => owner.setSharedScopeMember(
        sharedId,
        SetSharedScopeMemberRequest(
          operationId: grantReader.operationId,
          accountId: memberAccount.accountId,
          role: SharedScopeRole.writer,
          baseRevision: grantReader.baseRevision,
        ),
      ),
      status: 409,
      code: 'idempotency_mismatch',
    );
    await expectTransport(
      () => owner.setSharedScopeMember(
        sharedId,
        SetSharedScopeMemberRequest.create(
          accountId: memberAccount.accountId,
          role: SharedScopeRole.reader,
          baseRevision: 1,
        ),
      ),
      status: 409,
      code: 'membership_conflict',
    );
    final writerTransport = transport('member', sharedScopeId: sharedId);
    var writer = await open('writer', writerTransport);
    await writer.sync();
    await writer.put('shared-note', {'value': 'member-writer'});
    check((await writer.flush()).acknowledged == 1, 'Shared writer ACK.');
    await writer.sync();
    final oldCursor = writer.cache.cursor!;
    final staleWriter = transport('member', sharedScopeId: sharedId);
    final oldBinding = await staleWriter.sessionInfo();
    final receiptRequest = MutationRequest(
      operationId: CreateSharedScopeRequest.create().operationId,
      documentId: 'receipt-note',
      kind: MutationKind.put,
      data: {'value': 'accepted-before-revoke'},
      baseVersion: 0,
    );
    await staleWriter.mutate(receiptRequest);
    await writer.put('demoted-pending', {'value': 'offline pending'});
    final pendingId = writer.pending.single.operationId;
    await writer.close();
    policy = await owner.setSharedScopeMember(
      sharedId,
      SetSharedScopeMemberRequest.create(
        accountId: memberAccount.accountId,
        role: SharedScopeRole.reader,
        baseRevision: policy.revision,
      ),
    );
    writer = await open('writer', transport('member', sharedScopeId: sharedId));
    check(
      writer.pending.single.operationId == pendingId,
      'Offline pending identity must survive reopen before permission refresh.',
    );
    await expectState(
      writer.flush,
      'Demotion must detect the changed binding.',
    );
    check(
      writer.status.paused &&
          writer.status.reason == 'scope_changed' &&
          writer.pending.isEmpty &&
          writer.list().isEmpty,
      'Demotion must purge durable cache and pending writes before transmission.',
    );
    await expectTransport(
      staleWriter.sync,
      status: 403,
      code: 'session_mismatch',
    );
    final currentReader = transport('member', sharedScopeId: sharedId);
    final readerBinding = await currentReader.sessionInfo();
    check(
      readerBinding.permissionVersion != oldBinding.permissionVersion,
      'Demotion must advance this member permission generation.',
    );
    await expectTransport(
      () => currentReader.sync(cursor: oldCursor),
      status: 410,
      code: 'resync_required',
    );
    await writer.resume();
    await writer.sync();
    await writer.put('revoked-pending', {'value': 'never upload after revoke'});

    // Receiving a real change hint proves the SSE request was established;
    // revoke only afterwards, then require an authorization error on that stream.
    final hintReceived = Completer<void>();
    final streamFailure = Completer<TransportException>();
    final eventTransport = transport('member', sharedScopeId: sharedId);
    await eventTransport.sessionInfo();
    final stream = eventTransport.watchChanges().listen(
      (_) {
        if (!hintReceived.isCompleted) hintReceived.complete();
      },
      onError: (Object error) {
        if (!streamFailure.isCompleted) {
          if (error is TransportException) {
            streamFailure.complete(error);
          } else {
            streamFailure.completeError(error);
          }
        }
      },
      onDone: () {
        if (!streamFailure.isCompleted) {
          streamFailure.completeError(StateError('SSE closed without revoke.'));
        }
      },
    );
    try {
      await hintReceived.future.timeout(const Duration(seconds: 3));
      policy = await owner.setSharedScopeMember(
        sharedId,
        SetSharedScopeMemberRequest.create(
          accountId: memberAccount.accountId,
          role: SharedScopeRole.none,
          baseRevision: policy.revision,
        ),
      );
      final failure = await streamFailure.future.timeout(
        const Duration(seconds: 3),
      );
      check(
        failure.statusCode == 403 && failure.code == 'forbidden',
        'An active SSE connection retained revoked membership.',
      );
    } finally {
      await stream.cancel();
    }
    await expectTransport(writer.sync, status: 403, code: 'forbidden');
    check(
      writer.status.paused && writer.pending.isEmpty && writer.list().isEmpty,
      'Revocation must purge the SDK cache and offline pending edits.',
    );
    await expectTransport(
      () => staleWriter.mutate(receiptRequest),
      status: 403,
      code: 'forbidden',
    );
    check(
      (await ownerSharedTransport.sessionInfo()).permissionVersion == '1' &&
          ownerPersonal.get('private-note') != null,
      'Member edits must not change the fixed owner binding or personal cache.',
    );
    policy = await owner.setSharedScopeMember(
      sharedId,
      SetSharedScopeMemberRequest.create(
        accountId: memberAccount.accountId,
        role: SharedScopeRole.writer,
        baseRevision: policy.revision,
      ),
    );
    final restored = transport('member', sharedScopeId: sharedId);
    final restoredBinding = await restored.sessionInfo();
    check(
      restoredBinding.permissionVersion != readerBinding.permissionVersion,
      'Removal and re-addition must never resurrect an earlier generation.',
    );
    await expectTransport(
      () => restored.sync(cursor: oldCursor),
      status: 410,
      code: 'resync_required',
    );
    await writer.resume();
    await writer.sync();
    check(
      writer.get('demoted-pending') == null &&
          writer.get('revoked-pending') == null &&
          writer.get('reader-denied') == null,
      'Rejected or purged edits appeared in the server journal.',
    );
    final deleteRequest = MutationRequest(
      operationId: CreateSharedScopeRequest.create().operationId,
      documentId: 'shared-note',
      kind: MutationKind.delete,
      data: null,
      baseVersion: writer.get('shared-note')!.version,
    );
    final deleted = await restored.mutate(deleteRequest);
    final deleteReplay = await restored.mutate(deleteRequest);
    check(
      deleted.deleted &&
          deleteReplay.deleted &&
          deleted.version == deleteReplay.version,
      'Exact delete replay must retain the original tombstone and version.',
    );
    await ownerShared.sync();
    check(
      ownerShared.get('shared-note')!.deleted,
      'Owner did not pull tombstone.',
    );
    final creationReplay = await owner.createSharedScope(replayCreate);
    check(
      creationReplay.scopeId == sharedId &&
          creationReplay.revision == 1 &&
          creationReplay.members.isEmpty &&
          (await owner.sharedScopeMembers(sharedId)).revision ==
              policy.revision,
      'Creation replay must not reset the current membership policy.',
    );
    stdout.writeln(
      'COSMOS_SYNC_AUTHORIZATION_PASS realHttp=true tls=trusted-certificate '
      'jwt=RSA-JWKS cache=SQLite identities=fixture-only '
      'account-isolation create-replay fixed-owner reader-denial membership-CAS '
      'writer-demotion durable-pending-purge active-SSE-revoke cursor-generation '
      'receipt-fence regrant delete-replay',
    );
  } finally {
    for (final client in clients) {
      await client.close();
    }
    for (final transport in transports) {
      transport.close();
    }
    directory.deleteSync(recursive: true);
  }
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> expectTransport(
  Future<Object?> Function() action, {
  required int status,
  required String code,
}) async {
  try {
    await action();
  } on TransportException catch (error) {
    check(
      error.statusCode == status && error.code == code,
      'Expected $status/$code, got ${error.statusCode}/${error.code}.',
    );
    return;
  }
  throw StateError('Expected server rejection $status/$code.');
}

Future<void> expectState(
  Future<Object?> Function() action,
  String message,
) async {
  try {
    await action();
  } on StateError {
    return;
  }
  throw StateError(message);
}
