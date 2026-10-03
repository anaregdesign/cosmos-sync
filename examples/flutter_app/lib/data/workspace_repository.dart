import 'dart:convert';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Non-secret connection preferences. Identity always comes from the BFF.
class ConnectionConfig {
  const ConnectionConfig({
    required this.bffUri,
    this.scopeMode = SyncScopeMode.user,
    this.allowInsecureLocalhost = false,
  });

  final Uri bffUri;
  final SyncScopeMode scopeMode;
  final bool allowInsecureLocalhost;

  Map<String, Object?> toJson() => {
    'bffUri': bffUri.toString(),
    'scopeMode': scopeMode.name,
    'allowInsecureLocalhost': allowInsecureLocalhost,
  };

  factory ConnectionConfig.fromJson(Map<String, Object?> json) =>
      ConnectionConfig(
        bffUri: Uri.parse(json['bffUri'] as String),
        scopeMode: SyncScopeMode.values.byName(json['scopeMode'] as String),
        allowInsecureLocalhost:
            json['allowInsecureLocalhost'] as bool? ?? false,
      );

  String get key =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();
}

/// App-private caches are selected by BFF-verified identity and an opaque
/// credential binding rotated on interactive sign-in. JWT claims and caller
/// tenant/partition identifiers never select a cache.
class WorkspaceRepository {
  WorkspaceRepository({
    required this.directory,
    this.transportFactory = _httpTransport,
  });

  final Directory directory;
  final SyncTransport Function(ConnectionConfig, Future<String> Function())
  transportFactory;

  static SyncTransport _httpTransport(
    ConnectionConfig config,
    Future<String> Function() tokenProvider,
  ) => HttpSyncTransport(
    baseUri: config.bffUri,
    tokenProvider: tokenProvider,
    scopeMode: config.scopeMode,
    allowInsecureLocalhost: config.allowInsecureLocalhost,
  );

  File get _index => File(p.join(directory.path, 'verified-session.json'));

  Future<CosmosSyncClient> open({
    required ConnectionConfig config,
    required String credentialBinding,
    required Future<String> Function() tokenProvider,
    bool offline = false,
  }) async {
    await directory.create(recursive: true);
    final transport = transportFactory(config, tokenProvider);
    CosmosSyncClient? opened;
    try {
      SessionInfo verified;
      if (offline) {
        final saved = await _readIndex();
        if (saved == null ||
            saved['connection'] != config.key ||
            saved['credentialBinding'] != credentialBinding) {
          throw StateError(
            'No verified cache exists for this signed-in session.',
          );
        }
        verified = SessionInfo.fromJson(
          (saved['session'] as Map).cast<String, Object?>(),
        );
      } else {
        verified = await transport.sessionInfo();
      }
      final identity = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                config.key,
                verified.scopeId,
                verified.principalId,
                verified.scopeMode.name,
              ]),
            ),
          )
          .toString();
      final client = await CosmosSyncClient.open(
        path: p.join(directory.path, '$identity.sqlite'),
        transport: transport,
        session: verified,
      );
      opened = client;
      if (!offline && client.status.paused) {
        // SDK has already purged the obsolete authorization generation.
        await client.resume();
      }
      if (!offline) {
        await _saveIndex({
          'connection': config.key,
          'credentialBinding': credentialBinding,
          'session': verified.toJson(),
        });
      }
      return client;
    } catch (_) {
      if (opened != null) {
        await opened.close();
      } else {
        transport.close();
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>?> _readIndex() async {
    if (!await _index.exists()) return null;
    try {
      return (jsonDecode(await _index.readAsString()) as Map)
          .cast<String, Object?>();
    } on FormatException {
      return null;
    }
  }

  Future<void> _saveIndex(Map<String, Object?> value) async {
    final temporary = File('${_index.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(_index.path);
  }

  /// Call only after clients drain and close their SQLite handles.
  Future<void> purge() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
