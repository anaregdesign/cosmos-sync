@TestOn('browser')
library;

import 'dart:convert';

import 'package:cosmos_sync/cosmos_sync_browser.dart';
import 'package:cosmos_sync_example/data/settings_store_web.dart';
import 'package:cosmos_sync_example/data/workspace_repository_base.dart';
import 'package:cosmos_sync_example/data/workspace_repository_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import '../support/test_transport.dart';

void main() {
  late WorkspaceRepository repository;
  late TestServer server;
  late String namespace;
  final opened = <CosmosSyncClient>[];
  final config = ConnectionConfig(
    bffUri: Uri.parse('https://bff.example.test'),
  );
  var sequence = 0;

  WorkspaceRepository makeRepository() => WorkspaceRepository(
    namespace: namespace,
    transportFactory: (_, _) => TestTransport(server),
  );
  Future<CosmosSyncClient> open(
    WorkspaceRepository target, {
    String binding = 'original-credential-session',
    bool offline = false,
  }) async {
    final client = await target.open(
      config: config,
      credentialBinding: binding,
      tokenProvider: () async {
        if (offline) throw StateError('Offline must not request a token.');
        return 'fixture-only-api-token';
      },
      offline: offline,
    );
    opened.add(client);
    return client;
  }

  setUp(() {
    namespace =
        'cosmos-web-${DateTime.now().microsecondsSinceEpoch}-${sequence++}';
    server = TestServer();
    repository = makeRepository();
  });
  tearDown(() async {
    for (final client in opened) {
      await client.close();
    }
    opened.clear();
    await repository.purge();
    web.window.localStorage.removeItem('$namespace.connection');
  });

  test(
    'real IndexedDB preserves a committed operation inside the verified document',
    () async {
      var client = await open(repository);
      expect(client.cache, isA<IndexedDbCache>());
      final operation = await client.put('offline', {'text': 'durable'});
      await client.close();
      server.offline = true;
      client = await open(repository, offline: true);
      expect(client.pending.single.operationId, operation);
      expect(client.get('offline')!.data, {'text': 'durable'});
      await client.close();
      await expectLater(
        open(repository, binding: 'new-interactive-session', offline: true),
        throwsStateError,
      );
    },
  );

  test(
    'new document cannot restore credentials or reopen IndexedDB before an online rebind',
    () async {
      final initial = await open(repository);
      final operation = await initial.put('private', {
        'text': 'survives storage reopen',
      });
      await initial.close();
      final reloaded = makeRepository();
      await expectLater(open(reloaded, offline: true), throwsStateError);
      server.offline = true;
      await expectLater(open(reloaded), throwsA(isA<TransportException>()));
      await expectLater(open(reloaded, offline: true), throwsStateError);
      server.offline = false;
      final rebound = await open(
        reloaded,
        binding: 'fresh-interactive-session',
      );
      expect(rebound.pending.single.operationId, operation);
      expect(rebound.get('private')!.data!['text'], 'survives storage reopen');
    },
  );

  test(
    'BFF account switches select isolated databases and logout removes all owned caches',
    () async {
      var client = await open(repository);
      await client.put('alice-private', {'text': 'Alice only'});
      await client.close();
      server.principal = 'bob';
      client = await open(repository, binding: 'bob-session');
      expect(client.list(), isEmpty);
      expect(client.pending, isEmpty);
      await client.close();
      final key = '$namespace.cache-registry';
      expect(
        (jsonDecode(web.window.localStorage.getItem(key)!) as List).length,
        2,
      );
      await repository.purge();
      expect(web.window.localStorage.getItem(key), null);
      server.principal = 'alice';
      client = await open(repository, binding: 'alice-reauthenticated');
      expect(client.list(), isEmpty);
      expect(client.pending, isEmpty);
    },
  );

  test(
    'a learned online denial purges the saved offline authorization and database',
    () async {
      final original = await open(repository);
      await original.put('private', {'text': 'must disappear'});
      await original.close();
      server.revoked = true;
      await expectLater(open(repository), throwsA(isA<TransportException>()));
      expect(
        web.window.localStorage.getItem('$namespace.cache-registry'),
        null,
      );
      await expectLater(open(repository, offline: true), throwsStateError);
      server.revoked = false;
      final reverified = await open(
        repository,
        binding: 'new-permission-session',
      );
      expect(reverified.list(), isEmpty);
      expect(reverified.pending, isEmpty);
    },
  );

  test(
    'another live cache owner prevents deletion and is never a successful logout',
    () async {
      final original = await open(repository);
      await original.put('private', {'text': 'held by another owner'});
      final names = web.window.localStorage.getItem(
        '$namespace.cache-registry',
      );
      await expectLater(repository.purge(), throwsA(isA<StateError>()));
      expect(
        web.window.localStorage.getItem('$namespace.cache-registry'),
        names,
      );
      expect(original.get('private')!.data!['text'], 'held by another owner');
      await original.close();
      await repository.purge();
      expect(
        web.window.localStorage.getItem('$namespace.cache-registry'),
        null,
      );
    },
  );

  test(
    'a corrupted registry cannot enumerate or delete foreign browser data',
    () async {
      final original = await open(repository);
      await original.put('owned', {'text': 'retained until explicit cleanup'});
      await original.close();
      final key = '$namespace.cache-registry';
      final saved = web.window.localStorage.getItem(key)!;
      for (final invalid in [
        ['foreign-application:${'a' * 64}'],
        ['$namespace:../../outside'],
        List.filled(65, '$namespace:${'b' * 64}'),
        ['$namespace:${'b' * 64}', '$namespace:${'b' * 64}'],
        {'not': 'a list'},
      ]) {
        web.window.localStorage.setItem(key, jsonEncode(invalid));
        await expectLater(repository.prepare(), throwsStateError);
        await expectLater(repository.purge(), throwsStateError);
      }
      web.window.localStorage.setItem(key, saved);
      final reverified = await open(
        repository,
        binding: 'explicit-online-rebind',
      );
      expect(
        reverified.get('owned')!.data!['text'],
        'retained until explicit cleanup',
      );
    },
  );

  test(
    'only public settings and bounded database names enter localStorage',
    () async {
      final store = BrowserSettingsStore(key: '$namespace.connection');
      await store.write(
        jsonEncode({
          'bffUri': config.bffUri.toString(),
          'publicClientId': 'fixture-spa',
        }),
      );
      final client = await open(repository);
      expect(await store.read(), contains('fixture-spa'));
      final registry = web.window.localStorage.getItem(
        '$namespace.cache-registry',
      )!;
      expect(registry, isNot(contains('fixture-only-api-token')));
      expect(registry, isNot(contains('credential-session')));
      expect(registry, isNot(contains('alice')));
      expect(
        (jsonDecode(registry) as List).single,
        matches('^$namespace:[0-9a-f]{64}\$'),
      );
      await client.close();
      await expectLater(store.write('x' * 65537), throwsStateError);
    },
  );
}
