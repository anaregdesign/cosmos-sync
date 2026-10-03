# Developer onboarding

The product goal is to deploy the supplied Cosmos Sync BFF on Azure Container
Apps, connect the Dart SDK, and obtain the supported Firestore-inspired document,
watch and offline experience without writing a synchronization or security BFF.
This guide joins deployment, authentication, account/membership policy, the runnable app and
operations into one journey. **The hosted clean-checkout acceptance is still
open in [#32](https://github.com/anaregdesign/cosmos-sync/issues/32).** Existing
local, emulator, native-provider and device results are separate evidence in
[verification](verification.md); they do not establish an ACA deployment.

The first `0.2.0-dev.1` preview has a finite API. It implements durable local
documents/outbox, explicit synchronization, optimistic conflicts, tombstones,
resumable cursors, local queries/watches and server-authorized personal/shared
scopes. It does not implement Firestore's complete API or security-rule language.
Apple and Google are the intended consumer login providers, with their adapters
and stable account linking still tracked in [#26–30](social-auth.md). The
implemented native path uses OIDC/PKCE and a dedicated API access token, with
Entra used for actual provider validation. Provider registration, authorization
policy and compatible Cosmos resources remain operator responsibilities.
The built-in authorization preview provides durable BFF accounts, personal
self-access and fixed-owner shared scopes with reader/writer membership APIs.
Implementation and security evidence are tracked in
[#33](https://github.com/anaregdesign/cosmos-sync/issues/33); check the latest
verified source and distinguish local tests from actual hosted acceptance.
Existing explicit server grants remain the legacy
mode. An empty legacy grants configuration deliberately denies document access.
A healthy container is not yet the completed developer experience.

## 1. Start from a clean checkout

```sh
git clone https://github.com/anaregdesign/cosmos-sync.git
cd cosmos-sync
git status --short
```

Use the reviewed release commit recorded in [release](release.md). Confirm
actual package publication and image digest there before using registry artifacts;
a dry run or planned package URL does not establish availability. The source
checkout remains usable for local preparation while those gates are open.

Go 1.26+ and Dart 3.12+ are required; Flutter 3.44.6 is the measured native
baseline. Docker is needed only for the emulator/container checks. Install the
Terraform version required by `infra/terraform/azure-container-apps`; its provider
constraints and lock file are part of the deployment source. An approved Azure
subscription and permission to create the planned resources are required for
an actual apply, not for local validation.

```sh
cd examples/flutter_app
flutter pub get
flutter analyze
flutter test
cd ../..
python3 tools/flutter_app_smoke.py --device macos
```

The last command launches the ordinary app UI against a real local Go HTTP BFF,
SQLite and a signed test identity adapter. It exercises the protocol without
Azure or a real provider; it does not perform provider registration or a hosted
deployment. A physical Android target requires the separate explicitly selected
device procedure in [physical-device validation](physical-devices.md). The sample
targets Android API 24+, iOS 15+ and macOS 12+. It supplies no Flutter Web, Linux
or Windows login app; Chromium SDK persistence tests are separate coverage.

## 2. Prepare the hosting and identity inputs

Read the [Container Apps runbook](azure-container-apps.md) before using
`infra/terraform/azure-container-apps`. The template and a successful local
validation are deployment preparation, not evidence that an image is running.
The Terraform task is tracked in [#31](https://github.com/anaregdesign/cosmos-sync/issues/31).

| Supplied by the deployment template | Must exist or be explicitly configured by the operator |
| --- | --- |
| ACA environment/application and bounded ingress, health, scaling and runtime configuration | Approved subscription, resource group/region, network access and the plan's creation permissions |
| Optional runtime user-assigned identity and explicit narrow role assignments | Existing compatible Cosmos NoSQL account/database/container and authorization to assign only its required data role |
| References to existing Key Vault secrets | Approved vault, high-entropy shared cursor key and exact secret-access permission; optional metrics/private-pull secrets only when selected |
| Reviewed public GHCR image pinned by digest | Actual published digest and validated configuration; private pulls need separately approved credentials |
| BFF OIDC/CORS/configuration inputs | Trusted issuer, dedicated API audience/scope, registered native public client/redirect and tested provider consent |

No Cosmos account/database/container, identity-provider registration, test user,
provider consent or membership in another user's shared scope is implied by
starting the BFF. Built-in personal access starts only after a correctly verified
API access token establishes the caller's own account.
The container validates an existing `/scopeId` container with TTL disabled,
single-write configuration and Session-or-stronger consistency. All managed
writes must pass through this BFF; external hard deletes, per-item TTL and
out-of-band edits break the supported journal/receipt contract.

Use the runbook's cheap single-replica example for an approved bounded validation.
Scaling beyond one replica requires a shared signing key and a selected
authorization source with a documented revocation delay; a stale per-replica
grants file must not become the deployment's permission authority. The selected
`builtin` mode stores account/scope/membership policy in Cosmos and uses a
same-partition policy ETag fence for data mutations. Exact freshness, response
delivery and revocation boundaries require the tests and documentation in #33.
An initial deny-all template without that mode is deployment preparation, not
an automatically configured permission service.

For new deployments the template selects `builtin` but requires the explicit
`builtin_authorization_image_verified=true` assertion after verification of the
actual immutable image and intended new namespace. The example leaves that
assertion false, so it cannot silently deploy an unverified policy image. This
assertion does not approve a cloud apply or migrate a legacy deployment.

ACA runtime configuration uses non-secret `COSMOS_SYNC_CONFIG_JSON`, explicit
`COSMOS_SYNC_TLS_MODE=container-apps` behind HTTPS ingress, and a selected managed
identity. The shared cursor key uses a Key Vault secret reference. JWT checks
remain production checks; never use development mode to workaround ingress or
configuration problems. Follow the runbook for the exact supported transport
boundary and the runtime source's validation results.

Never place secret values in `terraform.tfvars`, committed JSON, plan output or
chat. Secret-reference names/URIs are configuration; the cursor key, credentials
and access tokens remain secret. Terraform state and saved plans can still expose
sensitive deployment information. Use the runbook's protected remote-state and
secret-rotation procedure before a real deployment.

Run the template's format, initialization, validation and mocked-plan checks from
a clean checkout. For example, the checks that do not create Azure resources are:

```sh
cd infra/terraform/azure-container-apps
terraform fmt -check -recursive
terraform init -backend=false -input=false -lockfile=readonly
terraform validate
terraform test
tflint
cd ../../..
```

The tests use mocked providers and plan commands; keep that boundary when running
them. Review the real plan before an authorized apply. Local mocked
plans do not prove Azure permissions, image availability, firewall connectivity
or managed-identity data access. Record actual apply/readiness separately in #32.
For this repository's current work, the owner authorized IaC/docs preparation;
new ACA resources, identity/RBAC/Key Vault/network changes and deployment still
need their exact approval. Retain the already approved reusable Cosmos/Entra
validation environment.

## 3. Configure authentication and the supplied authorization service

Follow [native authentication](native-auth.md) and the
[Entra setup](entra-setup.md) for the implemented path. Register an application
specific public native client with the exact callback
`com.anaregdesign.cosmossync://auth/oauthredirect`, and an API exposing the
required delegated scope. Configure the BFF's exact issuer, API audience and
scope. The native client ID is not the API audience. Sign in through the system
browser with PKCE; do not copy a token into the sample.

Apple/Google raw ID tokens and unrelated Google/Graph API access tokens are not
Cosmos Sync API credentials. The [social-auth roadmap](social-auth.md) defines the
broker/API-token or backend-exchange boundary; entering another provider's issuer
in the current form does not implement it. New provider registrations, credentials,
consent and Apple signing/capabilities require their concrete owner approval.

The recommended configuration selects `authorization: {"mode": "builtin"}`.
The interface and revocation bounds are documented in [authorization](authorization.md);
require the latest reviewed tests and a matching immutable BFF image.
Correctly verified API authentication
establishes a durable account and personal scope. Apps use the supplied management
API instead of implementing policy storage or a permission service themselves.

| BFF route | Developer use |
| --- | --- |
| `GET /v1/account` | Obtain the verified user's opaque `accountId` and `personalScopeId`; never derive ownership from email or client-decoded claims. |
| `GET /v1/session?scope=user` | Verify/open the account's personal document scope. |
| `POST /v1/scopes` | Supply an operation UUID to create a shared scope whose creator is its fixed owner. Retry the exact operation on an unknown outcome. |
| `GET /v1/scopes/{scopeId}/members` | Owner-only membership/revision inspection. |
| `POST /v1/scopes/{scopeId}/members` | Owner-only conditional change with operation UUID, registered opaque account ID, `reader`, `writer` or `none`, and observed `baseRevision`. |
| `GET /v1/session?scope=shared&scopeId={scopeId}` | Verify current access to that particular server-managed shared scope. An ID is a membership selector, not permission or a raw partition key. |

The shared owner cannot be replaced or edited as an ordinary member. A nonowner
cannot self-grant. A conflicting revision returns `membership_conflict`; refresh
the membership view and ask for an explicit new operation rather than silently
overwrite it. Unknown accounts cannot be invited by email through these APIs.
Provider invitations, cross-provider linking, owner transfer and account/scope
deletion are separate work. API authentication alone grants no membership of
someone else's shared scope.

Leaving `authorization.mode` unset or choosing `legacy` retains the explicit
[`grants.example.json`](../bff/grants.example.json) model. Missing/empty grants
deny access; supply server-authorized tenant/subject/read/write/version entries
if intentionally operating that mode. Do not mix nonempty legacy grants with
built-in authority, assume legacy `tenant` mode is the new `shared` mode, or
silently migrate old partitions. A reviewed migration must preserve ownership,
history, receipts, permission changes and pending-write behavior. No generic
security-rule DSL, document ACL or Entra group dependency is introduced.

OIDC/Broker app roles may gate application entry; they do not replace document
ownership or shared memberships. The chosen architecture keeps those data
permissions in the BFF. External ID consumer configuration remains separate
from the validated workforce Entra setup; no new consumer tenant or social
provider registration is created by this choice. The official comparison and
implementation acceptance are recorded in
[#33](https://github.com/anaregdesign/cosmos-sync/issues/33).

## 4. Run the application, then integrate the SDK

Launch `examples/flutter_app` with ordinary `flutter run -d macos` or an approved
native device target. Enter the deployed HTTPS BFF URL, trusted issuer, native
public client ID and space-separated `openid`, API scope and `offline_access`
scopes. The form contains no client secret or token field. `Save and sign in`
opens the system browser. A verified BFF session establishes principal/scope
before a fresh cache is opened. See the [app guide](../examples/flutter_app/README.md)
for exact callback, secure-storage and offline reopening behavior.
The ordinary app defaults to personal documents. Its legacy tenant option is
not a selector for a newly created built-in shared scope.

The Dart package supplies the sync/storage API; it contains no widgets or general
provider-login SDK. Reuse the sample's reviewed auth/lifecycle pattern or another
compatible API-access-token provider. Supply `HttpSyncTransport.tokenProvider`
with a refreshed API Bearer access token. Keep credentials in approved platform
storage, and select an app-private cache identity tied to the endpoint,
BFF-verified principal/scope and the same verified credential session.

```dart
import 'package:cosmos_sync/cosmos_sync.dart';

Future<void> previewNotes({
  required Uri endpoint,
  required String cachePath,
  required Future<String> Function() accessToken,
}) async {
  final client = await CosmosSyncClient.open(
    path: cachePath,
    transport: HttpSyncTransport(
      baseUri: endpoint,
      tokenProvider: accessToken,
      scopeMode: SyncScopeMode.user,
    ),
  );
  final changes = client.watch('note').listen((view) {
    // Render data in the UI; log only non-sensitive state here.
    print('Version: ${view?.version}; pending: ${view?.hasPendingWrites}');
    // A null view is allowed before creation or after a learned cache purge.
  });
  final status = client.statuses.listen((value) {
    print('Paused: ${value.paused}; reason: ${value.reason}');
    // Render fixed error codes in the UI; never log credentials or payloads.
  });
  try {
    await client.sync();
    await client.put('note', {'title': 'Available offline'});
    // put completed a durable local write. It is still pending server ACK.
    final delivery = await client.flush();
    print('Pending: ${delivery.remaining}; retry at: ${delivery.retryAt}');
    // An outage retains exact operations.
    final page = client.query(LocalQuery(limit: 20));
    print('Cached coverage complete: ${!page.metadata.isIncomplete}');
    // Coverage at a committed cursor is separate from current freshness.
    client.startWatching(); // SSE hints where available, with polling fallback.
    await client.delete('note'); // A durable local tombstone operation.
    await client.flush();
  } finally {
    await changes.cancel();
    await status.cancel();
    await client.close(); // Ordinary close retains data/outbox for offline reopen.
  }
}
```

Adapt this API sketch to your application's lifetime; keep the client open while
watching. Await local mutation methods. Use `waitForPendingWrites()` when you need
ACKs for the currently queued set and handle conflict/discard/revocation/close
failures. `put` replaces a complete bounded JSON document. There is no automatic
typed model generation; application models map to/from this JSON boundary.
See the [package guide](../packages/cosmos_sync/README.md) and
[query semantics](query.md) for the exact usable API.

The typed management API supports creating a shared scope and granting a
**separately registered** account read access. It uses the owner's fresh API token:

```dart
Future<SharedScope> createSharedWorkspace({
  required HttpSyncTransport ownerTransport,
  required String registeredReaderAccountId,
}) async {
  final createRequest = CreateSharedScopeRequest.create();
  // Persist createRequest.toJson() before sending if restart-safe retry is needed.
  final scope = await ownerTransport.createSharedScope(createRequest);
  final memberRequest = SetSharedScopeMemberRequest.create(
    accountId: registeredReaderAccountId,
    role: SharedScopeRole.reader,
    baseRevision: scope.revision,
  );
  // Persist this request too; retry an unknown outcome with the SAME request.
  return ownerTransport.setSharedScopeMember(scope.scopeId, memberRequest);
}
```

The member obtains its opaque account ID through its own authenticated `account()`
call; it is not an email invitation. Restore saved management requests with
`fromJson` when retrying after process exit. After `membership_conflict`, reread
`sharedScopeMembers(scopeId)` and make an explicit new change. These online
management requests are distinct from the document client's durable offline outbox.
Connect a document transport using `scopeMode: SyncScopeMode.shared` and
`sharedScopeId: policy.scopeId`, then open a separate app-private cache for that
verified scope. A legacy tenant checkbox is not a built-in shared-scope selector.
The actual interfaces and tests remain tracked in #33; a typed helper alone does
not establish hosted membership or multi-provider acceptance.

## 5. Verify the connected and offline experience

Use a unique synthetic document prefix and two independently stored clients for
the same authorized scope. Do not modify unrelated application records.

1. Create, read, edit and delete online. A local/query watch emits after durable
   local changes and ACK/pull. Pending overlays and the last confirmed server
   version are distinct. Query coverage at a committed cursor is distinct from
   current server freshness.
2. Choose `Work offline`, save an edit, close/reopen the same verified cache and
   credential session, then reconnect. The pending operation ID/base survives;
   delivery produces one accepted write, even when the response is replayed.
   A new cache or fresh interactive login needs online session verification.
3. In client A observe a version; edit the same document through client B and ACK
   it; then deliver A's stale edit. Observe a conflict, choose `Keep local and
   retry` or `Use server`, and inspect the resulting state. Neither a pull nor
   retry automatically merges/rebases the original edit.
4. For a shared scope, have its owner change a separate registered member from
   writer to reader, then `none`. Verify write denial and learned session/cursor
   invalidation through the selected policy model. The fixed owner cannot be
   demoted as its own member. Legacy-mode validation can instead transition the
   same user's explicit grant to reader/inactive and advance its permission
   version; label that evidence as legacy. A learned 401/403 or changed
   authorization purges cache/outbox and pauses. An offline device cannot learn
   revocation or remotely erase its data yet.
5. Sign out: stop new work, drain in-flight operations, await SDK `signOut()` and
   close, then delete native credentials. Confirm pending-loss messaging and purge.
   Ordinary app close should preserve the durable cache; sign-out should not.

One real account can exercise legacy role transitions and two-client conflicts.
It cannot establish actual built-in shared owner/member denial or isolation
between two provider accounts/tenants; use separate signed test principals for
automated coverage and leave the real-provider gap explicit. Unsigned
iOS compilation and simulator execution cannot prove physical iPhone login.
Fault-injected lost responses, retries and crash tests should remain labeled as
such when combined with an actual provider/Cosmos/ACA run.

## 6. Handle failures and operate the service

Render `TransportException.code`, `SyncStatus`, pending mutation state and
`FlushResult.retryAt` as actionable application state. Network/429/5xx retries
preserve the exact operation and persisted backoff. Attempted writes with an
unknown outcome cannot be discarded safely. Conflicts require explicit
`retryConflict`/`discard`; capacity code `scope_capacity_exceeded` requires operator
action and preserves the operation. A cursor generation change triggers replay
while retaining exact pending identities. Polling recovers missed/closed hints.

Use the [ACA runbook](azure-container-apps.md), [Azure operations](azure-operations.md),
[security](security.md) and [operational bounds](performance.md) for revision/image
upgrades, compatible configuration, cursor-key/history rotation, permissions,
monitoring and recovery. Cold starts and SSE polls have latency/RU/cost effects;
idle streams still query Cosmos. App-local rate limits are not distributed
quotas. Retained journals/receipts/tombstones have no automatic GC and are guarded
by finite capacity. Scale, logs, storage, backup restore and network egress need
explicit cost choices; no production load/failover/PITR result is implied by a
small contract test. Never automatically destroy retained validation resources.

There is no global ordering, cross-partition/offline transaction, arbitrary server
query, automatic merge, external-writer ingestion, continuous OS background sync,
encrypted SQLite database or production SLA. Browser eviction, OS compromise and
offline revocation remain application/deployment concerns. These boundaries are
part of the preview's developer experience, not hidden after deployment.

## 7. Record reproducible acceptance

Attach sanitized evidence to [#32](https://github.com/anaregdesign/cosmos-sync/issues/32):
clean source commit, actual published image digest/package version, tool/platform
versions, validated Terraform/approved plan, actual ACA readiness and managed
identity access, provider callback, CRUD/offline/conflict/grant/purge results, and
measured runtime/request charges. Preserve private configuration outside Git.
Do not publish tokens, secret values, private owner identities, device IDs or
document payloads. Mark each evidence boundary: local fixture, actual provider,
actual Cosmos, hosted ACA and physical platform. Leave unperformed gates open.
