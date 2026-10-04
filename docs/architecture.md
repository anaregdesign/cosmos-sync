# Architecture and supported scope

Cosmos Sync v0.2 is an experimental Go BFF and Dart/Flutter offline SDK for Cosmos DB for NoSQL. It provides a finite document protocol and cache query model inspired by Firestore, with explicit differences. The [product contract](spec/product-completion.md) defines the bounded completion target; [verification](verification.md) records actual evidence.

## Server boundary

OIDC access JWT verification precedes BFF authorization. The provider authenticates
an issuer/subject identity; email, groups and client-supplied ownership claims do
not grant data permissions. New deployments explicitly select `builtin` mode.
Cosmos stores durable opaque accounts, an account's personal self-access scope,
and fixed-owner shared scopes. Only the owner can change registered accounts'
reader/writer membership, using an operation ID and observed policy revision.
Policy changes, immutable audit records and receipts commit together. Membership
generations invalidate old sessions/cursors without rotating unrelated members.
See the [authorization contract](authorization.md) for limits and revocation.

Each request asserts the verified principal/scope/mode/permission generation,
protecting against token-provider switches between members sharing a partition.
An opaque shared-scope selector conveys no permission. Authorization metadata is
excluded from document reads and synchronization. A same-partition policy ETag
fences document commits against a preceding permission change. Offline clients
cannot learn remote revocation, and Session consistency is not a globally
linearizable authorization read. A response already released to the network
cannot be recalled.

Unset/explicit `legacy` mode retains existing user/shared-tenant grants and
partitions. Its server grant file is read per request and must be atomically
distributed to replicas. It has an admission-time revocation boundary rather
than the built-in policy commit fence. Built-in mode rejects mixed nonempty
legacy grants; migration is separate reviewed work.

The official Go `azcosmos` adapter uses ETag-conditional transactional batches to
write head, document, immutable journal and principal-bound receipt atomically.
Built-in mutations include the current policy's conditional write in that same
batch. Both batch and individual-operation results are checked. A head serializes
writes within a partition; it creates contention for large shared scopes. Signed
consistency envelopes propagate Cosmos session metadata across BFFs. Account
policy rejects multi-write, missing metadata and weaker-than-Session consistency.
Production requires one write region and a `/scopeId` container with TTL disabled.

The supplied Container Apps target uses HTTPS ingress, explicit trusted-ingress
runtime mode, a dedicated managed identity and narrow Cosmos native data RBAC.
Pinned Terraform references existing Cosmos/Key Vault resources and creates the
hosting resources only after an approved apply. Mocked plans verify preparation,
not Azure connectivity. [Onboarding](developer-onboarding.md) joins provider
configuration, account/member APIs, the Flutter app and operational checks.

## Client state

A CacheStore provides loaded synchronous reads and asynchronous atomic durable mutations. Native SQLite and browser IndexedDB preserve confirmed documents, exact outbox requests/dependencies, retry state, verified identity, sync/snapshot cursors and coverage. An awaited put/delete means local acceptance. A server ACK is separate. Watches include pending/conflict/coverage changes, and local queries scan the cached authorized scope with deterministic JSON ordering and scope-bound page cursors. See [query semantics](query.md).

A first edit preserves its observed version. A following edit may depend on an actual predecessor ACK. Pulls never silently rebase edits; late ACKs preserve newer overlays and confirmed versions. Unknown outcomes replay the exact operation ID and payload. Explicit conflict retry/discard is required. Authorization failure or session mismatch purges and pauses; sign-out serializes with in-flight work. Offline caches cannot detect remote revocation.

Native cache ownership uses file/isolate guards. Browser IndexedDB uses one lifetime Web Lock per database identity, commits mirrors only on transaction completion, and fails closed if persistent storage/locking is unavailable. Browser eviction, backups and platform storage are app/OS boundaries; logical purge is not secure erase.

## Synchronization and capacity

Retained journal replay supplies contiguous per-scope order and tombstones. An optional bounded snapshot folds immutable events through a fixed head H, pages deterministically and adopts a data cursor at H only after local completion; writes during bootstrap remain available after H. Each snapshot page costs O(history). Interrupted bootstrap persists progress without claiming full coverage. Generation rotation triggers safe resnapshot, retaining pending identities.

SSE carries hints, with periodic authorization checks and bounded connections. It never supplies durable data or replaces polling. Foreground/reconnect synchronization resumes the saved data cursor. OS background delivery is not guaranteed. Cosmos Change Feed is not the client protocol and does not repair external writers.

History, receipts and tombstones have no TTL or GC. Conservative per-scope event/estimated-byte caps reject new writes while keeping accepted receipts replayable. Snapshot replay bounds, payload/page limits, request/stream concurrency and principal rate buckets bound runtime resources. [Performance](performance.md) explains measured local costs; no emulator result is a cloud RU or availability guarantee.

## Feature boundary

| Area | Delivered preview contract | Remaining boundary |
| --- | --- | --- |
| Cache | Native SQLite; Chromium IndexedDB/Web Locks | Browser eviction and unverified browsers/platforms |
| Documents | Durable offline put/delete, pending/ACK waits, watches | No field transforms or Firestore typed values |
| Queries | Finite local AST, metadata, deterministic pages/watches | Full-scope network sync; no server SQL/index planner |
| Conflicts | Explicit version conflict and retry/discard | No automatic merge/LWW/CRDT |
| Transactions | Atomic single-document server mutation in one scope | No offline or cross-partition transaction API |
| Sync | Journal, bounded snapshot, durable resume, tombstones | No unsafe compaction; bounded retained operations |
| Notifications | Authenticated SSE hints with polling recovery | No guaranteed push/background execution |
| Authorization | Validated API JWTs; durable personal scopes and fixed-owner shared reader/writer membership | Provider setup/linking, invitations, owner transfer, account deletion and generic security rules are separate work; legacy grants remain opt-in |
| Operations | Local/fault/emulator/platform tests and preparation | Approved live Azure RU/replica/backup/deployment gate |

The [staged identity-directory core](identity-directory.md) is separate from active
built-in authorization. Its bounded single-record Cosmos compare-and-swap models
explicit linking, proof replay and session generations; no production route or
factory enables it. Trusted upstream/fresh-auth proof and broker self-service
enforcement, complete session/cache integration and production capacity/recovery
remain required before activation.

The owner approved MIT, public GitHub/GHCR visibility, personal pub.dev ownership
and the experimental `0.2.0-dev.1` preview. The foundation is merged; subsequent
main integration and distribution are authorized and tracked in
[Epic #2](https://github.com/anaregdesign/cosmos-sync/issues/2). Actual registry,
provider, Azure and device results remain separate verification gates. The
original East US serverless attempt remains retained in ARM `Failed` state after
free-tier/capacity rejection. With subsequent owner approval, the West US2 Cosmos
account/database/container, private prerequisites and actual Container Apps
deployment were created successfully. The executable-only command repaired the
observed startup configuration conflict; the deployment retains min 0/max 1.
As of the 2026-10-04 resumed readback, app/environment provisioning succeeded, but
verified-TLS ingress still returns Envoy 403 despite the matching approved `/32`.
No SDK/cloud data write or ordinary hosted Flutter journey has passed.
Scale-to-zero does not remove fixed network/storage/logging charges. See the
[retained ACA record](aca-validation-plan.md). Actual hosted data and common
External ID OIDC acceptance remain separate gates. The owner removed actual
Google/Apple connections and configuration from this delivery on 2026-10-04 and
deferred physical Android checks until simulator development is complete; neither a mocked
plan nor local test establishes a hosted production SLA.
