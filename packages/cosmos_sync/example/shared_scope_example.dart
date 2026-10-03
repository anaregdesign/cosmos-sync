import 'package:cosmos_sync/cosmos_sync.dart';

/// The caller supplies a registered reader's opaque account ID, obtained after
/// that person signs in. No provider email or client role grants permission.
/// Persist [request] before this call if retry must survive process exit.
Future<SharedScope> grantReader({
  required HttpSyncTransport owner,
  required String scopeId,
  required SetSharedScopeMemberRequest request,
}) {
  if (request.role != SharedScopeRole.reader) {
    throw ArgumentError('This example grants only the reader role.');
  }
  return owner.setSharedScopeMember(scopeId, request);
}

/// Personal setup needs no grants file when the BFF uses built-in authorization.
/// Reuse the same [request] after a lost response; an acknowledged replay may
/// return an older policy, so fetch current membership before the next edit.
Future<SharedScope> createWorkspace({
  required HttpSyncTransport owner,
  required CreateSharedScopeRequest request,
}) async {
  await owner.account();
  return owner.createSharedScope(request);
}

/// Apps provide their own OIDC API-token adapter and app-private cache identity.
/// The BFF authorizes this scope; this constructor cannot grant membership.
Future<CosmosSyncClient> openSharedWorkspace({
  required Uri endpoint,
  required Future<String> Function() apiTokenProvider,
  required String cacheIdentity,
  required String sharedScopeId,
}) => CosmosSyncClient.open(
  path: cacheIdentity,
  transport: HttpSyncTransport(
    baseUri: endpoint,
    tokenProvider: apiTokenProvider,
    scopeMode: SyncScopeMode.shared,
    sharedScopeId: sharedScopeId,
  ),
);
