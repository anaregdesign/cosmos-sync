import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'models.dart';

/// HTTP wire transport. Durable retries belong to the offline client.
///
/// [baseUri] identifies the server root (or its path prefix). An injected
/// [client] is closed when this transport is closed. Production callers must
/// use HTTPS; plaintext HTTP is available only for explicitly allowed loopback
/// development endpoints. Call [sessionInfo] before mutations or sync; each
/// request is bound to that verified scope even if its fresh access token changes.
class HttpSyncTransport
    implements
        SyncTransport,
        ConsistencyTokenTransport,
        SnapshotTransport,
        ChangeHintTransport {
  HttpSyncTransport({
    required this.baseUri,
    required this.tokenProvider,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 30),
    this.scopeMode = SyncScopeMode.user,
    bool allowInsecureLocalhost = false,
  }) : _client = client ?? http.Client() {
    final loopback = {'localhost', '127.0.0.1', '::1'};
    if (!baseUri.hasAuthority ||
        baseUri.host.isEmpty ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        (baseUri.scheme != 'https' &&
            !(allowInsecureLocalhost &&
                baseUri.scheme == 'http' &&
                loopback.contains(baseUri.host)))) {
      throw ArgumentError.value(baseUri, 'baseUri', 'Use an HTTPS server URI.');
    }
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'Must be positive.',
      );
    }
  }

  static const _maxBodyBytes = 32 * 1024 * 1024;
  static const _maxEventBytes = 64 * 1024;
  static const _maxSequence = 9007199254740991;
  static const _sessionHeader = 'X-Cosmos-Sync-Session';

  final Uri baseUri;
  final Future<String> Function() tokenProvider;
  final Duration requestTimeout;
  final SyncScopeMode scopeMode;
  final http.Client _client;
  final Set<Completer<void>> _activeRequests = {};
  SessionInfo? _lastSession;
  String? _consistencyToken;
  bool _closed = false;

  @override
  String? get consistencyToken => _consistencyToken;

  @override
  set consistencyToken(String? value) {
    if (value != null && !_validOpaque(value)) {
      throw ArgumentError('Invalid opaque consistency token.');
    }
    _consistencyToken = value;
  }

  @override
  Future<SessionInfo> sessionInfo() async {
    final response = await _request(
      'GET',
      'session',
      queryParameters: {'scope': scopeMode.name},
    );
    final session = _parse(response.json, SessionInfo.fromJson);
    if (session.scopeMode != scopeMode ||
        [
          session.scopeId,
          session.principalId,
          session.permissionVersion,
        ].any((value) => !_validOpaque(value))) {
      throw const TransportException(
        code: 'invalid_session',
        message: 'The BFF returned an invalid authorization scope.',
      );
    }
    if (_lastSession != null && !_lastSession!.sameScope(session)) {
      _consistencyToken = null;
    }
    _lastSession = session;
    return session;
  }

  @override
  Future<ServerDocument> mutate(MutationRequest request) async {
    final response = await _request(
      'POST',
      'mutations',
      body: request.toJson(),
      useConsistencyToken: true,
    );
    final document = _parse(response.json['document'], ServerDocument.fromJson);
    _acceptConsistencyToken(response);
    return document;
  }

  @override
  Future<SyncPage> sync({String? cursor, int limit = 100}) async {
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'Must be positive.');
    }
    final response = await _request(
      'GET',
      'sync',
      queryParameters: {'cursor': ?cursor, 'limit': '$limit'},
      useConsistencyToken: true,
    );
    final page = _parse(response.json, SyncPage.fromJson);
    _acceptConsistencyToken(response);
    return page;
  }

  @override
  Future<SnapshotPage> snapshot({String? cursor, int limit = 100}) async {
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 100.');
    }
    final response = await _request(
      'GET',
      'snapshot',
      queryParameters: {'cursor': ?cursor, 'limit': '$limit'},
      useConsistencyToken: true,
    );
    final page = _parse(response.json, SnapshotPage.fromJson);
    if (page.cutoverSequence > _maxSequence ||
        page.documents.length > limit ||
        page.documents.map((document) => document.id).toSet().length !=
            page.documents.length ||
        (page.hasMore && page.documents.isEmpty) ||
        !_validOpaque(page.cursor) ||
        !_validOpaque(page.syncCursor)) {
      throw _invalidResponse();
    }
    _acceptConsistencyToken(response);
    return page;
  }

  /// Opens one SSE connection. The offline client owns reconnect and fallback.
  /// Hint IDs resume this stream only; callers still fetch durable sync pages.
  @override
  Stream<ChangeHint> watchChanges({String? lastEventId, String? cursor}) {
    if (_closed) throw StateError('Transport is closed.');
    final expectedSession = _lastSession;
    if (expectedSession == null) {
      throw StateError(
        'Verify the authorization scope with sessionInfo first.',
      );
    }
    if (lastEventId != null && !_validOpaque(lastEventId)) {
      throw ArgumentError.value(lastEventId, 'lastEventId', 'Invalid hint ID.');
    }
    if (cursor != null && !_validOpaque(cursor)) {
      throw ArgumentError.value(cursor, 'cursor', 'Invalid sync cursor.');
    }
    final expectedToken = _consistencyToken;
    final abort = Completer<void>();
    final done = Completer<void>();
    StreamSubscription<_SseEvent>? subscription;
    late final StreamController<ChangeHint> controller;
    var finished = false;
    var cancelled = false;
    var eventsPaused = false;

    void pauseEvents() {
      if (subscription != null && !eventsPaused) {
        eventsPaused = true;
        subscription!.pause();
      }
    }

    Future<void> finish([Object? error]) async {
      if (finished) return;
      finished = true;
      if (error != null && !cancelled) {
        controller.addError(_streamError(error));
      }
      if (!abort.isCompleted) abort.complete();
      if (!done.isCompleted) done.complete();
      _activeRequests.remove(abort);
      if (!cancelled) unawaited(controller.close());
      await subscription?.cancel();
    }

    Future<void> connect() async {
      if (_closed) {
        await finish(_aborted());
        return;
      }
      _activeRequests.add(abort);
      unawaited(
        abort.future.then(
          (_) => finish(
            const TransportException(
              code: 'request_aborted',
              message: 'Change stream was cancelled.',
            ),
          ),
        ),
      );
      try {
        final response =
            await (() async {
              final token = await _untilAbort(tokenProvider(), abort);
              if (abort.isCompleted) throw _aborted();
              _validateAccessToken(token);
              final request =
                  http.AbortableRequest(
                      'GET',
                      _endpoint(
                        'events',
                        lastEventId == null && cursor != null
                            ? {'cursor': cursor}
                            : null,
                      ),
                      abortTrigger: abort.future,
                    )
                    ..followRedirects = false
                    ..headers['Authorization'] = 'Bearer $token'
                    ..headers['Accept'] = 'text/event-stream';
              _bindRequest(request, expectedSession, expectedToken);
              if (lastEventId != null) {
                request.headers['Last-Event-ID'] = lastEventId;
              }
              final pending = _client.send(request).then((response) {
                if (abort.isCompleted) {
                  unawaited(_discardResponse(response));
                }
                return response;
              });
              return _untilAbort(pending, abort);
            })().timeout(
              requestTimeout,
              onTimeout: () => throw const TransportException(
                code: 'timeout',
                message: 'Opening the change stream timed out.',
              ),
            );
        if (abort.isCompleted) throw _aborted();
        if (response.statusCode != 200) {
          await _decodeResponse(
            response,
            expectedSession,
            abort: abort,
          ).timeout(
            requestTimeout,
            onTimeout: () => throw const TransportException(
              code: 'timeout',
              message: 'Reading the change stream error timed out.',
            ),
          );
          throw _invalidResponse();
        }
        final contentType = _header(response.headers, 'content-type');
        if (contentType == null ||
            contentType.split(';').first.trim().toLowerCase() !=
                'text/event-stream') {
          unawaited(_discardResponse(response));
          throw _invalidResponse();
        }
        subscription = _sseEvents(response.stream).listen(
          (event) {
            try {
              if (_lastSession == null ||
                  !_lastSession!.sameScope(expectedSession)) {
                throw const TransportException(
                  statusCode: 403,
                  code: 'session_mismatch',
                  message: 'The verified scope changed.',
                );
              }
              final json = _parse(event.data, (json) => json);
              if (event.type == 'error') {
                final code = json['code'];
                if (code is! String ||
                    code.isEmpty ||
                    !RegExp(r'^[a-z][a-z0-9_]{0,127}$').hasMatch(code)) {
                  throw _invalidResponse();
                }
                final error = _eventError(code);
                if (error.authorizationFailure) _consistencyToken = null;
                throw error;
              }
              if (event.type != 'change' ||
                  event.id == null ||
                  !_validOpaque(event.id!) ||
                  json['cursor'] != event.id ||
                  json.keys.any((key) => key != 'cursor' && key != 'session')) {
                throw _invalidResponse();
              }
              final session = json['session'];
              if (json.containsKey('session') &&
                  (session is! String || !_validOpaque(session))) {
                throw _invalidResponse();
              }
              // Asynchronous hints can arrive behind a newer ACK/page envelope.
              // Validate their optional session, but let durable responses update it.
              controller.add(
                ChangeHint(
                  resumeId: event.id!,
                  consistencyToken: session as String?,
                ),
              );
              if (controller.isPaused) pauseEvents();
            } on Object catch (error) {
              unawaited(finish(error));
            }
          },
          onError: (Object error, StackTrace stack) => unawaited(finish(error)),
          onDone: () => unawaited(finish()),
        );
        if (controller.isPaused) pauseEvents();
        await done.future;
      } on Object catch (error) {
        await finish(error);
      }
    }

    controller = StreamController<ChangeHint>(
      sync: true,
      onListen: () => unawaited(connect()),
      onPause: pauseEvents,
      onResume: () {
        if (eventsPaused) {
          eventsPaused = false;
          subscription?.resume();
        }
      },
      onCancel: () {
        cancelled = true;
        return finish();
      },
    );
    return controller.stream;
  }

  bool _validOpaque(String value) =>
      value.isNotEmpty &&
      value.length <= _maxEventBytes &&
      !value.contains(RegExp(r'[\r\n\x00]'));

  Future<void> _discardResponse(http.StreamedResponse response) async {
    final subscription = response.stream.listen(null, onError: (Object _) {});
    try {
      await subscription.cancel();
    } on Object {
      // The request's abort signal handles connection teardown independently.
    }
  }

  TransportException _aborted() => const TransportException(
    code: 'request_aborted',
    message: 'Sync request was cancelled.',
  );

  Future<T> _untilAbort<T>(Future<T> future, Completer<void> abort) =>
      Future.any([future, abort.future.then<T>((_) => throw _aborted())]);

  void _validateAccessToken(String token) {
    if (token.isEmpty || token.contains(RegExp(r'\s'))) {
      throw const TransportException(
        code: 'token_unavailable',
        message: 'The token provider returned an invalid access token.',
      );
    }
  }

  void _bindRequest(
    http.BaseRequest request,
    SessionInfo session,
    String? token,
  ) {
    request.headers['X-Cosmos-Sync-Scope'] = session.scopeId;
    request.headers['X-Cosmos-Sync-Principal'] = session.principalId;
    request.headers['X-Cosmos-Sync-Scope-Mode'] = session.scopeMode.name;
    request.headers['X-Cosmos-Sync-Permission'] = session.permissionVersion;
    if (token != null) request.headers[_sessionHeader] = token;
  }

  TransportException _streamError(Object error) => error is TransportException
      ? error
      : error is FormatException || error is TypeError || error is ArgumentError
      ? _invalidResponse()
      : const TransportException(
          code: 'network_error',
          message: 'Could not complete the change stream.',
        );

  TransportException _eventError(String code) => TransportException(
    code: code,
    message: 'Change stream returned $code.',
    statusCode: switch (code) {
      'unauthorized' => 401,
      'forbidden' || 'session_mismatch' => 403,
      'resync_required' => 410,
      'rate_limited' ||
      'rate_limit' ||
      'stream_limit' ||
      'concurrency_limit' => 429,
      _ => 503,
    },
  );

  Stream<_SseEvent> _sseEvents(Stream<List<int>> stream) {
    final parser = _SseParser(_maxEventBytes, _invalidResponse);
    late final StreamController<_SseEvent> controller;
    StreamSubscription<List<int>>? source;
    List<int>? chunk;
    var offset = 0;
    var processing = false;
    var stopped = false;
    var sourcePaused = false;

    void pauseSource() {
      if (source != null && !sourcePaused) {
        sourcePaused = true;
        source!.pause();
      }
    }

    void drain() {
      if (processing || stopped) return;
      processing = true;
      try {
        while (chunk != null &&
            !controller.isPaused &&
            controller.hasListener) {
          final event = parser.add(chunk![offset++]);
          if (offset == chunk!.length) {
            chunk = null;
            offset = 0;
          }
          if (event != null) {
            controller.add(event);
            if (controller.isPaused) pauseSource();
          }
        }
      } on Object catch (error, stack) {
        stopped = true;
        controller.addError(error, stack);
        unawaited(source?.cancel());
        unawaited(controller.close());
      } finally {
        processing = false;
      }
    }

    controller = StreamController<_SseEvent>(
      sync: true,
      onListen: () {
        source = stream.listen(
          (value) {
            if (value.isEmpty || stopped) return;
            chunk = value;
            offset = 0;
            drain();
          },
          onError: (Object error, StackTrace stack) {
            if (stopped) return;
            stopped = true;
            controller.addError(error, stack);
            unawaited(source?.cancel());
            unawaited(controller.close());
          },
          onDone: () {
            if (stopped) return;
            stopped = true;
            try {
              parser.end();
            } on Object catch (error, stack) {
              controller.addError(error, stack);
            }
            unawaited(controller.close());
          },
        );
        if (controller.isPaused) pauseSource();
      },
      onPause: pauseSource,
      onResume: () {
        // A sync controller buffers emissions made inside its own onResume.
        // Drain after that callback returns so each event can pause the source.
        scheduleMicrotask(() {
          drain();
          if (!controller.isPaused && !stopped && sourcePaused) {
            sourcePaused = false;
            source?.resume();
          }
        });
      },
      onCancel: () {
        stopped = true;
        chunk = null;
        return source?.cancel();
      },
    );
    return controller.stream;
  }

  Uri _endpoint(String endpoint, Map<String, String>? queryParameters) {
    final prefix = baseUri.path.replaceFirst(RegExp(r'/+$'), '');
    return baseUri.replace(
      path: '$prefix/v1/$endpoint',
      queryParameters: queryParameters,
    );
  }

  Future<_JsonResponse> _request(
    String method,
    String endpoint, {
    Map<String, Object?>? body,
    Map<String, String>? queryParameters,
    bool useConsistencyToken = false,
  }) async {
    if (_closed) throw StateError('Transport is closed.');
    if (useConsistencyToken && _lastSession == null) {
      throw StateError(
        'Verify the authorization scope with sessionInfo first.',
      );
    }
    final expectedSession = useConsistencyToken ? _lastSession : null;
    final expectedConsistencyToken = useConsistencyToken
        ? _consistencyToken
        : null;
    final abort = Completer<void>();
    _activeRequests.add(abort);
    try {
      return await _execute(
        method,
        _endpoint(endpoint, queryParameters),
        abort,
        body: body,
        expectedSession: expectedSession,
        expectedConsistencyToken: expectedConsistencyToken,
      ).timeout(
        requestTimeout,
        onTimeout: () {
          if (!abort.isCompleted) abort.complete();
          throw const TransportException(
            code: 'timeout',
            message: 'Sync request timed out.',
          );
        },
      );
    } finally {
      _activeRequests.remove(abort);
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<_JsonResponse> _execute(
    String method,
    Uri uri,
    Completer<void> abort, {
    Map<String, Object?>? body,
    SessionInfo? expectedSession,
    String? expectedConsistencyToken,
  }) async {
    try {
      // A fresh access token is fetched for every operation, including retries.
      final token = await _untilAbort(tokenProvider(), abort);
      if (abort.isCompleted) {
        throw const TransportException(
          code: 'request_aborted',
          message: 'Sync request was cancelled.',
        );
      }
      _validateAccessToken(token);
      final request =
          http.AbortableRequest(method, uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers['Authorization'] = 'Bearer $token'
            ..headers['Accept'] = 'application/json';
      if (expectedSession != null) {
        _bindRequest(request, expectedSession, expectedConsistencyToken);
      }
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        if (bytes.length > _maxBodyBytes) {
          throw const TransportException(
            statusCode: 413,
            code: 'request_too_large',
            message: 'Sync request exceeds the 32 MiB transport limit.',
          );
        }
        request
          ..headers['Content-Type'] = 'application/json; charset=utf-8'
          ..bodyBytes = bytes;
      }
      final response = await _client.send(request);
      return await _decodeResponse(response, expectedSession, abort: abort);
    } on TransportException {
      rethrow;
    } on Exception {
      // Exceptions can contain URLs or authentication details. Do not expose them.
      throw const TransportException(
        code: 'network_error',
        message: 'Could not complete the sync request.',
      );
    }
  }

  Future<_JsonResponse> _decodeResponse(
    http.StreamedResponse response,
    SessionInfo? expectedSession, {
    Completer<void>? abort,
  }) async {
    final bytes = BytesBuilder(copy: false);
    final iterator = StreamIterator(response.stream);
    try {
      while (await (abort == null
          ? iterator.moveNext()
          : _untilAbort(iterator.moveNext(), abort))) {
        final chunk = iterator.current;
        if (bytes.length + chunk.length > _maxBodyBytes) {
          throw const TransportException(
            code: 'response_too_large',
            message: 'Sync response exceeds the 32 MiB transport limit.',
          );
        }
        bytes.add(chunk);
      }
    } finally {
      await iterator.cancel();
    }
    Map<String, Object?>? json;
    try {
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is Map<String, Object?>) json = decoded;
    } on FormatException {
      // Preserve HTTP error classification even when an intermediary sends HTML.
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401 || response.statusCode == 403) {
        if (expectedSession == null ||
            _lastSession?.sameScope(expectedSession) == true) {
          _consistencyToken = null;
        }
      }
      final code = json?['code'];
      final message = json?['message'];
      ServerDocument? current;
      if (response.statusCode == 409 && json?['current'] != null) {
        current = _parse(json!['current'], ServerDocument.fromJson);
      }
      throw TransportException(
        statusCode: response.statusCode,
        code: code is String ? code : 'http_error',
        message: message is String
            ? message
            : 'Sync server returned HTTP ${response.statusCode}.',
        retryAfter: _retryAfter(_header(response.headers, 'retry-after')),
        current: current,
      );
    }
    if (json == null) throw _invalidResponse();
    return _JsonResponse(
      json,
      _header(response.headers, _sessionHeader),
      expectedSession,
    );
  }

  T _parse<T>(Object? value, T Function(Map<String, Object?>) parser) {
    try {
      if (value is! Map<String, Object?>) throw _invalidResponse();
      return parser(value);
    } on FormatException {
      throw _invalidResponse();
    } on TypeError {
      throw _invalidResponse();
    } on ArgumentError {
      throw _invalidResponse();
    }
  }

  // The server may have committed a mutation whose ACK cannot be decoded.
  // Retrying that exact durable operation is safe; rejecting it locally is not.
  TransportException _invalidResponse() => const TransportException(
    code: 'invalid_response',
    message: 'Sync server returned an invalid protocol response.',
  );

  void _acceptConsistencyToken(_JsonResponse response) {
    if (response.consistencyToken == null ||
        response.expectedSession == null ||
        _lastSession == null ||
        !_lastSession!.sameScope(response.expectedSession!)) {
      return;
    }
    try {
      consistencyToken = response.consistencyToken;
    } on ArgumentError {
      throw _invalidResponse();
    }
  }

  String? _header(Map<String, String> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
    }
    return null;
  }

  Duration? _retryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) {
      return seconds < 0 ? null : Duration(seconds: seconds);
    }
    try {
      final delay = parseHttpDate(
        value.trim(),
      ).difference(DateTime.now().toUtc());
      return delay.isNegative ? Duration.zero : delay;
    } on FormatException {
      return null;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _consistencyToken = null;
    for (final request in _activeRequests) {
      if (!request.isCompleted) request.complete();
    }
    _client.close();
  }
}

class _JsonResponse {
  const _JsonResponse(this.json, this.consistencyToken, this.expectedSession);
  final Map<String, Object?> json;
  final String? consistencyToken;
  final SessionInfo? expectedSession;
}

class _SseEvent {
  const _SseEvent(this.type, this.id, this.data);
  final String type;
  final String? id;
  final Object? data;
}

/// Bounded byte lines preserve fragmented UTF-8 and apply downstream backpressure.
class _SseParser {
  _SseParser(this.maximum, this.invalid);
  final int maximum;
  final TransportException Function() invalid;
  final List<int> _line = [];
  final List<String> _data = [];
  String? _type;
  String? _id;
  var _bytes = 0;
  var _afterCR = false;
  var _firstLine = true;

  _SseEvent? add(int byte) {
    if (_afterCR && byte == 10) {
      _afterCR = false;
      if (_bytes != 0 && ++_bytes > maximum) throw _tooLarge();
      return null;
    }
    _afterCR = byte == 13;
    if (byte != 10 && byte != 13) {
      if (_line.length >= maximum || ++_bytes > maximum) throw _tooLarge();
      _line.add(byte);
      return null;
    }
    if (++_bytes > maximum) throw _tooLarge();
    var line = utf8.decode(_line);
    _line.clear();
    if (_firstLine) {
      _firstLine = false;
      if (line.startsWith('\uFEFF')) line = line.substring(1);
    }
    if (line.isEmpty) {
      _bytes = 0;
      if (_data.isEmpty) {
        if (_type != null) throw invalid();
        _id = null;
        return null;
      }
      final event = _SseEvent(
        _type ?? 'message',
        _id,
        jsonDecode(_data.join('\n')),
      );
      _type = null;
      _id = null;
      _data.clear();
      return event;
    }
    if (line.startsWith(':')) return null;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'data':
        _data.add(value);
      case 'event':
        _type = value;
      case 'id':
        if (value.contains('\x00')) throw invalid();
        _id = value;
      case 'retry':
        if (!RegExp(r'^[0-9]+$').hasMatch(value)) throw invalid();
      default:
        throw invalid();
    }
    return null;
  }

  void end() {
    if (_line.isNotEmpty || _data.isNotEmpty || _type != null || _id != null) {
      throw invalid(); // Never dispatch a truncated, uncommitted SSE event.
    }
  }

  TransportException _tooLarge() => const TransportException(
    code: 'response_too_large',
    message: 'Change event exceeds the 64 KiB limit.',
  );
}
