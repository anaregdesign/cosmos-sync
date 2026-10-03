# Cosmos Sync requirements

Build a private monorepo for an authenticated Azure Cosmos DB for NoSQL BFF and a Flutter-compatible Dart SDK. Apps can read and write locally while offline, retain pending operations across process restart, synchronize when connectivity returns, and explicitly resolve conflicts. This is an early SDK, not Firestore compatibility.

## First delivery acceptance

- Go BFF validates OIDC access JWT signature, issuer, audience and expiry. Server-managed grants enforce tenant/user access and derive the logical partition. No Cosmos key or privileged token reaches clients.
- A usable vertical slice supports documents, durable local cache/outbox, pending state, replay-safe writes, version conflict handling, retained deletion tombstones, initial and incremental sync, resume cursors and polling change hints.
- Concurrent writes use optimistic concurrency. Atomic document, journal and receipt writes occur in one Cosmos logical partition. No cross-partition transaction or global ordering is promised.
- Revoked or mismatched identity clears local data and pauses synchronization. Offline permission revocation cannot be detected without reconnection.
- Automated BFF and Dart tests, Docker build, CI, publish preparation, examples, operational/security documentation and feature limitations accompany the slice.
- Repository is private. Code is pushed on an independent branch with a draft PR. No Azure paid resources, visibility changes, package publication, merge, deployment or license selection occur.

## Later milestones

Efficient snapshot compaction and expiring cursors, shared tenant documents and fine-grained ACLs, realtime fanout, encrypted/platform browser cache adapters, query indexes, production RU/retention/load testing and live Cosmos integration tests. These must be distinguished from delivered behavior.
