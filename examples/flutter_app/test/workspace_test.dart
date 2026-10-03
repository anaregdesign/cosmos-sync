import 'dart:async';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:cosmos_sync_example/data/workspace_repository.dart';
import 'package:cosmos_sync_example/ui/workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/test_transport.dart';

void main() {
  late Directory directory;
  late TestServer server;
  late WorkspaceRepository repository;
  final config = ConnectionConfig(
    bffUri: Uri.parse('https://bff.example.test'),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cosmos-app-test-');
    server = TestServer();
    repository = WorkspaceRepository(
      directory: Directory('${directory.path}/cache'),
      transportFactory: (_, _) => TestTransport(server),
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'shared configuration preserves legacy keys and binds exact shared identity',
    () {
      expect(config.toJson(), {
        'bffUri': 'https://bff.example.test',
        'scopeMode': 'user',
        'allowInsecureLocalhost': false,
      });
      final shared = ConnectionConfig(
        bffUri: config.bffUri,
        scopeMode: SyncScopeMode.shared,
        sharedScopeId: 'b' * 64,
      );
      final other = ConnectionConfig(
        bffUri: config.bffUri,
        scopeMode: SyncScopeMode.shared,
        sharedScopeId: 'c' * 64,
      );
      expect(ConnectionConfig.fromJson(shared.toJson()).key, shared.key);
      expect(shared.key, isNot(config.key));
      expect(shared.key, isNot(other.key));
      for (final value in [
        {...shared.toJson(), 'scopeMode': 'tenant'},
        {...shared.toJson(), 'sharedScopeId': '../scope'},
        {...shared.toJson(), 'sharedScopeId': null},
      ]) {
        expect(() => ConnectionConfig.fromJson(value), throwsArgumentError);
      }
    },
  );

  test(
    'shared selection cannot reopen a personal verified cache offline',
    () async {
      final original = await repository.open(
        config: config,
        credentialBinding: 'same-signed-in-account',
        tokenProvider: () async => 'api-token',
      );
      await original.put('private', {'text': 'personal'});
      await original.close();
      await expectLater(
        repository.open(
          config: ConnectionConfig(
            bffUri: config.bffUri,
            scopeMode: SyncScopeMode.shared,
            sharedScopeId: 'b' * 64,
          ),
          credentialBinding: 'same-signed-in-account',
          tokenProvider: () async =>
              throw StateError('No offline token request.'),
          offline: true,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'shared selection rejects a substituted server session before opening a cache',
    () async {
      await expectLater(
        repository.open(
          config: ConnectionConfig(
            bffUri: config.bffUri,
            scopeMode: SyncScopeMode.shared,
            sharedScopeId: 'b' * 64,
          ),
          credentialBinding: 'same-signed-in-account',
          tokenProvider: () async => 'api-token',
        ),
        throwsStateError,
      );
      expect(await Directory('${directory.path}/cache').list().isEmpty, true);
    },
  );

  test('offline reopen requires the same secure credential binding', () async {
    var client = await repository.open(
      config: config,
      credentialBinding: 'first-sign-in',
      tokenProvider: () async => 'test-access',
    );
    final operation = await client.put('offline-note', {'title': 'saved'});
    await client.close();
    server.offline = true;
    client = await repository.open(
      config: config,
      credentialBinding: 'first-sign-in',
      tokenProvider: () async => throw StateError('No network while offline.'),
      offline: true,
    );
    expect(client.get('offline-note')!.data!['title'], 'saved');
    expect(client.pending.single.operationId, operation);
    await client.close();
    await expectLater(
      repository.open(
        config: config,
        credentialBinding: 'new-interactive-sign-in',
        tokenProvider: () async => 'test-access',
        offline: true,
      ),
      throwsStateError,
    );
  });

  test('BFF principal changes select a separate cache', () async {
    var client = await repository.open(
      config: config,
      credentialBinding: 'alice-login',
      tokenProvider: () async => 'test-access',
    );
    await client.put('private', {'title': 'Alice only'});
    await client.close();
    server.principal = 'bob';
    client = await repository.open(
      config: config,
      credentialBinding: 'bob-login',
      tokenProvider: () async => 'test-access',
    );
    expect(client.list(), isEmpty);
    expect(client.pending, isEmpty);
    await client.close();
    await repository.purge();
    expect(await repository.directory.exists(), false);
  });

  test(
    'signout drains a late HTTP ACK before deleting every cache file',
    () async {
      final workspace = WorkspaceController(repository: repository);
      await workspace.connect(
        config: config,
        credentialBinding: 'alice-login',
        tokenProvider: () async => 'test-access',
      );
      server.inFlight = Completer<ServerDocument>();
      final saving = workspace.put('note', {'title': 'late ACK'});
      await server.started.future;
      final signingOut = workspace.disconnect(purge: true);
      await Future<void>.delayed(Duration.zero);
      expect(workspace.connected, false);
      server.inFlight!.complete(
        ServerDocument(
          id: 'note',
          data: {'title': 'late ACK'},
          version: 1,
          deleted: false,
        ),
      );
      await Future.wait([saving, signingOut]);
      expect(workspace.documents, isEmpty);
      expect(workspace.pending, isEmpty);
      expect(await repository.directory.exists(), false);
      workspace.dispose();
    },
  );

  test(
    'capacity failures show the error and retain the exact attempted operation',
    () async {
      final workspace = WorkspaceController(repository: repository);
      await workspace.connect(
        config: config,
        credentialBinding: 'alice-login',
        tokenProvider: () async => 'test-access',
      );
      server.capacityExceeded = true;
      await workspace.put('note', {'title': 'pending'});
      final pending = workspace.pending.single;
      expect(pending.state, MutationState.queued);
      expect(pending.errorCode, 'scope_capacity_exceeded');
      expect(pending.attempts, 1);
      expect(pending.nextAttemptAt, isNotNull);
      final operation = pending.operationId;
      await workspace.synchronize();
      expect(workspace.pending.single.operationId, operation);
      expect(server.requests.length, 1, reason: 'Retry deadline is respected.');
      await workspace.disconnect(purge: true);
      workspace.dispose();
    },
  );

  test(
    'permission revocation empties the visible workspace and disables edits',
    () async {
      final workspace = WorkspaceController(repository: repository);
      await workspace.connect(
        config: config,
        credentialBinding: 'alice-login',
        tokenProvider: () async => 'test-access',
      );
      await workspace.setOffline(true);
      await workspace.put('note', {'title': 'offline'});
      expect(workspace.documents, isNotEmpty);
      server.revoked = true;
      await workspace.setOffline(false);
      expect(workspace.documents, isEmpty);
      expect(workspace.pending, isEmpty);
      expect(workspace.status!.paused, true);
      expect(workspace.canEdit, false);
      await workspace.disconnect(purge: true);
      workspace.dispose();
    },
  );
}
