# v0.2 research and verification boundaries

Checked on 2026-10-03 using vendor documentation, pinned official SDK source and
web-platform standards. Versions below are observations on that date, not release
guarantees. [Product completion](spec/product-completion.md) defines project
requirements; the statements here distinguish source facts from selected design
and remaining verification.

## Cosmos emulator: actual SDK integration is possible

Microsoft's Linux **vNext** image is
`mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-latest`. Its NoSQL
gateway feature table includes batch, change feed, partitioned collections and
ordered/paginated queries; official examples cover x64 and ARM64 Go CI. Defaults
include gateway 8081 and health probes on 8080. Use readiness probes, choose HTTP
only for loopback development or configure HTTPS, and disable optional telemetry
for this test fixture. Custom indexing is a no-op and RU simulation is absent.
These are facts from [Microsoft's vNext emulator guide](https://learn.microsoft.com/en-us/azure/cosmos-db/emulator-linux).

The [general emulator guide](https://learn.microsoft.com/en-us/azure/cosmos-db/emulator)
distinguishes the older Linux image's ARM limitation from the vNext alternative.
Emulators do not reproduce Azure geographical replication or scale. The guide's
Windows consistency flags do not implement actual consistency behavior.

**Project decision:** use the pinned Go SDK for real local batch/ETag/session
requests, fail an explicitly enabled suite if its emulator is unavailable, and
keep live replica consistency, managed identity, RU/load/index and failover gates
open. A feature-table entry does not prove rollback or session semantics; test
them. Pin a tested image digest in reproducible CI once selected, since a mutable
`vnext-latest` tag can change behavior.

**Repository observation, not a Microsoft-wide consistency guarantee:** the pinned
local vNext build EN20260907 advertises Eventual consistency. The integration suite
has a test-only loopback client without the production account guard, plus a test
that the real guard rejects this metadata. This permits actual SDK/store tests;
it supplies no cloud Session or production account-policy evidence. Keep the
exception out of the production entrypoint and report the image digest/results.

## Official Go SDK: use supported batch, OCC and explicit sessions

The repository pins `azcosmos` v1.5.0. Its source exposes transactional batch
`SessionToken string`, per-item `IfMatchETag`, and batch result `Success` and
`OperationResults`. Ordinary item/query options also accept session tokens.
`QueryItemsResponse` embeds the general response rather than a typed session
field, so read `x-ms-session-token` from `RawResponse`. Inspect both Go errors and
batch success/operation statuses. See the official pinned
[batch options](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_transactional_batch_options.go),
[batch response](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_transactional_batch_response.go),
[item options](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_item_request_options.go),
[query options](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_query_request_options.go),
and [query response](https://github.com/Azure/azure-sdk-for-go/blob/sdk/data/azcosmos/v1.5.0/sdk/data/azcosmos/cosmos_query_response.go).

Microsoft documents [session tokens as partition-bound](https://learn.microsoft.com/en-us/azure/cosmos-db/consistency-levels)
and describes flowing them between web tiers when client instances differ.
The source comments themselves discuss multiple web nodes. **Selected design:**
carry consistency data in a signed scope/permission-bound envelope and persist it
atomically with cache progress; it is not a Cosmos credential. Do not assume a
process-local SDK client provides end-user continuity across BFF replicas.

The SDK supports the required official API; custom Cosmos REST is unnecessary.
The actual account policy must prove supported consistency and explicitly disabled
multi-write mode. No source checked establishes that a writable-location array's
length alone is a reliable single-write predicate. Treat missing/unsupported
metadata as a deployment error and test actual failover separately.

## Ordering, retention and resource boundaries

Microsoft's [transactional batch documentation](https://learn.microsoft.com/en-us/azure/cosmos-db/transactional-batch)
limits atomic operations to the same container/logical partition, up to 100
operations, 2 MB and five seconds. [Partitioning](https://learn.microsoft.com/en-us/azure/cosmos-db/partitioning)
describes logical-partition storage/throughput limits; a shared scope also adds
head-record contention. A global transaction/order across scopes is unsupported.

The [Change Feed guide](https://learn.microsoft.com/en-us/azure/cosmos-db/change-feed)
states ordering is per partition key, not global; batch changes may not have a
useful internal timestamp order. [Change Feed modes](https://learn.microsoft.com/en-us/azure/cosmos-db/change-feed-modes)
distinguish latest-version changes from all-versions-and-deletes, whose continuous
backup and retention prerequisites do not create an unlimited historical stream.

**Selected design:** retain application tombstones and immutable per-scope journal
events, require contiguous sequence replay, and disallow external writes/TTL on
managed records. Bound receipt replay and history retention together. Future
compaction needs a consistent checkpoint and epoch; scanning mutable documents
and then subscribing to Change Feed is not a proven gap-free handoff.

## Native and web package observations

| Package/source | Current observation | Implication for this project |
| --- | --- | --- |
| [sqlite3](https://pub.dev/packages/sqlite3) | 3.7.0; native and web SQLite APIs, with common interfaces; web needs the package's compatible WASM asset and persistent filesystem setup. | Existing native cache remains suitable. Using SQLite on web would require artifact deployment and persistent VFS testing. |
| [web](https://pub.dev/packages/web) | 1.1.1, published by dart.dev; browser API bindings for supported JS interop. | Direct IndexedDB/Web Locks can avoid distributing SQLite WASM for the selected web adapter. |
| [drift](https://pub.dev/packages/drift) | 2.35.1; maintained SQLite layer with migration, reactive queries and native/web support. | Optional future alternative; adding it is not required to share the cache contract. |

Package support lists are not this repository's device/browser test results.
[Dart JS interop](https://dart.dev/interop/js-interop) supports web JavaScript and
WebAssembly targets and recommends current interop APIs. Its availability does
not guarantee that a browser exposes every required storage API.
[Flutter's offline-first guide](https://docs.flutter.dev/app-architecture/design-patterns/offline-first)
describes local/remote repository coordination and synchronization choices.
**Selected design:** local acceptance and remote acknowledgment are separate;
status/coverage and conflict state are explicit. Keep background execution limits
visible to applications.

## Browser storage: atomicity, ownership and honest durability

[IndexedDB 3.0](https://www.w3.org/TR/IndexedDB/#transaction-lifecycle) specifies
transaction lifecycle, automatic commit/abort and a `complete` event after commit.
An individual request's success is insufficient. Its durability option is a hint;
`strict` increases persistence confidence but does not promise immunity to data
loss. Transactions become inactive between appropriate event tasks, so network
awaits do not belong inside the transaction's read/write lifecycle.

The [W3C Web Locks draft](https://www.w3.org/TR/web-locks/) provides cooperative
exclusion within a storage bucket across tabs/workers, requires a secure context,
and holds a lock until its callback promise completes. Its `steal` option can
leave old code running without exclusive guarantees. The
[WHATWG Storage Standard](https://storage.spec.whatwg.org/) makes best-effort the
default, permits persistent-storage requests, and specifies storage-pressure
clearing and user-driven clearing. Persistence is an origin/storage policy, not
an authorization boundary or backup guarantee.

**Selected design:** IndexedDB-backed cache rows, a lifetime exclusive Web Lock,
transaction-complete acknowledgment, and typed unavailable/busy/quota errors.
Never silently fall back to volatile memory or publish an in-memory mirror before
durable transaction success. Request strict durability where supported; expose
and document best-effort persistence. Browser-compatible protocol numbers must
be checked before use; unsafe version rounding cannot be allowed to alter OCC.

Required browser tests include reload exact replay, transaction abort with mirror
rollback, owner contention/recovery, quota failure, schema upgrade, unsupported
APIs, logout/revocation during in-flight work and storage deletion. Cross-browser
results must record tested versions; JavaScript compilation alone is not proof.

## Release decisions and external evidence

[GitHub container registry documentation](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
supports repository Actions publication using the existing `GITHUB_TOKEN` with
appropriate permissions. Registry namespace/access and actual repository-plan
environment protections need verification rather than assumed availability.
[Dart publishing](https://dart.dev/tools/pub/publishing) and
[automated publishing](https://dart.dev/tools/pub/automated-publishing) describe
package validation and trusted GitHub publishing setup. A dry-run does not publish
or resolve license, publisher ownership and source-visibility decisions.

No research result authorizes publication, a legal-license choice, broader OAuth
permissions, new tokens, cloud resources or deployment. Those remain owner
decisions. Production claims additionally require approved Azure/identity/grant
configuration and live evidence; local SDK/emulator/browser work can proceed
independently under the existing development authorization.
