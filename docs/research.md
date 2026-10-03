# Official-source research and design rationale

Checked on **2026-10-03**. This project targets **Azure Cosmos DB for NoSQL**. The facts below come from Microsoft, Dart/Flutter, and GitHub documentation; the implications describe this project's engineering decisions. They are not claims of Firestore compatibility or evidence of production deployment.

## BFF runtime and SDK

Use **Go**, as requested by the owner, with Microsoft's official `github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos` SDK. Microsoft lists the Go SDK as a supported NoSQL client and recommends using its current stable release. [Cosmos Go SDK](https://learn.microsoft.com/en-us/azure/cosmos-db/sdk-go)

The checked stable release is **azcosmos v1.5.0**, released in July 2026; v1.6.0 releases are previews. The stable release includes transactional batches, parameterized single-partition queries, ETag options, session tokens, `ReadFeedRanges`, and `ReadChangeFeed`. Its changelog records that the external cross-partition query engine was removed from v1.5.0 GA and returned in v1.6 previews. [Official Azure Go SDK changelog](https://github.com/Azure/azure-sdk-for-go/blob/main/sdk/data/azcosmos/CHANGELOG.md)

The pinned SDK module declares **Go 1.25.0**. CI, Docker, and the development toolchain must satisfy that requirement; requirements from older SDK releases are insufficient. [azcosmos v1.5.0 go.mod](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/go.mod)

The SDK's actual Go API provides the capabilities required by the first slice:

| Capability | Pinned v1.5.0 API and handling |
| --- | --- |
| Atomic mutation | `container.NewTransactionalBatch(partitionKey)`; add `CreateItem`, `ReplaceItem`, or other point operations; call `container.ExecuteTransactionalBatch(ctx, batch, options)`. |
| Batch concurrency check | `TransactionalBatchItemOptions.IfMatchETag` is `*azcore.ETag`; conditional replace/delete/upsert/patch serialize it into the operation. Create/read do not use this condition. |
| Commit result | Check `TransactionalBatchResponse.Success` and `OperationResults` in addition to the returned Go error. Results contain individual status codes, ETags, and optional bodies. |
| Response body | `TransactionalBatchOptions.EnableContentResponseOnWrite` defaults false; enable it only where operation bodies are needed. |

Sources: [container operations](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_container.go), [batch operation serialization](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_transactional_batch.go), [batch options](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_transactional_batch_options.go), [batch response](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_transactional_batch_response.go).

Point operations use `ItemOptions.IfMatchEtag` (the spelling differs from batch `IfMatchETag`). `ItemOptions.SessionToken` and `ItemResponse.SessionToken` are `*string`; query options likewise accept `*string`, while batch options/responses use `string`. [Item options](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_item_request_options.go), [item responses](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_item_response.go), [query options](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_query_request_options.go)

`QueryItemsResponse` has no dedicated `SessionToken` field; use its embedded response's `RawResponse.Header` if capturing the returned `x-ms-session-token` header. Query paging is continued with `ContinuationToken`, a separate concept from session consistency. [Pinned query response type](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_query_response.go)

Session consistency guarantees read-your-writes when the relevant session token is shared; tokens are partition-bound and must remain opaque. A newly created client with no token does not inherit another client's session. [Cosmos consistency levels](https://learn.microsoft.com/en-us/azure/cosmos-db/consistency-levels)

**Implementation implication from inspected source:** use explicit per-partition session-token propagation for reads after writes; do not assume independent BFF instances automatically share it. The request-option implementations serialize supplied tokens, and the inspected Go client pipeline does not provide a session-token persistence policy. Cross-instance continuity requires a deliberately designed shared state or signed continuation mechanism. Keep Cosmos tokens inside the BFF's trust boundary. The same client offers `NewClient(endpoint, azcore.TokenCredential, options)` for Entra authentication and `NewClientWithKey` for server-side key authentication. [Go client pipeline](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_client.go)

**Project decisions:** reuse the SDK client and Go HTTP transport, apply context deadlines, pin modules in `go.mod`/`go.sum`, and configure existing database/container names. Enforce a strict document-ID allowlist: the pinned batch serializer directly interpolates item IDs into JSON, so quotes, backslashes, and control characters must never reach it. Keep the journal queries explicitly partition-scoped and disable cross-partition querying in `QueryOptions`.

## Authentication and authorization boundary

The API accepts an OIDC provider's **access JWT**, not an ID token. The Go verifier must validate signature, configured issuer, configured audience, and expiry. Production configuration requires HTTPS metadata and an explicitly trusted authority; self-issued tokens are only suitable for isolated tests. These are Microsoft's documented API token-validation requirements, independent of the framework used by its example. [Microsoft JWT bearer validation guidance](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/configure-jwt-bearer-authentication?view=aspnetcore-10.0)

Authentication alone does not authorize access to a particular document. Application code must evaluate the user and resource/operation. [Microsoft resource-based authorization guidance](https://learn.microsoft.com/en-us/aspnet/core/security/authorization/resource-based?view=aspnetcore-10.0)

**Current project decision:** explicit built-in authorization maps a verified
issuer/subject to a durable opaque account and personal scope. Fixed-owner shared
scope memberships are stored and conditionally administered in Cosmos; provider
roles/groups do not replace them. Legacy mode retains the original tenant/subject
grants. The BFF derives the partition and checks current read/write permission on
requests, journal reads and notification hints. Request bodies and cursors cannot
grant owner or partition access. Issuers must be allowlisted; subjects are meaningful
only in their issuer namespace. See the [authorization contract](authorization.md).

Cosmos native data-plane RBAC scopes to an account, database, or container; its most granular documented role scope is a container. SDKs can authenticate with a server-side `TokenCredential`. [Cosmos data-plane RBAC](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-connect-role-based-access-control)

**Implication:** Cosmos RBAC protects the BFF's service identity, while BFF policy protects end-user partitions. Prefer a managed identity with container-scoped permissions in an eventual Azure deployment. Account keys, service credentials, and privileged Cosmos resource tokens never enter the Dart client. No Azure resource or identity is created by this scaffold.

**Revocation decision:** session identity and a server permission version gate outbox delivery and cursor acceptance. The client clears cached documents, cursor, and queued writes when scope/permission changes or access is denied. The initial protocol also conservatively purges/pauses on HTTP 401/403. The app must explicitly clear state on sign-out. An offline device cannot learn about a remote revocation until it reconnects; local data protection, token refresh policy, and sensitive-data offline lifetimes remain application/deployment responsibilities.

## Transactions, versions, and partition limits

Cosmos transactional batches commit or roll back point operations together **within one container and one logical partition**. Limits are 100 operations, a 2 MB payload, and five seconds of execution. Failed operations expose their status; other operations fail with dependency status 424. [Transactional batch operations](https://learn.microsoft.com/en-us/azure/cosmos-db/transactional-batch)

**Project decision:** a mutation changes a document, appends an immutable journal item, creates an operation receipt, and advances the partition sequence in one batch. The receipt binds operation ID to payload, so a retry can replay the result while reusing that ID with a different mutation fails. A partition sequence provides order only for that scope; it creates a contention point that must be measured. Do not promise cross-user transactions.

An item's `_etag` changes on updates. `If-Match` allows conditional replacement, with HTTP 412 on a stale ETag. Multi-region writes can accept updates locally before conflict resolution in the hub region. [Cosmos transactions and optimistic concurrency](https://learn.microsoft.com/en-us/azure/cosmos-db/database-transactions-optimistic-concurrency)

**Implication:** external document versions are server-assigned application values; SDK/storage code uses ETag checks to prevent concurrent sequence and document overwrites. Never parse an ETag as a timestamp or incrementable integer. The first slice should use a **single write region**. Multi-region writes require a separately validated conflict and sequencing design before support is advertised.

A logical partition normally has a 20 GB storage and 10,000 RU/s ceiling. A partition key is immutable, and moving an item between different logical partitions is not atomic. Uneven traffic creates hot partitions; a future hierarchical/bucketed partition design would change transaction and cursor boundaries. [Cosmos partitioning](https://learn.microsoft.com/en-us/azure/cosmos-db/partitioning)

## Change Feed and synchronization

Cosmos Change Feed orders changes per partition key, without guaranteed order across partition values. Items modified by a transactional batch, stored procedure, or bulk request can share a modification timestamp and appear in any order. Reads consume the account's throughput; automatic processor checkpointing provides at-least-once processing. [Change Feed overview](https://learn.microsoft.com/en-us/azure/cosmos-db/change-feed)

Latest-version mode omits hard deletes and intermediate item versions. A soft-delete update can be observed only while the item remains retained. All-versions-and-deletes mode requires continuous backup, permits reads only within its retention window, and cannot start at container creation or an arbitrary past timestamp. It also excludes accounts that have used partition merge. [Change Feed modes](https://learn.microsoft.com/en-us/azure/cosmos-db/change-feed-modes)

The Go SDK does provide Change Feed pull APIs. In the inspected v1.5.0 API, `ChangeFeedOptions` supports a partition key, feed range, time, and continuation, but does not expose an all-versions-and-deletes mode selector. A future notification worker can investigate supported pull behavior; v0 neither needs nor advertises that richer feed mode. [Pinned Go Change Feed options](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_change_feed_request_options.go)

**Project decision:** protocol v0 uses a retained, immutable application journal and retained tombstones rather than exposing raw Change Feed. Initial sync replays that journal; subsequent sync uses a signed scope/permission-bound cursor. There is no journal, tombstone, or receipt TTL in v0. This favors correctness for long offline periods while explicitly accepting growing storage and RU costs. Arbitrary writes made outside the BFF do not become journal events and are unsupported.

Future Change Feed consumers must not use item `_ts`, `_etag`, or `_lsn` as a global application cursor. Pull reads support one partition and resumable continuation tokens. Empty successful responses do not necessarily mean the feed is drained; consumers continue until `NotModified`. Commit a durable local checkpoint only after applying its full page. [Change Feed pull model](https://learn.microsoft.com/en-us/azure/cosmos-db/change-feed-pull-model)

Cosmos query continuation tokens bookmark stateless query execution; their documented lifetime is tied to using the same SDK version. [Cosmos query pagination](https://learn.microsoft.com/en-us/cosmos-db/query/pagination)

**Future design implication:** do not represent a paginated query over mutable documents as a transactionally frozen initial snapshot. A compaction/snapshot feature needs a race-free boundary with the journal, a history epoch, expired-cursor handling, and a full-resync procedure. Deleted history cannot silently disappear while a client still trusts an older cursor.

## Dart and Flutter offline API

Flutter's offline guidance recommends repositories combining local and remote sources, streams that can emit local data before refreshed remote data, writes stored locally before network delivery, and explicit synchronization state. It also warns that continuous background work affects battery life and can be limited by devices. [Flutter offline-first support](https://docs.flutter.dev/app-architecture/design-patterns/offline-first)

**Project decision:** expose local reads/watch streams, durable pending/conflict state, a persisted outbox, explicit synchronization, bounded retry with jitter, and resume cursors. Saving the optimistic document and outbox entry must succeed together before acknowledging a local write. A network timeout after server commit must retry the exact same operation ID and payload. Stale versions surface conflicts for explicit resolution, rather than silently applying last-write-wins. Notification delivery is a sync hint; pulling the durable journal establishes state after reconnect.

Cosmos SDKs already retry throttling; application layers must avoid unbounded retry amplification. [Cosmos HTTP 429 guidance](https://learn.microsoft.com/en-us/azure/cosmos-db/troubleshoot-request-rate-too-large)

**Implication:** respect `Retry-After`; retain queued writes on connection failures, 429, and transient 5xx; pause a conflicted document without blocking unrelated documents. Persist the assigned base version before first send. Pending status is a local promise, not a promise that the server has accepted the write.

`dart:io` supports non-web Flutter/Dart platforms. Web uses browser APIs through `package:web` and JavaScript interop. [Dart core libraries and platform support](https://dart.dev/libraries)

**Scope:** the initial file-backed cache is for native Dart/Flutter clients. Flutter Web needs a separate transactional browser store and transport adapter before it is advertised. This SDK is inspired by Firestore's developer experience; it does not promise Firestore query syntax, security rules, cross-document transactions, global ordering, automatic background delivery, or complete compatibility.

## Package publication preparation

GHCR stores Docker and OCI images. Publishing from Actions can use `GITHUB_TOKEN` for packages associated with the workflow repository, without creating a new PAT. A first-published package is private by default. A source-repository OCI label connects the package; linked package permissions normally inherit unless organization policy disables inheritance. [GitHub Container registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)

An eventual GHCR publishing job needs `contents: read` and `packages: write`, authentication to `ghcr.io`, and build tags/labels. GitHub recommends pinning actions to commit SHAs. Extra attestation/OIDC permissions are only needed if those features are used. [GitHub Actions Docker image publication](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images)

**Current boundary:** CI builds/tests the image; publication requires a separately authorized release. No workflow push or PR should publish a package during bootstrap. Do not set an OCI license identifier before the owner selects a legal license. Package/repository visibility is a separate owner decision.

`dart pub publish --dry-run` validates the package and lists proposed files without uploading. A package needs an appropriate `LICENSE` and redistribution rights. Published versions generally remain available permanently. An organization can use a verified publisher backed by domain verification, or publish through an authorized Google account. [Dart package publishing](https://dart.dev/tools/pub/publishing)

`publish_to: none` prevents publishing; explicit platform metadata controls advertised platform support. [Dart pubspec reference](https://dart.dev/tools/pub/pubspec)

Pub.dev's Actions publishing uses temporary GitHub OIDC tokens with `id-token: write`. The package uploader/publisher admin configures the repository and version-tag pattern on pub.dev; only tag-push-triggered workflows are accepted. Environment restrictions and protected release tags can limit release authority. [Pub.dev automated publishing](https://dart.dev/tools/pub/automated-publishing)

GitHub environment protection depends on the plan and repository visibility. Private environments require Pro, Team, or Enterprise; required reviewers are available only for public repositories on Free/Pro/Team. Merely referencing a new environment in YAML creates an unprotected environment. Verify the organization's actual protection capability before relying on a release approval gate. [GitHub deployment environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)

**Remaining release decisions:** legal license, public package intent, publisher/account ownership and domain, first release version/API scope, permitted CI release trigger, and production OIDC/grant/retention configuration. Name availability checks are point-in-time checks, not reservations. Keep actual publication disabled until those decisions and authorization are recorded. Repository visibility changes, Azure paid resources, deployment, and merging remain outside this bootstrap.
