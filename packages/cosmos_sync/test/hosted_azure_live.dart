/// Explicit manual hosted test; no tokens are accepted in arguments or assets.
/// This target uses a recorded real API JWT and proves native Dart/SQLite, not
/// a fresh provider login, Flutter UI or multiple Container Apps replicas.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

Future<void> main() async {
  try {
    await run();
    stdout.writeln('COSMOS_SYNC_HOSTED_SDK_PASS sqlite=true hosted=true');
  } catch (_) {
    // Never print provider/server errors, JWTs, configuration or payloads.
    stderr.writeln('COSMOS_SYNC_HOSTED_SDK_FAILED');
    exitCode = 1;
  }
}

Future<void> run() async {
  final control = _Control(
    Uri.parse(Platform.environment['COSMOS_SYNC_HOSTED_CONTROL_URL'] ?? ''),
  );
  final fixture = await control.configuration();
  _check(fixture['protocolVersion'] == 1);
  final endpoint = Uri.parse(fixture['endpoint'] as String);
  final token = fixture['accessToken'] as String;
  final id = fixture['documentId'] as String;
  final directory = Directory(fixture['cacheDirectory'] as String);
  await directory.create(recursive: true);
  CosmosSyncClient? writer;
  CosmosSyncClient? peer;
  StreamSubscription<ChangeHint>? hintSubscription;
  StreamSubscription<DocumentSnapshot?>? watchSubscription;
  var networkAllowed = true;
  HttpSyncTransport transport() => HttpSyncTransport(
    baseUri: endpoint,
    tokenProvider: () async => token,
    requestTimeout: const Duration(seconds: 15),
    client: _BoundedClient(endpoint, control, () => networkAllowed),
  );
  void checkDocument(CosmosSyncClient client, String value) {
    final document = client.get(id);
    _check(
      document != null &&
          !document.deleted &&
          !document.hasPendingWrites &&
          document.data?['value'] == value,
    );
  }

  try {
    writer = await CosmosSyncClient.open(
      path: '${directory.path}/writer.sqlite',
      transport: transport(),
    );
    await writer.sync(maxPages: 4);
    _check(writer.query(LocalQuery()).metadata.bootstrapComplete);
    await control.stage('session_bootstrapped');

    networkAllowed = false;
    final operation = await writer.put(id, {
      'fixture': 'bounded-hosted-validation',
      'value': 'offline-create',
    });
    _check(writer.get(id)!.hasPendingWrites);
    _check(writer.pending.single.operationId == operation);
    await control.stage('offline_write_durable');
    await writer.close();
    writer = await CosmosSyncClient.open(
      path: '${directory.path}/writer.sqlite',
      transport: transport(),
    );
    _check(writer.pending.single.operationId == operation);
    _check(writer.get(id)!.data?['value'] == 'offline-create');
    await control.stage('offline_cache_reopened');

    networkAllowed = true;
    final acknowledged = writer.waitForPendingWrites();
    final created = await writer.flush(maxOperations: 1);
    _check(created.acknowledged == 1 && created.remaining == 0);
    await acknowledged;
    checkDocument(writer, 'offline-create');
    await control.stage('create_acknowledged');

    final peerTransport = transport();
    peer = await CosmosSyncClient.open(
      path: '${directory.path}/peer.sqlite',
      transport: peerTransport,
    );
    await peer.sync(maxPages: 4);
    checkDocument(peer, 'offline-create');
    await control.stage('peer_received_create');
    final staleOperation = await peer.put(id, {
      'fixture': 'bounded-hosted-validation',
      'value': 'stale-peer-edit',
    });
    final hint = Completer<void>();
    hintSubscription = peerTransport
        .watchChanges(cursor: peer.cache.cursor)
        .listen(
          (_) {
            if (!hint.isCompleted) hint.complete();
          },
          onError: (Object _) {
            if (!hint.isCompleted) {
              hint.completeError(StateError('Hosted change hint failed.'));
            }
          },
        );
    final hintReady = hint.future.timeout(const Duration(seconds: 20));
    // Install an immediate listener so an early transport error stays bounded
    // and is observed by the later assertion, without an unhandled async error.
    unawaited(hintReady.catchError((Object _) {}));
    await writer.put(id, {
      'fixture': 'bounded-hosted-validation',
      'value': 'online-update',
    });
    final updated = await writer.flush(maxOperations: 1);
    _check(updated.acknowledged == 1 && updated.remaining == 0);
    checkDocument(writer, 'online-update');
    await control.stage('update_acknowledged');
    await hintReady;
    await hintSubscription.cancel();
    hintSubscription = null;
    await control.stage('server_hint_received');
    final conflicted = await peer.flush(maxOperations: 1);
    _check(conflicted.acknowledged == 0 && conflicted.remaining == 1);
    _check(peer.pending.single.state == MutationState.conflict);
    _check(peer.pending.single.errorCode == 'conflict');
    _check(peer.get(id)!.hasConflict);
    await control.stage('stale_write_conflicted');
    await peer.discard(staleOperation);
    _check(peer.pending.isEmpty);
    checkDocument(peer, 'online-update');
    await control.stage('server_version_chosen');
    await peer.sync(maxPages: 4);
    checkDocument(peer, 'online-update');
    await control.stage('remote_update_synchronized');
    // A fresh watcher cannot be satisfied by the earlier 409/discard. This
    // peer's tombstone can arrive only through the next durable remote sync.
    final remoteTombstone = Completer<void>();
    watchSubscription = peer.watch(id).listen((document) {
      if (document?.deleted == true &&
          document?.hasPendingWrites == false &&
          !remoteTombstone.isCompleted) {
        remoteTombstone.complete();
      }
    });

    await writer.delete(id);
    final deleted = await writer.flush(maxOperations: 1);
    _check(deleted.acknowledged == 1 && deleted.remaining == 0);
    _check(writer.get(id)!.deleted && !writer.get(id)!.hasPendingWrites);
    await control.stage('delete_acknowledged');
    await peer.sync(maxPages: 4);
    await remoteTombstone.future.timeout(const Duration(seconds: 2));
    _check(peer.get(id)!.deleted && !peer.get(id)!.hasPendingWrites);
    await control.stage('remote_tombstone_watched');
    await writer.close();
    writer = await CosmosSyncClient.open(
      path: '${directory.path}/writer.sqlite',
      transport: transport(),
    );
    await writer.sync(maxPages: 4);
    _check(writer.pending.isEmpty && writer.get(id)!.deleted);
    await control.stage('cache_reopened_with_tombstone');
  } finally {
    await hintSubscription?.cancel();
    await watchSubscription?.cancel();
    await peer?.close();
    await writer?.close();
    // Leave the private SQLite evidence and retained server tombstone in place.
  }
}

void _check(bool condition) {
  if (!condition) throw StateError('Hosted SDK assertion failed.');
}

class _BoundedClient extends http.BaseClient {
  _BoundedClient(this.origin, this.control, this.networkAllowed)
    : inner = IOClient(
        HttpClient()..connectionTimeout = const Duration(seconds: 10),
      );
  final Uri origin;
  final _Control control;
  final bool Function() networkAllowed;
  final IOClient inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!networkAllowed() ||
        request.url.scheme != 'https' ||
        request.url.origin != origin.origin ||
        request.url.userInfo.isNotEmpty ||
        request.url.hasFragment ||
        request.url.queryParameters.keys.any(
          (name) => !{'scope', 'cursor', 'limit'}.contains(name),
        )) {
      throw StateError('Only the approved hosted HTTPS request is allowed.');
    }
    request.followRedirects = false;
    final permit = await control.permit(
      request.method,
      request.url.path,
      request.url.origin,
    );
    final attempt = permit['mutationAttempt'] as int?;
    if (attempt == null) return inner.send(request);
    try {
      final response = await inner.send(request);
      final body = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 15),
      )) {
        body.addAll(chunk);
        if (body.length > 1024 * 1024) {
          throw StateError('Hosted mutation response exceeds its bound.');
        }
      }
      if (response.statusCode != 200 && response.statusCode != 409) {
        throw StateError(
          'Hosted mutation did not complete the expected outcome.',
        );
      }
      await control.result(
        attempt,
        response.statusCode == 200 ? 'accepted' : 'conflict',
      );
      return http.StreamedResponse(
        Stream.value(body),
        response.statusCode,
        headers: response.headers,
        request: response.request,
      );
    } catch (_) {
      await control.result(attempt, 'unknown');
      rethrow;
    }
  }

  @override
  void close() => inner.close();
}

class _Control {
  _Control(this.base) {
    if (base.scheme != 'http' ||
        base.host != '127.0.0.1' ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        !base.path.endsWith('/') ||
        base.pathSegments.where((part) => part.isNotEmpty).length != 1) {
      throw StateError('Use the approved private hosted runner.');
    }
  }
  final Uri base;
  Future<Map<String, Object?>> configuration() => _request('GET', 'config');
  Future<void> stage(String stage) async =>
      _request('POST', 'stage', {'stage': stage});
  Future<Map<String, Object?>> permit(
    String method,
    String path,
    String origin,
  ) => _request('POST', 'permit', {
    'method': method,
    'path': path,
    'origin': origin,
  });
  Future<void> result(int attempt, String outcome) async => _request(
    'POST',
    'result',
    {'mutationAttempt': attempt, 'outcome': outcome},
  );

  Future<Map<String, Object?>> _request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.openUrl(method, base.resolve(path));
      request.followRedirects = false;
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (response.statusCode != 200) {
        throw StateError('Private hosted control refused the operation.');
      }
      final chunks = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 5))) {
        chunks.addAll(chunk);
        if (chunks.length > 32768) {
          throw StateError(
            'Private hosted control exceeded its response bound.',
          );
        }
      }
      return (jsonDecode(utf8.decode(chunks)) as Map).cast<String, Object?>();
    } finally {
      client.close(force: true);
    }
  }
}
