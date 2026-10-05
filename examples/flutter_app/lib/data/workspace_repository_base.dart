import 'dart:convert';
import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:crypto/crypto.dart';

/// Non-secret connection preferences. Identity always comes from the BFF.
class ConnectionConfig {
  const ConnectionConfig({
    required this.bffUri,
    this.scopeMode = SyncScopeMode.user,
    this.sharedScopeId,
    this.allowInsecureLocalhost = false,
  });

  final Uri bffUri;
  final SyncScopeMode scopeMode;
  final String? sharedScopeId;
  final bool allowInsecureLocalhost;

  Map<String, Object?> toJson() => {
    'bffUri': bffUri.toString(),
    'scopeMode': scopeMode.name,
    if (sharedScopeId != null) 'sharedScopeId': sharedScopeId,
    'allowInsecureLocalhost': allowInsecureLocalhost,
  };

  factory ConnectionConfig.fromJson(Map<String, Object?> json) {
    final config = ConnectionConfig(
      bffUri: Uri.parse(json['bffUri'] as String),
      scopeMode: SyncScopeMode.values.byName(json['scopeMode'] as String),
      sharedScopeId: json['sharedScopeId'] as String?,
      allowInsecureLocalhost: json['allowInsecureLocalhost'] as bool? ?? false,
    );
    config.validateScopeSelection();
    return config;
  }

  void validateScopeSelection() {
    if (scopeMode == SyncScopeMode.shared) {
      if (sharedScopeId == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(sharedScopeId!)) {
        throw ArgumentError('Shared mode requires a BFF-issued scope ID.');
      }
    } else if (sharedScopeId != null) {
      throw ArgumentError('A shared ID cannot be mixed with a legacy mode.');
    }
  }

  String get key =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();
}

/// App-private caches are selected by BFF-verified identity and an opaque
/// credential binding rotated on interactive sign-in. JWT claims and caller
/// tenant/partition identifiers never select a cache.
abstract class WorkspaceRepositoryBase {
  WorkspaceRepositoryBase({this.transportFactory = _httpTransport});

  final SyncTransport Function(ConnectionConfig, Future<String> Function())
  transportFactory;

  static SyncTransport _httpTransport(
    ConnectionConfig config,
    Future<String> Function() tokenProvider,
  ) => HttpSyncTransport(
    baseUri: config.bffUri,
    tokenProvider: tokenProvider,
    scopeMode: config.scopeMode,
    sharedScopeId: config.sharedScopeId,
    allowInsecureLocalhost: config.allowInsecureLocalhost,
  );

  Future<void> prepare();
  Future<Map<String, Object?>?> readIndex();
  Future<void> saveIndex(Map<String, Object?> value);
  Future<CacheStore> openCache(String identity);
  Future<void> purge();

  Future<CosmosSyncClient> open({
    required ConnectionConfig config,
    required String credentialBinding,
    required Future<String> Function() tokenProvider,
    bool offline = false,
    SessionInfo? expectedIdentity,
  }) async {
    config.validateScopeSelection();
    await prepare();
    final transport = transportFactory(config, tokenProvider);
    CosmosSyncClient? opened;
    try {
      SessionInfo verified;
      if (offline) {
        final saved = await readIndex();
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
      if (verified.scopeMode != config.scopeMode ||
          (config.scopeMode == SyncScopeMode.shared &&
              verified.scopeId != config.sharedScopeId)) {
        throw StateError(
          'The verified session does not match the selected scope.',
        );
      }
      if (expectedIdentity != null &&
          (verified.principalId != expectedIdentity.principalId ||
              verified.identityGeneration !=
                  expectedIdentity.identityGeneration ||
              verified.identityId != expectedIdentity.identityId)) {
        throw const TransportException(
          statusCode: 401,
          code: 'identity_session_invalid',
          message: 'The new data session does not match the verified identity.',
        );
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
        cache: await openCache(identity),
        transport: transport,
        session: verified,
      );
      opened = client;
      if (!offline && client.status.paused) {
        // SDK has already purged the obsolete authorization generation.
        await client.resume();
      }
      if (!offline) {
        await saveIndex({
          'connection': config.key,
          'credentialBinding': credentialBinding,
          'session': verified.toJson(),
        });
      }
      return client;
    } catch (error) {
      if (opened != null) {
        await opened.close();
      } else {
        transport.close();
      }
      if (error is TransportException &&
          (error.statusCode == 401 || error.statusCode == 403)) {
        await purge();
      }
      rethrow;
    }
  }
}
