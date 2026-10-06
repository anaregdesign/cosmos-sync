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
  jsonEncode(
    body is Map && body.containsKey('scopeId')
        ? <Object?, Object?>{
            'principalId': 'principal',
            'scopeMode': 'user',
            ...body,
          }
        : body,
  ),
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

class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
  @override
  void close() {}
}

Future<HttpSyncTransport> _streamTransport(
  Future<http.StreamedResponse> Function(http.BaseRequest) handler, {
  Future<String> Function()? tokenProvider,
  Duration requestTimeout = const Duration(seconds: 30),
}) async {
  final transport = HttpSyncTransport(
    baseUri: Uri.parse('https://sync.example.test/api'),
    tokenProvider: tokenProvider ?? () async => 'fresh-token',
    requestTimeout: requestTimeout,
    client: _StreamClient(
      (request) async => request.url.path.endsWith('/session')
          ? http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  jsonEncode({
                    'scopeId': 'scope',
                    'principalId': 'principal',
                    'permissionVersion': '1',
                    'scopeMode': 'user',
                  }),
                ),
              ),
              200,
            )
          : handler(request),
    ),
  );
  await transport.sessionInfo();
  return transport;
}

http.StreamedResponse _sse(String text, {String type = 'text/event-stream'}) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(text)),
      200,
      headers: {'content-type': type},
    );

String _hint(String id) => 'id: $id\nevent: change\ndata: {"cursor":"$id"}\n\n';

void main() {
  group('identity-bound transport', () {
    final identity = 'a' * 64;
    Map<String, Object?> session(int generation) => {
      'scopeId': 'scope',
      'principalId': 'principal',
      'permissionVersion': '2',
      'scopeMode': 'user',
      'identityGeneration': generation,
      'identityId': identity,
    };

    test(
      'binds mutation, sync and snapshot without composing permission',
      () async {
        final transport = _transport((request) async {
          if (request.url.path == '/v1/session') return _json(session(10000));
          expect(request.headers['X-Cosmos-Sync-Permission'], '2');
          expect(request.headers['X-Cosmos-Sync-Identity-Generation'], '10000');
          expect(request.headers['X-Cosmos-Sync-Identity'], identity);
          return switch (request.url.path) {
            '/v1/mutations' => _json({'document': _document}),
            '/v1/snapshot' => _json({
              'documents': [_document],
              'cursor': 'snapshot',
              'syncCursor': 'sync',
              'cutoverSequence': 7,
              'hasMore': false,
            }),
            _ => _json({
              'changes': <Object?>[],
              'cursor': 'sync',
              'hasMore': false,
            }),
          };
        });
        addTearDown(transport.close);
        final verified = await transport.sessionInfo();
        expect(verified.identityGeneration, 10000);
        expect(verified.permissionVersion, '2');
        await transport.mutate(_mutation());
        await transport.sync();
        await transport.snapshot();
      },
    );

    test(
      'new generation clears consistency and ignores an old in-flight envelope',
      () async {
        var generation = 1;
        final entered = Completer<void>();
        final reply = Completer<http.Response>();
        final transport = _transport((request) async {
          if (request.url.path == '/v1/session') {
            return _json(session(generation));
          }
          entered.complete();
          return reply.future;
        });
        addTearDown(transport.close);
        await transport.sessionInfo();
        transport.consistencyToken = 'original';
        final pending = transport.sync();
        await entered.future;
        generation = 2;
        await transport.sessionInfo();
        expect(transport.consistencyToken, isNull);
        reply.complete(
          _json(
            {'changes': <Object?>[], 'cursor': 'old-cursor', 'hasMore': false},
            headers: {'X-Cosmos-Sync-Session': 'stale-envelope'},
          ),
        );
        await pending;
        expect(transport.consistencyToken, isNull);
      },
    );

    test(
      'SSE binds identity and classifies learned unlink as authorization loss',
      () async {
        final transport = HttpSyncTransport(
          baseUri: Uri.parse('https://sync.example.test'),
          tokenProvider: () async => 'api-token',
          client: _StreamClient((request) async {
            if (request.url.path == '/v1/session') {
              return http.StreamedResponse(
                Stream.value(utf8.encode(jsonEncode(session(1)))),
                200,
              );
            }
            expect(request.headers['X-Cosmos-Sync-Identity-Generation'], '1');
            expect(request.headers['X-Cosmos-Sync-Identity'], identity);
            return _sse(
              'event: error\ndata: {"code":"identity_session_invalid"}\n\n',
            );
          }),
        );
        addTearDown(transport.close);
        await transport.sessionInfo();
        transport.consistencyToken = 'before';
        await expectLater(
          transport.watchChanges(),
          emitsError(
            isA<TransportException>().having(
              (error) => error.authorizationFailure,
              'authorization failure',
              isTrue,
            ),
          ),
        );
        expect(transport.consistencyToken, isNull);
      },
    );

    test(
      'rejects malformed server identity metadata before data requests',
      () async {
        for (final generation in [0, -1, 10001, '1', 1.5]) {
          var requests = 0;
          final transport = _transport((_) async {
            requests++;
            return _json({...session(1), 'identityGeneration': generation});
          });
          addTearDown(transport.close);
          await expectLater(
            transport.sessionInfo(),
            throwsA(
              isA<TransportException>().having(
                (error) => error.code,
                'code',
                'invalid_response',
              ),
            ),
          );
          expect(requests, 1);
        }
      },
    );
  });

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

  group('snapshot pages', () {
    test(
      'binds authorization and preserves separate cutover/sync cursors',
      () async {
        final transport = await _readyTransport((request) async {
          expect(request.url.path, '/v1/snapshot');
          expect(request.url.queryParameters, {
            'cursor': 'snapshot-resume',
            'limit': '1',
          });
          expect(request.headers['X-Cosmos-Sync-Scope'], 'scope');
          expect(request.headers['X-Cosmos-Sync-Principal'], 'principal');
          expect(request.headers['X-Cosmos-Sync-Scope-Mode'], 'user');
          expect(request.headers['X-Cosmos-Sync-Permission'], '1');
          expect(request.headers['X-Cosmos-Sync-Session'], 'before');
          return _json(
            {
              'documents': [_document],
              'cursor': 'snapshot-next',
              'syncCursor': 'durable-sync',
              'cutoverSequence': 7,
              'hasMore': false,
            },
            headers: {'X-Cosmos-Sync-Session': 'after'},
          );
        });
        addTearDown(transport.close);
        transport.consistencyToken = 'before';
        final page = await transport.snapshot(
          cursor: 'snapshot-resume',
          limit: 1,
        );
        expect(page.cursor, 'snapshot-next');
        expect(page.syncCursor, 'durable-sync');
        expect(page.cutoverSequence, 7);
        expect(page.documents.single.version, 7);
        expect(transport.consistencyToken, 'after');
      },
    );

    test(
      'rejects malformed numeric/cursor and inconsistent snapshot pages',
      () async {
        final valid = <String, Object?>{
          'documents': [_document],
          'cursor': 'snapshot',
          'syncCursor': 'sync',
          'cutoverSequence': 7,
          'hasMore': false,
        };
        for (final changes in <Map<String, Object?>>[
          {'cutoverSequence': -1},
          {'cutoverSequence': 7.5},
          {'cutoverSequence': 9007199254740992},
          {'cutoverSequence': 6},
          {'cursor': ''},
          {'syncCursor': '\nmalformed'},
          {
            'documents': [
              {..._document, 'version': 7.5},
            ],
          },
          {
            'documents': [_document, _document],
          },
          {'documents': [], 'hasMore': true},
        ]) {
          final transport = await _readyTransport(
            (_) async => _json(
              {...valid, ...changes},
              headers: {'X-Cosmos-Sync-Session': 'must-not-accept'},
            ),
          );
          addTearDown(transport.close);
          transport.consistencyToken = 'before';
          await expectLater(
            transport.snapshot(),
            throwsA(
              isA<TransportException>().having(
                (e) => e.code,
                'code',
                'invalid_response',
              ),
            ),
          );
          expect(transport.consistencyToken, 'before');
        }
      },
    );

    test(
      'rejects unsupported limits and snapshot before session binding',
      () async {
        final transport = _transport((_) async => _json({}));
        addTearDown(transport.close);
        await expectLater(transport.snapshot(), throwsStateError);
        for (final limit in [0, 101]) {
          await expectLater(
            transport.snapshot(limit: limit),
            throwsArgumentError,
          );
        }
      },
    );
  });

  group('change hint streaming', () {
    test(
      'uses fresh Bearer and every scope assertion; separates hint resume',
      () async {
        var calls = 0;
        var tokens = 0;
        final transport = await _streamTransport((request) async {
          calls++;
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/events');
          expect(
            request.headers['Authorization'],
            'Bearer token-${tokens - 1}',
          );
          expect(request.headers['Accept'], 'text/event-stream');
          expect(request.headers['X-Cosmos-Sync-Scope'], 'scope');
          expect(request.headers['X-Cosmos-Sync-Principal'], 'principal');
          expect(request.headers['X-Cosmos-Sync-Scope-Mode'], 'user');
          expect(request.headers['X-Cosmos-Sync-Permission'], '1');
          expect(
            request.headers['X-Cosmos-Sync-Session'],
            'authoritative-envelope',
          );
          expect(request.followRedirects, false);
          if (calls == 1) {
            expect(request.url.queryParameters, {'cursor': 'durable-cursor'});
            expect(request.headers.containsKey('Last-Event-ID'), false);
          } else {
            expect(request.url.query, '');
            expect(request.headers['Last-Event-ID'], 'hint-resume');
          }
          return _sse(_hint('hint-resume'));
        }, tokenProvider: () async => 'token-${tokens++}');
        addTearDown(transport.close);
        transport.consistencyToken = 'authoritative-envelope';
        expect(
          (await transport.watchChanges(cursor: 'durable-cursor').toList())
              .single
              .resumeId,
          'hint-resume',
        );
        await transport
            .watchChanges(lastEventId: 'hint-resume', cursor: 'durable-cursor')
            .toList();
        expect(tokens, 3);
        expect(calls, 2); // Transport does not silently reconnect.
      },
    );

    test(
      'parses fragmented UTF-8 CRLF multiline data and ignores heartbeat',
      () async {
        const source =
            '\uFEFF: connected\r\n\r\nid: hint-日本語\r\nevent: change\r\n'
            'data: {"cursor":\r\ndata: "hint-日本語", "session":"older-envelope"}\r\n\r\n'
            ': heartbeat\r\n\r\n';
        final transport = await _streamTransport(
          (_) async => http.StreamedResponse(
            Stream.fromIterable(utf8.encode(source).map((byte) => [byte])),
            200,
            headers: {'content-type': 'TEXT/EVENT-STREAM; charset=utf-8'},
          ),
        );
        addTearDown(transport.close);
        transport.consistencyToken = 'newer-ack-envelope';
        final hints = await transport.watchChanges().toList();
        expect(hints.single.resumeId, 'hint-日本語');
        expect(hints.single.consistencyToken, 'older-envelope');
        expect(transport.consistencyToken, 'newer-ack-envelope');
      },
    );

    test('supports bare CR separators', () async {
      final transport = await _streamTransport(
        (_) async => _sse(_hint('one').replaceAll('\n', '\r')),
      );
      addTearDown(transport.close);
      expect((await transport.watchChanges().toList()).single.resumeId, 'one');
    });

    test(
      'maps auth resync throttle and store error events to typed status',
      () async {
        for (final entry in {
          'unauthorized': 401,
          'forbidden': 403,
          'resync_required': 410,
          'rate_limited': 429,
          'store_unavailable': 503,
        }.entries) {
          final transport = await _streamTransport(
            (_) async =>
                _sse('event: error\ndata: {"code":"${entry.key}"}\n\n'),
          );
          addTearDown(transport.close);
          transport.consistencyToken = 'stored';
          await expectLater(
            transport.watchChanges().toList(),
            throwsA(
              isA<TransportException>()
                  .having((e) => e.code, 'code', entry.key)
                  .having((e) => e.statusCode, 'status', entry.value),
            ),
          );
          expect(
            transport.consistencyToken,
            entry.value < 404 ? null : 'stored',
          );
        }
      },
    );

    test(
      'preserves HTTP authorization failure instead of parsing SSE',
      () async {
        final transport = await _streamTransport(
          (_) async => http.StreamedResponse(
            Stream.value(utf8.encode('{"code":"forbidden"}')),
            403,
            headers: {'content-type': 'application/json'},
          ),
        );
        addTearDown(transport.close);
        transport.consistencyToken = 'stored';
        await expectLater(
          transport.watchChanges().toList(),
          throwsA(
            isA<TransportException>()
                .having((e) => e.statusCode, 'status', 403)
                .having((e) => e.code, 'code', 'forbidden'),
          ),
        );
        expect(transport.consistencyToken, null);
      },
    );

    test('times out and cancels a stalled non-SSE HTTP error body', () async {
      final cancelled = Completer<void>();
      final body = StreamController<List<int>>(onCancel: cancelled.complete);
      final transport = await _streamTransport(
        (_) async => http.StreamedResponse(
          body.stream,
          503,
          headers: {'content-type': 'text/html'},
        ),
        requestTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(transport.close);
      await expectLater(
        transport.watchChanges().toList(),
        throwsA(
          isA<TransportException>().having((e) => e.code, 'code', 'timeout'),
        ),
      );
      await cancelled.future.timeout(const Duration(seconds: 1));
      await body.close();
    });

    test('rejects malformed non-hint events and truncated data', () async {
      for (final text in [
        'event: message\ndata: {}\n\n',
        'event: change\ndata: {"cursor":"one"}\n\n',
        'id: one\nevent: change\ndata: {"cursor":"two"}\n\n',
        'id: one\nevent: change\ndata: []\n\n',
        'id: one\nevent: change\ndata: {"cursor":"one","session":null}\n\n',
        'id: one\nevent: change\ndata: {"cursor":"one","documents":[]}\n\n',
        'id: one\nevent: change\ndata: {"cursor":"one"}\n',
        '<html>not events</html>\n\n',
        'id: bad\x00id\nevent: change\ndata: {}\n\n',
      ]) {
        final transport = await _streamTransport((_) async => _sse(text));
        addTearDown(transport.close);
        await expectLater(
          transport.watchChanges().toList(),
          throwsA(
            isA<TransportException>().having(
              (e) => e.code,
              'code',
              'invalid_response',
            ),
          ),
          reason: text,
        );
      }
      for (final type in ['application/json', 'text/html']) {
        final transport = await _streamTransport(
          (_) async => _sse(_hint('one'), type: type),
        );
        addTearDown(transport.close);
        await expectLater(
          transport.watchChanges().toList(),
          throwsA(
            isA<TransportException>().having(
              (e) => e.code,
              'code',
              'invalid_response',
            ),
          ),
        );
      }
    });

    test('rejects invalid UTF-8 without replacement decoding', () async {
      final transport = await _streamTransport(
        (_) async => http.StreamedResponse(
          Stream.fromIterable([
            [0xc3],
            [0x28, 10, 10],
          ]),
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      addTearDown(transport.close);
      await expectLater(
        transport.watchChanges().toList(),
        throwsA(
          isA<TransportException>().having(
            (e) => e.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    });

    test(
      'bounds both unterminated lines and accumulated multiline events',
      () async {
        for (final text in [
          ':${'x' * (64 * 1024)}',
          'event: change\ndata: ${' ' * 40000}\ndata: ${' ' * 40000}\n\n',
          'event: change\r\n${'data: \r\n' * 8500}',
        ]) {
          final bytes = utf8.encode(text);
          final transport = await _streamTransport(
            (_) async => http.StreamedResponse(
              Stream.fromIterable([
                for (var start = 0; start < bytes.length; start += 1024)
                  bytes.sublist(start, (start + 1024).clamp(0, bytes.length)),
              ]),
              200,
              headers: {'content-type': 'text/event-stream'},
            ),
          );
          addTearDown(transport.close);
          await expectLater(
            transport.watchChanges().toList(),
            throwsA(
              isA<TransportException>().having(
                (e) => e.code,
                'code',
                'response_too_large',
              ),
            ),
          );
        }
      },
    );

    test('pausing the consumer stops reading the next network chunk', () async {
      var produced = 0;
      Stream<List<int>> body() async* {
        produced++;
        yield utf8.encode(_hint('one'));
        produced++;
        yield utf8.encode(_hint('two'));
      }

      final transport = await _streamTransport(
        (_) async => http.StreamedResponse(
          body(),
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      addTearDown(transport.close);
      final first = Completer<void>();
      final done = Completer<void>();
      late StreamSubscription<ChangeHint> subscription;
      final ids = <String>[];
      subscription = transport.watchChanges().listen((hint) {
        ids.add(hint.resumeId);
        if (ids.length == 1) {
          subscription.pause();
          first.complete();
        }
      }, onDone: done.complete);
      await first.future;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(produced, 1);
      expect(ids, ['one']);
      subscription.resume();
      await done.future;
      expect(ids, ['one', 'two']);
    });

    test(
      'repeated pauses within one network chunk do not queue or deadlock',
      () async {
        var produced = 0;
        Stream<List<int>> body() async* {
          produced++;
          yield utf8.encode(_hint('one') + _hint('two') + _hint('three'));
          produced++;
          yield utf8.encode(_hint('four'));
        }

        final transport = await _streamTransport(
          (_) async => http.StreamedResponse(
            body(),
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        );
        addTearDown(transport.close);
        final paused = List.generate(3, (_) => Completer<void>());
        final done = Completer<void>();
        final ids = <String>[];
        late StreamSubscription<ChangeHint> subscription;
        subscription = transport.watchChanges().listen((hint) {
          ids.add(hint.resumeId);
          if (ids.length <= 3) {
            subscription.pause();
            paused[ids.length - 1].complete();
          }
        }, onDone: done.complete);
        for (var i = 0; i < 3; i++) {
          await paused[i].future.timeout(const Duration(seconds: 1));
          expect(produced, 1, reason: 'pause index $i');
          expect(ids.length, i + 1);
          subscription.resume();
        }
        await done.future.timeout(const Duration(seconds: 1));
        expect(ids, ['one', 'two', 'three', 'four']);
      },
    );

    test(
      'closing before stream listen cannot fetch or send a late token',
      () async {
        var tokens = 0;
        var sends = 0;
        final transport = await _streamTransport(
          (_) async {
            sends++;
            return _sse('');
          },
          tokenProvider: () async {
            tokens++;
            return 'token';
          },
        );
        final stream = transport.watchChanges();
        transport.close();
        await expectLater(
          stream.toList(),
          throwsA(
            isA<TransportException>().having(
              (e) => e.code,
              'code',
              'request_aborted',
            ),
          ),
        );
        expect(tokens, 1);
        expect(sends, 0);
      },
    );

    test(
      'cancel aborts a pending token refresh without awaiting or late send',
      () async {
        final token = Completer<String>();
        final started = Completer<void>();
        var tokenCalls = 0;
        var sends = 0;
        final transport = await _streamTransport(
          (_) async {
            sends++;
            return _sse(_hint('late'));
          },
          tokenProvider: () {
            if (tokenCalls++ == 0) return Future.value('initial');
            started.complete();
            return token.future;
          },
        );
        addTearDown(transport.close);
        final subscription = transport.watchChanges().listen(
          (_) => fail('No late hint expected.'),
        );
        await started.future;
        await subscription.cancel().timeout(const Duration(seconds: 1));
        token.complete('late-access-token');
        await Future<void>.delayed(Duration.zero);
        expect(sends, 0);
      },
    );

    test(
      'close interrupts pending token refresh and prevents late sends',
      () async {
        final token = Completer<String>();
        final started = Completer<void>();
        var tokenCalls = 0;
        var sends = 0;
        final transport = await _streamTransport(
          (_) async {
            sends++;
            return _sse(_hint('late'));
          },
          tokenProvider: () {
            if (tokenCalls++ == 0) return Future.value('initial');
            started.complete();
            return token.future;
          },
        );
        final outcome = expectLater(
          transport.watchChanges().toList(),
          throwsA(
            isA<TransportException>().having(
              (e) => e.code,
              'code',
              'request_aborted',
            ),
          ),
        );
        await started.future;
        transport.close();
        await outcome;
        token.complete('late-access-token');
        await Future<void>.delayed(Duration.zero);
        expect(sends, 0);
      },
    );

    test(
      'cancel aborts pending headers and disposes a late response',
      () async {
        final headers = Completer<http.StreamedResponse>();
        final sent = Completer<void>();
        final aborted = Completer<void>();
        final cancelled = Completer<void>();
        final transport = await _streamTransport((request) {
          (request as http.Abortable).abortTrigger!.then(
            (_) => aborted.complete(),
          );
          sent.complete();
          return headers.future;
        });
        addTearDown(transport.close);
        final subscription = transport.watchChanges().listen(
          (_) => fail('Unexpected hint.'),
        );
        await sent.future;
        await subscription.cancel().timeout(const Duration(seconds: 1));
        await aborted.future;
        final late = StreamController<List<int>>(onCancel: cancelled.complete);
        headers.complete(
          http.StreamedResponse(
            late.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        );
        await cancelled.future;
        await late.close();
      },
    );

    test('cancel pauses and aborts a live connection body', () async {
      final listened = Completer<void>();
      final cancelled = Completer<void>();
      final aborted = Completer<void>();
      final body = StreamController<List<int>>(
        onListen: listened.complete,
        onCancel: cancelled.complete,
      );
      final transport = await _streamTransport((request) async {
        (request as http.Abortable).abortTrigger!.then(
          (_) => aborted.complete(),
        );
        return http.StreamedResponse(
          body.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      addTearDown(transport.close);
      final subscription = transport.watchChanges().listen((_) {});
      await listened.future;
      subscription.pause();
      await subscription.cancel().timeout(const Duration(seconds: 1));
      await cancelled.future;
      await aborted.future;
      await body.close();
    });

    test(
      'opening timeout also aborts token refresh and prevents late sends',
      () async {
        final token = Completer<String>();
        var tokenCalls = 0;
        var sends = 0;
        final transport = await _streamTransport(
          (_) async {
            sends++;
            return _sse(_hint('late'));
          },
          tokenProvider: () =>
              tokenCalls++ == 0 ? Future.value('initial') : token.future,
          requestTimeout: const Duration(milliseconds: 10),
        );
        addTearDown(transport.close);
        await expectLater(
          transport.watchChanges().toList(),
          throwsA(
            isA<TransportException>().having((e) => e.code, 'code', 'timeout'),
          ),
        );
        token.complete('late-token');
        await Future<void>.delayed(Duration.zero);
        expect(sends, 0);
      },
    );

    test(
      'rejects stream use without a verified scope and header injection',
      () async {
        final unbound = _transport((_) async => _json({}));
        addTearDown(unbound.close);
        expect(() => unbound.watchChanges(), throwsStateError);
        final transport = await _streamTransport((_) async => _sse(''));
        addTearDown(transport.close);
        for (final id in ['', 'bad\nheader', 'bad\x00header']) {
          expect(
            () => transport.watchChanges(lastEventId: id),
            throwsArgumentError,
          );
        }
        transport.close();
        expect(() => transport.watchChanges(), throwsStateError);
      },
    );
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
                        'principalId': 'principal',
                        'permissionVersion': '1',
                        'scopeMode': 'user',
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
