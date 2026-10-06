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

import 'support/recorded_data_journey.dart';

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
  final control = HostedManualControl(
    Uri.parse(Platform.environment['COSMOS_SYNC_HOSTED_CONTROL_URL'] ?? ''),
  );
  final fixture = await control.configuration();
  _check(fixture['protocolVersion'] == 1);
  final endpoint = Uri.parse(fixture['endpoint'] as String);
  final token = fixture['accessToken'] as String;
  final id = fixture['documentId'] as String;
  final directory = Directory(fixture['cacheDirectory'] as String);
  await RecordedDataJourney(
    directory: directory,
    documentId: id,
    stage: control.stage,
    transportFactory: (allowed, _) => HttpSyncTransport(
      baseUri: endpoint,
      tokenProvider: () async => token,
      requestTimeout: const Duration(seconds: 15),
      client: HostedBudgetClient(endpoint, control, allowed),
    ),
  ).run();
}

void _check(bool condition) {
  if (!condition) throw StateError('Hosted SDK assertion failed.');
}

class HostedBudgetClient extends http.BaseClient {
  HostedBudgetClient(this.origin, this.control, this.networkAllowed)
    : inner = IOClient(
        HttpClient()..connectionTimeout = const Duration(seconds: 10),
      );
  final Uri origin;
  final HostedManualControl control;
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

class HostedManualControl {
  HostedManualControl(this.base) {
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
