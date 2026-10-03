import 'dart:async';
import 'dart:convert';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

// Disposable headless-browser fixture: real IndexedDB and authenticated Go HTTP.
Future<void> main() async {
  final output = web.document.getElementById('result')!;
  CosmosSyncClient? first;
  CosmosSyncClient? second;
  HttpSyncTransport? events;
  try {
    final reply = await http.get(
      Uri.parse('${web.window.location.origin}/fixture.json'),
    );
    final fixture = jsonDecode(reply.body) as Map;
    final base = Uri.parse(fixture['url'] as String);
    final token = fixture['token'] as String;
    HttpSyncTransport transport() => HttpSyncTransport(
      baseUri: base,
      tokenProvider: () async => token,
      allowInsecureLocalhost: true,
    );
    if (web.window.location.search == '?restore=1') {
      final restored =
          jsonDecode(web.window.sessionStorage.getItem('cosmosSyncRestore')!)
              as Map;
      first = await CosmosSyncClient.open(
        path: restored['first'] as String,
        transport: transport(),
      );
      check(
        first.pending.single.operationId == restored['operation'],
        'exact operation survived actual page reload',
      );
      check(
        first.get('browser-reload')!.data!['text'] == 'survives page reload',
        'pending overlay survived actual page reload',
      );
      check(
        first.cache.cursor == restored['cursor'] &&
            first.cache.consistencyToken == restored['session'] &&
            !first.cache.bootstrapIncomplete,
        'cursor/envelope/coverage survived actual page reload',
      );
      await first.signOut();
      second = await CosmosSyncClient.open(
        path: restored['second'] as String,
        transport: transport(),
      );
      await second.signOut();
      output.textContent =
          'PASS browser IndexedDB + Go JWT HTTP: CORS, reopen, ACK, snapshot, SSE, resume, query, tombstone, purge, actual page reload';
      return;
    }
    final prefix = 'cosmos-sync-http-${DateTime.now().microsecondsSinceEpoch}';
    first = await CosmosSyncClient.open(
      path: '$prefix-first',
      transport: transport(),
    );
    await first.put('browser-note', {'text': 'durable browser', 'rank': 1});
    check(first.get('browser-note')!.hasPendingWrites, 'durable local view');
    await first.close();
    first = await CosmosSyncClient.open(
      path: '$prefix-first',
      transport: transport(),
    );
    check(first.pending.length == 1, 'IndexedDB reopen outbox');
    final acknowledged = first.waitForPendingWrites();
    await first.flush();
    await acknowledged;
    check(!first.get('browser-note')!.hasPendingWrites, 'real Go ACK');
    second = await CosmosSyncClient.open(
      path: '$prefix-second',
      transport: transport(),
    );
    await second.sync(pageSize: 1);
    check(second.get('browser-note')!.data!['rank'] == 1, 'snapshot bootstrap');
    final savedCursor = second.cache.cursor;
    events = transport();
    await events.sessionInfo();
    final hint = await events.watchChanges().first.timeout(
      const Duration(seconds: 8),
    );
    check(hint.resumeId.isNotEmpty, 'authenticated browser SSE');
    check(
      second.cache.cursor == savedCursor,
      'hint cannot advance data cursor',
    );
    await first.put('browser-note', {'text': 'incremental', 'rank': 2});
    await first.flush();
    await second.sync();
    check(second.get('browser-note')!.data!['rank'] == 2, 'incremental resume');
    check(
      second.query(LocalQuery(limit: 2)).completeAtCursor != null,
      'query coverage after committed bootstrap',
    );
    await first.delete('browser-note');
    await first.flush();
    await second.sync();
    check(second.get('browser-note')!.deleted, 'browser tombstone');
    final operation = await first.put('browser-reload', {
      'text': 'survives page reload',
    });
    web.window.sessionStorage.setItem(
      'cosmosSyncRestore',
      jsonEncode({
        'first': '$prefix-first',
        'second': '$prefix-second',
        'operation': operation,
        'cursor': first.cache.cursor,
        'session': first.cache.consistencyToken,
      }),
    );
    web.window.location.assign('${web.window.location.origin}/?restore=1');
    // Unload owns cleanup; do not close the cache before the real page reload.
    await Completer<void>().future;
  } catch (_) {
    output.textContent = 'FAIL browser cross-stack contract';
  } finally {
    events?.close();
    await first?.close();
    await second?.close();
    await http.post(
      Uri.parse('${web.window.location.origin}/result'),
      body: output.textContent ?? 'FAIL missing result',
    );
  }
}

void check(bool condition, String context) {
  if (!condition) throw StateError(context);
}
