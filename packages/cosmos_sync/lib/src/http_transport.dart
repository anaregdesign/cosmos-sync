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
class HttpSyncTransport implements SyncTransport, ConsistencyTokenTransport {
  HttpSyncTransport({
    required this.baseUri,
    required this.tokenProvider,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 30),
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
  static const _sessionHeader = 'X-Cosmos-Sync-Session';

  final Uri baseUri;
  final Future<String> Function() tokenProvider;
  final Duration requestTimeout;
  final http.Client _client;
  final Set<Completer<void>> _activeRequests = {};
  SessionInfo? _lastSession;
  String? _consistencyToken;
  bool _closed = false;

  @override
  String? get consistencyToken => _consistencyToken;

  @override
  set consistencyToken(String? value) {
    if (value != null &&
        (value.isEmpty ||
            value.length > 65536 ||
            value.contains('\r') ||
            value.contains('\n'))) {
      throw ArgumentError('Invalid opaque consistency token.');
    }
    _consistencyToken = value;
  }

  @override
  Future<SessionInfo> sessionInfo() async {
    final response = await _request('GET', 'session');
    final session = _parse(response.json, SessionInfo.fromJson);
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
      final token = await tokenProvider();
      if (abort.isCompleted) {
        throw const TransportException(
          code: 'request_aborted',
          message: 'Sync request was cancelled.',
        );
      }
      if (token.isEmpty || token.contains(RegExp(r'\s'))) {
        throw const TransportException(
          code: 'token_unavailable',
          message: 'The token provider returned an invalid access token.',
        );
      }
      final request =
          http.AbortableRequest(method, uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers['Authorization'] = 'Bearer $token'
            ..headers['Accept'] = 'application/json';
      if (expectedSession != null) {
        request.headers['X-Cosmos-Sync-Scope'] = expectedSession.scopeId;
        request.headers['X-Cosmos-Sync-Permission'] =
            expectedSession.permissionVersion;
        if (expectedConsistencyToken != null) {
          request.headers[_sessionHeader] = expectedConsistencyToken;
        }
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
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > _maxBodyBytes) {
          throw const TransportException(
            code: 'response_too_large',
            message: 'Sync response exceeds the 32 MiB transport limit.',
          );
        }
        bytes.add(chunk);
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
          _consistencyToken = null;
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
