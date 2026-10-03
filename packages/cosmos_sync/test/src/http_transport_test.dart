import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cosmos_sync/src/http_transport.dart';
import 'package:cosmos_sync/src/models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_parser/http_parser.dart';
import 'package:test/test.dart';

const _document = {
  'id': 'note-1',
  'data': {'title': '日本語'},
  'version': 7,
  'deleted': false,
};

MutationRequest _mutation() => MutationRequest(
  operationId: '119acde0-d037-4979-8e2e-2e68ba11531d',
  documentId: 'note-1',
  kind: MutationKind.put,
  data: {'title': '日本語'},
  baseVersion: 6,
);

http.Response _json(
  Object? body, {
  int status = 200,
  Map<String, String>? headers,
}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8', ...?headers},
);

HttpSyncTransport _transport(
  Future<http.Response> Function(http.Request) handler, {
  Future<String> Function()? tokenProvider,
  Uri? baseUri,
  Duration requestTimeout = const Duration(seconds: 30),
}) => HttpSyncTransport(
  baseUri: baseUri ?? Uri.parse('https://sync.example.test'),
  tokenProvider: tokenProvider ?? () async => 'test-access-token',
  client: MockClient(handler),
  requestTimeout: requestTimeout,
);

Future<HttpSyncTransport> _readyTransport(
  Future<http.Response> Function(http.Request) handler, {
  Future<String> Function()? tokenProvider,
  Duration requestTimeout = const Duration(seconds: 30),
}) async {
  final transport = _transport(
    (request) async => request.url.path.endsWith('/session')
        ? _json({'scopeId': 'scope', 'permissionVersion': '1'})
        : handler(request),
    tokenProvider: tokenProvider,
    requestTimeout: requestTimeout,
  );
  await transport.sessionInfo();
  return transport;
}

void main() {
  group('endpoint security', () {
    test('requires HTTPS except opted-in exact loopback hosts', () {
      for (final url in [
        'http://sync.example.test',
        'http://localhost',
        'ftp://localhost',
        'https://name:password@example.test',
        'https://example.test?token=x',
        'https://example.test#fragment',
        '/relative',
      ]) {
        expect(
          () => HttpSyncTransport(
            baseUri: Uri.parse(url),
            tokenProvider: () async => 'token',
          ),
          throwsArgumentError,
          reason: url,
        );
      }
      for (final host in ['localhost', '127.0.0.1', '[::1]']) {
        final transport = HttpSyncTransport(
          baseUri: Uri.parse('http://$host:8080'),
          tokenProvider: () async => 'token',
          allowInsecureLocalhost: true,
        );
        transport.close();
      }
      for (final host in ['localhost.evil.test', '127.0.0.2', '192.168.1.1']) {
        expect(
          () => HttpSyncTransport(
            baseUri: Uri.parse('http://$host'),
            tokenProvider: () async => 'token',
            allowInsecureLocalhost: true,
          ),
          throwsArgumentError,
        );
      }
    });

    test('rejects zero request timeout', () {
      expect(
        () => _transport((_) async => _json({}), requestTimeout: Duration.zero),
        throwsArgumentError,
      );
    });

    test('rejects header injection in restored consistency token', () {
      final transport = _transport((_) async => _json({}));
      addTearDown(transport.close);
      for (final value in ['', 'opaque\r\nAuthorization: bad']) {
        expect(() => transport.consistencyToken = value, throwsArgumentError);
      }
    });
  });

  group('wire requests', () {
    test(
      'requires a verified scope before sending writes or syncing',
      () async {
        var calls = 0;
        final transport = _transport((_) async {
          calls++;
          return _json({});
        });
        addTearDown(transport.close);
        await expectLater(transport.mutate(_mutation()), throwsStateError);
        await expectLater(transport.sync(), throwsStateError);
        expect(calls, 0);
      },
    );

    test('binds a changed access token to the last verified scope', () async {
      var tokens = 0;
      final transport = _transport((request) async {
        if (request.url.path.endsWith('/session')) {
          expect(request.headers['Authorization'], 'Bearer token-a');
          return _json({
            'scopeId': 'scope-a',
            'permissionVersion': 'revision-a',
          });
        }
        expect(request.headers['Authorization'], 'Bearer token-b');
        expect(request.headers['X-Cosmos-Sync-Scope'], 'scope-a');
        expect(request.headers['X-Cosmos-Sync-Permission'], 'revision-a');
        return _json({'code': 'scope_changed'}, status: 403);
      }, tokenProvider: () async => tokens++ == 0 ? 'token-a' : 'token-b');
      addTearDown(transport.close);
      await transport.sessionInfo();
      await expectLater(
        transport.mutate(_mutation()),
        throwsA(
          isA<TransportException>().having(
            (e) => e.code,
            'code',
            'scope_changed',
          ),
        ),
      );
    });

    test('captures request scope before awaiting a token refresh', () async {
      final stalledToken = Completer<String>();
      final tokenStarted = Completer<void>();
      var tokens = 0;
      var sessions = 0;
      final transport = _transport(
        (request) async {
          if (request.url.path.endsWith('/session')) {
            return _json({
              'scopeId': sessions++ == 0 ? 'scope-a' : 'scope-b',
              'permissionVersion': '1',
            });
          }
          expect(request.headers['X-Cosmos-Sync-Scope'], 'scope-a');
          expect(request.headers['X-Cosmos-Sync-Session'], 'old-envelope');
          return _json(
            {'document': _document},
            headers: {'X-Cosmos-Sync-Session': 'old-response-envelope'},
          );
        },
        tokenProvider: () {
          if (tokens++ == 1) {
            tokenStarted.complete();
            return stalledToken.future;
          }
          return Future.value('access-token');
        },
      );
      addTearDown(transport.close);
      await transport.sessionInfo();
      transport.consistencyToken = 'old-envelope';
      final mutation = transport.mutate(_mutation());
      await tokenStarted.future;
      await transport.sessionInfo();
      transport.consistencyToken = 'new-scope-envelope';
      stalledToken.complete('refreshed-access-token');
      await mutation;
      expect(transport.consistencyToken, 'new-scope-envelope');
    });

    test('fetches fresh tokens and keeps a base path prefix', () async {
      var tokens = 0;
      final transport = _transport(
        (request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/session');
          expect(request.headers['Authorization'], 'Bearer token-$tokens');
          expect(request.headers['Accept'], 'application/json');
          expect(request.followRedirects, isFalse);
          expect(request.headers.containsKey('X-Cosmos-Sync-Session'), isFalse);
          return _json({'scopeId': 'scope', 'permissionVersion': 'revision-1'});
        },
        baseUri: Uri.parse('https://sync.example.test/api/'),
        tokenProvider: () async => 'token-${++tokens}',
      );
      addTearDown(transport.close);
      final first = await transport.sessionInfo();
      final second = await transport.sessionInfo();
      expect(first.scopeId, 'scope');
      expect(second.permissionVersion, 'revision-1');
      expect(tokens, 2);
    });

    test('sends the exact durable mutation and parses its document', () async {
      final mutation = _mutation();
      var requests = 0;
      final transport = await _readyTransport((request) async {
        requests++;
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/mutations');
        expect(
          request.headers['Content-Type'],
          'application/json; charset=utf-8',
        );
        expect(jsonDecode(request.body), mutation.toJson());
        return _json({'document': _document});
      });
      addTearDown(transport.close);
      final document = await transport.mutate(mutation);
      expect(document.id, 'note-1');
      expect(document.data, {'title': '日本語'});
      expect(document.version, 7);
      expect(requests, 1);
    });

    test('encodes cursor opaquely and omits it on initial sync', () async {
      var requests = 0;
      const cursor = 'opaque+/= &?日本語';
      final transport = await _readyTransport((request) async {
        requests++;
        expect(request.url.path, '/v1/sync');
        expect(request.url.queryParameters['limit'], '17');
        expect(
          request.url.queryParameters['cursor'],
          requests == 1 ? null : cursor,
        );
        return _json({
          'changes': [_document],
          'cursor': cursor,
          'hasMore': true,
        });
      });
      addTearDown(transport.close);
      await transport.sync(limit: 17);
      final page = await transport.sync(cursor: cursor, limit: 17);
      expect(page.cursor, cursor);
      expect(page.hasMore, isTrue);
      expect(page.changes.single.version, 7);
      await expectLater(transport.sync(limit: 0), throwsArgumentError);
      expect(requests, 2);
    });

    test(
      'forwards opaque consistency token only on mutation and sync',
      () async {
        final transport = _transport((request) async {
          if (request.url.path.endsWith('/session')) {
            expect(
              request.headers.containsKey('X-Cosmos-Sync-Session'),
              isFalse,
            );
            return _json({'scopeId': 'scope', 'permissionVersion': '1'});
          }
          if (request.url.path.endsWith('/mutations')) {
            expect(
              request.headers['X-Cosmos-Sync-Session'],
              'restored-envelope',
            );
            return _json(
              {'document': _document},
              headers: {'x-cosmos-sync-session': 'new-envelope'},
            );
          }
          expect(request.headers['X-Cosmos-Sync-Session'], 'new-envelope');
          return _json({
            'changes': <Object?>[],
            'cursor': 'next',
            'hasMore': false,
          });
        });
        addTearDown(transport.close);
        transport.consistencyToken = 'restored-envelope';
        await transport.sessionInfo();
        await transport.mutate(_mutation());
        expect(transport.consistencyToken, 'new-envelope');
        await transport.sync();
        expect(transport.consistencyToken, 'new-envelope');
      },
    );

    test(
      'clears consistency token after a scope or permission change',
      () async {
        var calls = 0;
        final transport = _transport((_) async {
          calls++;
          return _json({
            'scopeId': calls < 4 ? 'scope-a' : 'scope-b',
            'permissionVersion': calls < 3 ? '1' : '2',
          });
        });
        addTearDown(transport.close);
        await transport.sessionInfo();
        transport.consistencyToken = 'saved';
        await transport.sessionInfo();
        expect(transport.consistencyToken, 'saved');
        await transport.sessionInfo();
        expect(transport.consistencyToken, isNull);
        transport.consistencyToken = 'saved-again';
        await transport.sessionInfo();
        expect(transport.consistencyToken, isNull);
      },
    );
  });

  group('error handling', () {
    for (final status in [400, 401, 403, 410, 429, 500, 503]) {
      test('classifies HTTP $status without retrying internally', () async {
        var calls = 0;
        final transport = await _readyTransport((_) async {
          calls++;
          return _json(
            {'code': status == 410 ? 'resync_required' : 'server_code'},
            status: status,
            headers: {'retry-after': '12'},
          );
        });
        addTearDown(transport.close);
        transport.consistencyToken = 'saved';
        await expectLater(
          transport.sync(),
          throwsA(
            isA<TransportException>()
                .having((e) => e.statusCode, 'status', status)
                .having(
                  (e) => e.retryable,
                  'retryable',
                  status == 429 || status >= 500,
                )
                .having(
                  (e) => e.authorizationFailure,
                  'auth',
                  status == 401 || status == 403,
                )
                .having(
                  (e) => e.retryAfter,
                  'retry-after',
                  const Duration(seconds: 12),
                ),
          ),
        );
        expect(calls, 1);
        expect(
          transport.consistencyToken,
          status == 401 || status == 403 ? null : 'saved',
        );
      });
    }

    test('exposes conflict current document and idempotency errors', () async {
      var calls = 0;
      final transport = await _readyTransport((_) async {
        return _json(
          ++calls == 1
              ? {'code': 'conflict', 'current': _document}
              : {'code': 'idempotency_mismatch'},
          status: 409,
        );
      });
      addTearDown(transport.close);
      await expectLater(
        transport.mutate(_mutation()),
        throwsA(
          isA<TransportException>()
              .having((e) => e.code, 'code', 'conflict')
              .having((e) => e.current?.version, 'current version', 7)
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
      await expectLater(
        transport.mutate(_mutation()),
        throwsA(
          isA<TransportException>()
              .having((e) => e.code, 'code', 'idempotency_mismatch')
              .having((e) => e.current, 'current', null),
        ),
      );
    });

    test(
      'preserves retryable HTTP status when an intermediary sends HTML',
      () async {
        final transport = await _readyTransport(
          (_) async => http.Response('<html>down</html>', 502),
        );
        addTearDown(transport.close);
        await expectLater(
          transport.sync(),
          throwsA(
            isA<TransportException>()
                .having((e) => e.code, 'code', 'http_error')
                .having((e) => e.statusCode, 'status', 502)
                .having((e) => e.retryable, 'retryable', true),
          ),
        );
      },
    );

    test('parses HTTP-date Retry-After and clamps past dates', () async {
      var calls = 0;
      final transport = await _readyTransport(
        (_) async => _json(
          {'code': 'busy'},
          status: 429,
          headers: {
            'Retry-After': calls++ == 0
                ? formatHttpDate(
                    DateTime.now().toUtc().add(const Duration(minutes: 1)),
                  )
                : 'Sun, 06 Nov 1994 08:49:37 GMT',
          },
        ),
      );
      addTearDown(transport.close);
      await expectLater(
        transport.sync(),
        throwsA(
          isA<TransportException>().having(
            (e) => e.retryAfter?.inSeconds,
            'date delay',
            inInclusiveRange(58, 60),
          ),
        ),
      );
      await expectLater(
        transport.sync(),
        throwsA(
          isA<TransportException>().having(
            (e) => e.retryAfter,
            'past date',
            Duration.zero,
          ),
        ),
      );
    });

    test('ignores invalid or negative Retry-After', () async {
      var calls = 0;
      final transport = await _readyTransport(
        (_) async => _json(
          {'code': 'busy'},
          status: 429,
          headers: {'retry-after': calls++ == 0 ? '-1' : 'tomorrow'},
        ),
      );
      addTearDown(transport.close);
      for (var i = 0; i < 2; i++) {
        await expectLater(
          transport.sync(),
          throwsA(
            isA<TransportException>().having(
              (e) => e.retryAfter,
              'delay',
              null,
            ),
          ),
        );
      }
    });

    test('keeps unknown successful mutation outcomes retryable', () async {
      for (final body in [
        'not-json',
        '[]',
        '{"document":{"id":"missing-fields"}}',
      ]) {
        final transport = await _readyTransport(
          (_) async => http.Response(body, 200),
        );
        addTearDown(transport.close);
        await expectLater(
          transport.mutate(_mutation()),
          throwsA(
            isA<TransportException>()
                .having((e) => e.code, 'code', 'invalid_response')
                .having((e) => e.retryable, 'retryable', true),
          ),
        );
      }
    });

    test('wraps network failure without exposing exception secrets', () async {
      final transport = await _readyTransport(
        (_) async => throw http.ClientException('secret-access-token'),
      );
      addTearDown(transport.close);
      await expectLater(
        transport.sync(),
        throwsA(
          isA<TransportException>()
              .having((e) => e.statusCode, 'status', null)
              .having((e) => e.code, 'code', 'network_error')
              .having(
                (e) => e.toString(),
                'safe message',
                isNot(contains('secret')),
              ),
        ),
      );
    });

    test('does not send after a timed-out token provider completes', () async {
      final token = Completer<String>();
      var requests = 0;
      var tokenCalls = 0;
      final transport = await _readyTransport(
        (_) async {
          requests++;
          return _json({
            'changes': <Object?>[],
            'cursor': 'next',
            'hasMore': false,
          });
        },
        tokenProvider: () =>
            tokenCalls++ == 0 ? Future.value('initial-token') : token.future,
        requestTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(transport.close);
      await expectLater(
        transport.sync(),
        throwsA(
          isA<TransportException>().having((e) => e.code, 'code', 'timeout'),
        ),
      );
      token.complete('late-token');
      await Future<void>.delayed(Duration.zero);
      expect(requests, 0);
    });

    test(
      'rejects requests larger than the transport bound before sending',
      () async {
        var requests = 0;
        final transport = await _readyTransport((_) async {
          requests++;
          return _json({'document': _document});
        });
        addTearDown(transport.close);
        final oversized = MutationRequest(
          operationId: 'operation',
          documentId: 'note-1',
          kind: MutationKind.put,
          data: {'text': 'x' * (32 * 1024 * 1024)},
          baseVersion: 0,
        );
        await expectLater(
          transport.mutate(oversized),
          throwsA(
            isA<TransportException>().having(
              (e) => e.code,
              'code',
              'request_too_large',
            ),
          ),
        );
        expect(requests, 0);
      },
    );

    test('bounds response stream before JSON parsing', () async {
      final transport = HttpSyncTransport(
        baseUri: Uri.parse('https://sync.example.test'),
        tokenProvider: () async => 'token',
        client: MockClient.streaming(
          (request, _) async => request.url.path.endsWith('/session')
              ? http.StreamedResponse(
                  Stream.value(
                    utf8.encode(
                      jsonEncode({
                        'scopeId': 'scope',
                        'permissionVersion': '1',
                      }),
                    ),
                  ),
                  200,
                )
              : http.StreamedResponse(
                  Stream.fromIterable([
                    Uint8List(32 * 1024 * 1024),
                    [32],
                  ]),
                  200,
                ),
        ),
      );
      addTearDown(transport.close);
      await transport.sessionInfo();
      await expectLater(
        transport.sync(),
        throwsA(
          isA<TransportException>().having(
            (e) => e.code,
            'code',
            'response_too_large',
          ),
        ),
      );
    });

    test('rejects use after close and close is idempotent', () async {
      final transport = await _readyTransport((_) async => _json({}));
      transport.close();
      transport.close();
      await expectLater(transport.sync(), throwsStateError);
    });
  });
}
