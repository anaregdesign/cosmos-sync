# Architecture and supported scope

Cosmos Sync v0.2 is an unpublished Go BFF and Dart/Flutter offline SDK for Cosmos DB for NoSQL. It provides a finite document protocol and cache query model inspired by Firestore, with explicit differences. The [product contract](spec/product-completion.md) defines the bounded completion target; [verification](verification.md) records actual evidence.

## Server boundary

OIDC access JWT verification precedes current server grants. User and optional shared tenant modes derive a single logical partition; a separate principal identifies the caller. Each request asserts the verified principal/scope/mode/permission version, protecting against token-provider switches even between members sharing one partition. Shared scopes have whole-scope read/write roles, without per-document ACLs. Grants are read from the server file per request and must be atomically distributed to replicas.

The official Go `azcosmos` adapter uses ETag-conditional transactional batches to write head, document, immutable journal and principal-bound receipt atomically. Both batch and individual-operation results are checked. A head serializes writes within a partition; it creates contention for large shared scopes. Signed consistency envelopes propagate Cosmos session metadata across BFFs. Account policy rejects multi-write, missing metadata and weaker-than-Session consistency. Production requires one write region and a `/scopeId` container with TTL disabled.

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
| Authorization | OIDC and current user/shared-tenant grants | Production identity/grant administration remains owner configured |
| Operations | Local/fault/emulator/platform tests and preparation | Approved live Azure RU/replica/backup/deployment gate |

License, source visibility, publisher ownership and actual distribution remain owner decisions tracked in issues #14–16. No paid Azure resource, publication, merge or deployment is performed by this preview work.
