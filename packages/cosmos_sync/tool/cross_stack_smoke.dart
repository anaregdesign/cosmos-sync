import 'dart:convert';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';

// Run only against the disposable Go OIDC+memory-store fixture. This fixture
// creates no Azure resources and validates actual signed JWTs in the Go BFF.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Pass the Go fixture ready JSON path.');
  }
  final fixture = jsonDecode(File(args.single).readAsStringSync()) as Map;
  final endpoint = Uri.parse(fixture['url'] as String);
  final token = fixture['token'] as String;
  final directory = Directory.systemTemp.createTempSync('cosmos-sync-e2e-');
  HttpSyncTransport transport() => HttpSyncTransport(
    baseUri: endpoint,
    tokenProvider: () async => token,
    allowInsecureLocalhost: true,
  );
  CosmosSyncClient? first;
  CosmosSyncClient? second;
  void check(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  try {
    first = await CosmosSyncClient.open(
      path: '${directory.path}/first.db',
      transport: transport(),
    );
    await first.put('note', {'title': 'offline', 'count': 1});
    check(
      first.get('note')!.hasPendingWrites,
      'local enqueue has pending state',
    );
    await first.close();
    first = await CosmosSyncClient.open(
      path: '${directory.path}/first.db',
      transport: transport(),
    );
    check(first.pending.length == 1, 'outbox survived reopen');
    check(
      (await first.flush()).acknowledged == 1,
      'Go accepted first mutation',
    );
    check(
      !first.get('note')!.hasPendingWrites,
      'ACK cleared only delivered edit',
    );
    second = await CosmosSyncClient.open(
      path: '${directory.path}/second.db',
      transport: transport(),
    );
    await second.sync(pageSize: 1);
    check(
      second.get('note')!.data!['title'] == 'offline',
      'initial journal replay',
    );

    await first.put('note', {'title': 'updated', 'count': 2});
    await first.flush();
    await second.sync(pageSize: 1);
    check(second.get('note')!.data!['count'] == 2, 'incremental cursor resume');

    final staleEdit = await second.put('note', {'title': 'stale offline edit'});
    await first.put('note', {'title': 'concurrent server edit', 'count': 3});
    await first.flush();
    await second.sync();
    check(
      (await second.flush()).acknowledged == 0,
      'stale edit cannot overwrite',
    );
    check(
      second.get('note')!.hasConflict,
      'pull before flush preserves conflict',
    );
    await first.sync();
    check(
      first.get('note')!.data!['count'] == 3,
      'server retains concurrent edit',
    );
    await second.discard(staleEdit);

    await first.delete('note');
    await first.flush();
    await second.sync();
    check(second.get('note')!.deleted, 'remote tombstone retained');
    check(second.list().isEmpty, 'deleted data excluded from collection');

    await first.put('note', {'title': 'recreated'});
    await first.flush();
    await second.sync();
    check(!second.get('note')!.deleted, 'recreate against tombstone version');
    check(second.get('note')!.data!['title'] == 'recreated', 'recreate data');
    stdout.writeln(
      'PASS Go JWT BFF + Dart SQLite: offline restart, ACK, initial/incremental sync, stale-edit conflict, delete/recreate',
    );
  } finally {
    await first?.close();
    await second?.close();
    directory.deleteSync(recursive: true);
  }
}
