# Architecture and supported scope

Cosmos Sync is an early Go BFF and native Dart offline SDK for Azure Cosmos DB for NoSQL. It offers a small document-sync protocol; it does not claim Firestore API/behavior compatibility.

## Trust and storage

Apps hold OIDC access tokens for the BFF. The BFF validates signing keys, issuer, audience and time validity and then checks its current server-managed tenant/subject grants. The issuer, tenant and subject derive a stable scope/partition hash. A separate permissionVersion invalidates cached authorization context and cursors when grants change without moving stored documents. Clients cannot select a Cosmos partition or execute arbitrary Cosmos queries. User scopes are isolated; shared tenant data and per-document ACLs are future work.

The Go adapter uses the official `azcosmos` SDK. A mutation reads a scope's metadata and current document, verifies the requested base version, then atomically writes metadata sequence, document, immutable journal event and idempotency receipt in one logical partition. An ETag condition on metadata serializes concurrent commits. Batch success and individual operation status must both be checked. A receipt binds operationId to its canonical request hash, so an acknowledged retry returns the same document and a different payload is rejected. Grants are rechecked before receipt lookup.

Clients never receive Cosmos keys, managed-identity access tokens or resource tokens. A signed `X-Cosmos-Sync-Session` envelope carries only consistency metadata to let another BFF replica request the same Cosmos session. It is scoped, integrity protected and purpose separated from sync cursors. Cosmos SDK verification against a real account/emulator is still required before production assurance.

## Offline state machine

The native SQLite cache stores confirmed server documents separately from pending local operations. A local edit is durably committed before it is exposed as pending. Reads overlay the latest pending edit on the confirmed base. The first pending edit records the confirmed version observed at enqueue; a later edit may depend on the preceding local ACK. Receiving newer server data cannot silently rebase an existing local edit. Synchronization sends mutations serially and durably locks any resolved dependency version before first send; retries retain the same operationId and payload. A late ACK updates the confirmed base and removes only its own operation, preserving later edits.

A 409 version conflict stops writes for that document and exposes the current server version for explicit resolution. Discard removes the conflicting edit; retry creates a fresh operationId against the selected server version. There is no implicit last-write-wins. Network, 429 and transient server failures retain pending data for a later attempt. Retry scheduling must honor backoff/Retry-After without a busy loop.

Before any queued data is sent, `/session` must match the SDK's expected scope and permissionVersion. Each mutation/sync also asserts that expected scope/permission in headers and the BFF compares them with its derived identity before routing or writing, closing a token-provider account switch between requests. A mismatch or 401/403 purges the cache/outbox and pauses the client under the conservative v0 policy. Applications should clear/close the old client at logout and isolate cache paths per account. Revocation cannot be known while disconnected; physical disk remanence/encryption and client compromise are outside this prototype's guarantees. Do not put secrets in document data.

## Sync, deletion and ordering

Initial sync replays the retained immutable journal from sequence zero. Incremental sync resumes an opaque HMAC cursor bound to protocol generation, scope and permissionVersion. Applying a received page and its cursor is one local SQLite transaction; process failure before commit repeats the page safely. Document versions never move backward. Concurrent bootstrap writes stay in the journal and appear on a subsequent page or poll; no SQL-snapshot/change-feed cutover race is introduced.

Each committed user-partition mutation increments a sequence. No cross-user/global ordering or cross-partition atomicity is offered. Deletes append tombstones rather than physically deleting items. Delete/recreate requires the tombstone's version as the base. The v0 journal, tombstones and receipts have no TTL and grow over time. This trades RU/storage cost for restart/replay safety. Compaction, restore, retention and generation rollover require an explicit expired-cursor resync protocol and are future work. Client timestamps and Cosmos `_ts` are not resume cursors.

Change notification in v0 is a periodic SDK poll of the authorized durable sync endpoint. It finds server changes while running and connected, without a websocket/SSE delivery guarantee. Device restart/reconnection resumes from the persisted cursor. Cosmos Change Feed is not the client protocol; future feed-driven fanout must preserve retained tombstones and per-partition constraints described in [research](research.md).

## Feature boundaries

| Area | First slice | Follow-up/limit |
| --- | --- | --- |
| Flutter use | Pure Dart API with native SQLite IO adapter | Web IndexedDB/WASM adapter and measured mobile/platform matrix |
| Offline reads/writes | Local cached documents, pending overlay, durable outbox | Data never downloaded is unavailable offline |
| Queries | Local document collection/read API | No Firestore query AST, collection groups, server query planner or completeness claim |
| Conflict handling | Explicit version conflict + retry/discard | No automatic merge or implicit LWW |
| Transactions | Server mutation atomic inside one user partition | No offline transaction or multi-document client transaction API |
| Sync | Initial journal replay, incremental/resume, tombstones | Efficient snapshot/compaction and retention window |
| Notifications | Periodic sync polling | Durable external fanout, push/background OS execution |
| Authorization | OIDC access JWT + current server scope grants | External grant store, shared data, document ACLs |
| Cache security | Identity isolation and conservative purge | OS secure storage/database encryption; purge is not secure erase |
| Production | Adapter and failure/concurrency tests | Live Cosmos, load/RU/recovery tests and deployment approval |

## Roadmap

1. Validate live Cosmos SDK behavior, session consistency across replicas, native platform distribution and crash/recovery tests in an approved emulator/account.
2. Extend retry/background scheduling policies, snapshot/retention generation protocol, encrypted/platform cache options and operational metrics.
3. Add explicit shared-scope ACLs and a narrow tested query model before any Firestore-like query claims.
4. Add feed-driven notification fanout, sustained load tests and supported release/version policy.
