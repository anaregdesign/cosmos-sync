# v0.2 product completion criteria

Status: target specification, checked on 2026-10-03. This document defines work to
finish and evidence to collect; it does not report that the target is delivered.
Implementation results belong in [verification](../verification.md), and release
authorization belongs in [release](../release.md).

Cosmos Sync is a Firestore-inspired offline document SDK backed by an OIDC Go BFF
and Azure Cosmos DB for NoSQL. A completed v0.2 lets a Flutter app read, observe,
edit and delete authorized documents while disconnected, retain accepted local
edits across restart, and converge after reconnect without silently discarding an
edit, crossing an authorization boundary, or skipping a deletion. It provides
documented local query semantics, native and Chromium browser persistence,
optional server-managed shared scopes, and resumable change notifications. It does not
claim Firestore API, query, transaction, conflict or billing compatibility.

## Definitions and supported boundary

- A **scope** is a server-authorized set of documents stored in one logical Cosmos
  partition. In explicit built-in mode, a personal scope belongs to a durable
  issuer/subject account and a shared scope has a fixed creator/owner with
  conditional reader/writer membership administration. Its server-issued opaque
  selector does not authorize access. Legacy mode retains existing user/tenant
  server grants without automatic migration. Neither mode authorizes access
  from a client ownership claim or an unvalidated partition ID. General
  group/organization membership discovery is outside this target.
- A **local acceptance** means the cache and exact durable outbox mutation have
  committed together. It does not mean the server has accepted the mutation.
- A **server acknowledgment** identifies the operation's immutable receipt and
  resulting document version. Retrying an operation must reuse its ID, payload
  and original version precondition.
- **Coverage through a cursor** means a completed replay of the authorized scope
  has been committed locally through that cursor. It is not a freshness promise,
  a snapshot spanning later edits, or a guarantee of current permission offline.
- A **notification** is a prompt to resume synchronization from a saved cursor.
  Data returned by authenticated synchronization is authoritative; notifications
  are allowed to be duplicated, coalesced, delayed or lost.

The v0.2 deployment contract is one Cosmos container with `/scopeId`, one write
region, and Session, Strong or Bounded Staleness account consistency. All managed
document changes go through the BFF mutation path. An app uses one active cache
owner per cache identity. Shared scopes have whole-scope read/write roles; no
document-specific ACL or cross-scope query is implied.

## Issue-ready delivery units

These stable IDs can be used in English GitHub issues. An issue closes only when
its acceptance evidence is recorded. Some release gates require a user decision
or an approved external environment; those blockers do not authorize creating
resources or publishing artifacts.

| ID | Issue title | Completion evidence |
| --- | --- | --- |
| PC-01 | Complete durable document state and conflict APIs | Native and web share local acceptance, pending, acknowledgment, retry, conflict and logout contracts, including restart and ambiguous network failures. |
| PC-02 | Add scoped local queries and coverage metadata | Finite query AST, deterministic pagination and local watches pass the semantic fixture matrix; cache coverage is never overstated. |
| PC-03 | Add browser persistence and cache ownership | IndexedDB transactions, browser reopen, writer exclusion, unsupported API and quota failures pass real browser tests; native migrations and exclusive ownership pass. |
| PC-04 | Add server-authorized shared scopes and revocation | Read/write roles, cross-member sync, isolated cache identities and grant changes pass BFF and SDK integration tests. |
| PC-05 | Complete resumable notifications and lifecycle recovery | Authenticated hints, disconnect/resume, poll fallback, token refresh, shutdown and revocation pass multi-client tests. |
| PC-06 | Define safe retention and resnapshot recovery | Published retention/offline limits, receipt replay horizon, history gaps and consistent snapshot cutover are validated; unsafe pruning is impossible. |
| PC-07 | Validate the official Go Cosmos adapter against the emulator | Actual SDK transactional batch, rollback, ETag, receipt, pagination and session propagation pass opt-in local and CI integration. |
| PC-08 | Complete cross-platform and protocol compatibility gates | Shared contract fixtures pass native/browser stores and Go HTTP; safe numbers, immutable payloads, upgrades and bounded input errors are tested. |
| PC-09 | Validate production Cosmos and operating limits | Approved live account proves replica consistency, authorization, RU costs, retention and recovery; resource budgets and supported account topology are documented. |
| PC-10 | Prepare and authorize package releases | Reproducible image and package contents pass build/dry-run; owner decisions and registry access are satisfied before any publication. |

## PC-01: durable document behavior

The public Dart API must distinguish local acceptance from server acknowledgment.
After opening the cache, get/list reads are synchronous local views, while
put/delete and other durable changes return Futures that must be awaited.
Document watches first emit the durable local view. Snapshots expose confirmed
version, pending writes, conflict/rejection state and cache origin. A status stream
reports pause, synchronization failure, next retry and coverage transitions. An
app can wait for an operation or a captured set of writes to be acknowledged;
newly queued writes must not indefinitely extend that captured wait.

A local put/delete commits the overlay and exact operation together before its
Future succeeds. Restart restores operation order, preconditions, retry schedule
and conflict state. Network loss, 429 and retryable server failures preserve the
operation and use bounded exponential backoff with jitter and `Retry-After`.
Authentication loss pauses transmission and follows the documented cache policy.

Concurrent writes use an explicit version precondition. A conflict preserves the
local intent and the current server version for application resolution. Retry or
discard is explicit. An acknowledged predecessor binds a following edit's base;
a later background pull must not silently rebase it. An old acknowledgment never
replaces a newer pending overlay. A possibly transmitted operation cannot be
discarded and recreated as a new operation until its outcome is known or the
caller explicitly abandons that outcome with documented consequences.

Acceptance includes lost acknowledgment/exact replay, mismatched replay payload,
delete/recreate, conflict then restart, multiple edits before the first
acknowledgment, retry across clock changes, in-flight logout and storage failure.
At each crash boundary the result is either a committed operation or an error;
no successful local write may exist only in an in-memory overlay.

## PC-02: finite scoped query semantics

The query API operates on the current authorized scope's local document views.
It accepts a validated, immutable AST rather than raw Cosmos SQL. AND filters
support equality, inequality, number/string ranges and array membership. Explicit
field-name segments distinguish a literal dotted key from a nested path. Missing
fields never match filters. Null matches equality with null only; inequality
excludes null. The exact supported JSON type comparison and ordering rules are
documented and tested on both native Dart and compiled web Dart.

Ordering excludes missing ordered fields and uses ascending document ID as the
final tie-breaker. Positive limits and exclusive pagination carry every ordering
value and document ID and bind to the query definition. Query page cursors and
server synchronization cursors are distinct types. Concurrent cache changes can
move a document across a page boundary; pagination is not a frozen snapshot.

Deleted views are excluded, and pending overlays participate in filtering and
ordering. Watches emit data and metadata changes, including completion of the
initial replay without changed result rows. A partial bootstrap, reset after a
history gap, purge, or cache replacement must clear coverage. A query result may
report coverage through a committed cursor only after full authorized-scope
replay, and must separately expose pending writes and offline freshness limits.

Tests cover null/missing/type boundaries, nested and dotted fields, tied order,
pagination under edits, tombstones, pending/conflict overlays, malformed ASTs and
coverage transitions. The API documents scan cost and a tested cache-size
envelope. Server filtering/indexed query subscriptions are future work; callers
must not assume a locally filtered result reduced network/RU costs.

See the detailed [local query contract](local-query.md).

## PC-03 and PC-08: native and browser stores

Native SQLite and browser IndexedDB implement the same atomic cache contract:
documents, outbox, cursor, consistency envelope and coverage metadata. Native
schema migration and browser database upgrade preserve accepted writes. Opening
an incompatible/corrupt store yields a typed error and does not silently destroy
pending writes. `:memory:` or any deliberate volatile store is explicitly marked
volatile and never advertised as restart persistence.

The browser adapter must wait for transaction completion, not an individual
request's success. An abort/quota failure leaves persisted state and the visible
in-memory mirror aligned. Request strict transaction durability where supported
and document that browser durability remains subject to the user agent and user
data deletion. Do not fall back to memory if persistent storage is unavailable.

One owner holds the cache identity for its lifetime. Native file/isolate rules and
browser Web Lock names must include database identity and authenticated scope.
A second tab either receives a typed busy result or waits with cancellation; it
must not load a stale mirror and later overwrite another owner's outbox. Closing
or crashing the owner permits a subsequent opener to reload durable state. Lock
stealing is unsupported. Browser storage is scoped to the application's origin;
the SDK must still isolate users/scopes within that origin.

Web uses supported `dart:js_interop` and `package:web` bindings and must not expose
`dart:io` imports through its selected public implementation. IndexedDB and Web
Locks require feature detection; unsupported environments fail with an actionable
error. Authentication/CORS requests and custom cursor/consistency headers pass
real browser integration. A deployment must use HTTPS except supported localhost
development contexts.

Protocol versions/sequences/preconditions must be exact integers in the
JavaScript-safe range (`2^53 - 1`) or use a future explicitly versioned string
representation. Document versions are positive; a cursor/absent base may be zero.
Nonfinite numbers and unsafe integers are rejected on both ends,
before persistence or transmission; rounding must never change a precondition.
Protocol fixtures verify JSON immutability and native/web numeric agreement.

Browser acceptance runs reopen/reload, transaction abort, quota failure, schema
upgrade, owner contention, close/crash recovery, unsupported APIs, logout during
a write and best-effort storage deletion. v0.2 requires a recorded Chromium run;
Firefox and Safari remain unverified until equivalent evidence is collected.
Compilation or mock storage tests alone do not qualify a browser as verified.
Native device/OS claims likewise
require recorded platform checks, not solely a macOS unit-test run.

## PC-04: shared authorization scopes

The BFF resolves a validated issuer/subject/tenant to authoritative grants. The
session's optional user/tenant selector returns only an authorized scope and its
role/permission version. Every session, mutation, sync and notification request
rechecks access. Read-only
members may synchronize but cannot mutate; write capability alone never implies
permission to select another partition. The server derives partition keys and
binds receipts, cursors and consistency envelopes to the resolved scope and their
documented actor/permission context.

Sessions also identify the authenticated principal independently from the scope.
Every mutation, sync and notification request asserts the verified principal,
scope and permission version in the protocol's expected-session headers. The BFF
compares those assertions against the current token/grant before any data access;
headers are never routing authority. This is essential when two principals share
the same tenant partition: scope/permission checks alone cannot detect a token
provider that changed users. Cache ownership and transport state bind to principal
as well as scope, and an unexpected principal triggers the account-switch purge
path. Header names and fields must be recorded in [protocol](../protocol.md).

Members of a shared scope observe one per-scope sequence and explicit conflicts.
Personal and shared scopes use separate cache identities, outboxes and cursors.
Changing scope does not relabel or replay another scope's pending mutations.
Changing membership/permission version invalidates old envelopes/cursors and
causes the SDK to pause and purge the affected cache according to its policy.
Purge must wait for in-flight store/network work to finish or reject their stale
generation so a late response cannot repopulate revoked data.

Offline reads reflect the last known grant, not immediate remote revocation. That
limitation must be visible in application guidance. Once the client learns that
access is revoked, document views, query watches, outbox and synchronization state
for that scope are cleared; no app-provided token can override revocation. Device
backup, screenshots or previously exported application data cannot be recalled.

Acceptance covers two writers, read-only denial, removed member, role downgrade,
stale permission version, fabricated scope, same subject across issuers/tenants,
scope switch and in-flight revoke. The authoritative grant source and operational
membership-management path must be explicit; development fixtures are not a
production identity/membership service.

## PC-05: notification and resume behavior

Notification transport is authenticated and authorized for the selected scope.
Hints expose no document body or membership information for another scope. A hint
never advances the saved synchronization cursor by itself. The client applies
ordered journal pages, tombstones and the returned cursor/envelope in one local
transaction. The trusted BFF validates contiguous journal sequence coverage before returning a page; the SDK validates protocol shape and monotonic document versions before its atomic cursor commit. Opaque cursors do not let the SDK independently prove a server history range.

Disconnect/reconnect, duplicated hints and a changed BFF instance must all resume
from durable state. Periodic polling supplies correctness when notifications are
lost or unavailable. Server-side notification lifetime, heartbeat, connection
limits, revocation checks and proxy timeouts are bounded. Permission loss stops
the connection and uses the same purge path as HTTP authentication failures.

Mobile/background suspension and browser throttling are expected; the SDK does
not promise continuous background execution. Foreground/resume refreshes identity
and synchronizes. Closing the client cancels waits/connections, releases ownership
and prevents further cache writes. Tests include notification-before-subscribe,
disconnect during a page, no notification, duplicate notification, token refresh,
server restart, network 429/5xx, account/scope switch and revoked subscription.

## PC-06: retention, gaps and recovery

Retention is an explicit server contract: supported offline duration, journal
retention, tombstone retention, immutable operation-receipt retention and cursor
epoch/expiration are published together. The receipt replay horizon must cover
the supported retry horizon. Expired receipts cannot cause an old ambiguous
operation to become an unconditionally new write. History/receipt storage and
per-scope growth have configured budgets and operator visibility.

For an unpruned journal, replay from zero is valid only while all history remains
available. Disable TTL on protocol records; capacity exhaustion must produce an
explicit retriable/operational error rather than silent deletion. If pruning is
enabled, a missing/expired history cursor yields a typed reset response and clears
coverage. A gap must never be interpreted as an empty complete page.

Production compaction requires a race-free checkpoint/snapshot protocol with a
watermark, epoch and handoff to events after that watermark. Pagination over
mutable documents is not such a snapshot. A checkpoint must include deletion
state and isolate later mutations while being built/consumed. Interrupted rebuild
remains incomplete until its final local commit. Exact in-flight operations and
receipts must remain reconcilable across reset; a resnapshot must not silently
drop or rebase the durable outbox. Epoch/key rotation and restored database state
must reject old cursors safely.

Acceptance covers writes/deletes while snapshot pages are fetched, interrupted
snapshot, cursor just before/after retention boundary, pending/lost-ACK operations
older than history, an internal sequence gap, receipt expiration and key/epoch
rotation. Compaction is not safe to enable based solely on a passing happy-path
replay test. A preview retaining all history may document PC-06 as incomplete;
it must enforce that retention mode and its capacity limit.

## PC-07 and PC-09: Cosmos and operating gates

Run the pinned official Go SDK against the official local Linux vNext emulator
using ephemeral databases and loopback-only opt-in endpoints. Gate atomic
document/head/event/receipt commit, ETag rollback, receipt races and exact replay,
ordered paginated bootstrap/incremental reads, deletion/recreation, partition
isolation and explicit session token propagation across independent clients.
An opted-in unavailable or failing emulator is a failed check, not a skipped pass.

The pinned local vNext build advertises Eventual consistency. The production
account guard must reject it; a test-only, loopback-restricted client factory may
omit that guard to exercise SDK/store behavior. Keep this exception confined to
integration-test construction, never a production configuration/authentication
bypass. Passing token propagation requests against this emulator does not prove
cloud Session consistency or production account-policy acceptance.

Account policy must reject missing/unsupported write-mode or consistency metadata.
Do not infer multi-write behavior from a writable-location array's cardinality
alone. Session envelopes must survive BFF instance changes/restart with the
documented shared signing-key policy. SDK errors and batch operation failures are
separate failure channels; neither may acknowledge an uncommitted mutation.

An approved live single-write-region Cosmos environment must separately establish
actual replica/session behavior, managed-identity RBAC, concurrent BFF instances,
regional failover/recovery, RU costs, throttling and custom-index effectiveness.
Emulator/fake-transport tests cannot supply that evidence. Record payload/page
limits, scope-size envelope, throughput/load fixture, latency/RU measurements and
backpressure behavior. One partition's head serializes mutations; shared scopes
must be sized for that contention and Cosmos logical-partition limits.

Direct portal/SDK imports, external writers, hard deletion or TTL on managed data
violate the journal/receipt contract. v0.2 either restricts write access to the
BFF or provides an authenticated administrative mutation path using the same
atomic protocol. External-change ingestion requires a separate reconciliation
design and remains unsupported. Do not claim that Cosmos Change Feed automatically
repairs mutations that bypassed the protocol.

## PC-10: reviewable release completion

CI must run static analysis, formatting, meaningful unit/contract/security tests,
native and browser persistence tests, cross-stack HTTP integration, official SDK
emulator integration and reproducible Docker/package builds. Record unsupported
or unverified platforms explicitly. Package dry-run contents must exclude cached
user data, tokens, development fixtures and credentials. README/examples must
demonstrate offline restart, pending/ack distinction, conflict resolution, queries,
shared scopes and revocation on the supported platforms.

Publication remains blocked until the owner decides the legal license, confirms
repository/source visibility and approves initial public publication, publisher
ownership, registry namespace/access and release version. GHCR identity and
GitHub Actions environment protections must be verified with existing authorized
credentials or owner configuration. A successful dry-run/build is preparation,
not permission to publish. Approved production deployment additionally needs
identity issuer/audience, grant source, Azure identity/resources and signing-secret
configuration; no credentials are sent to client applications.

## Explicit non-goals for v0.2

- Full Firestore SDK/API/query compatibility; arbitrary Cosmos SQL; joins, OR/IN,
  aggregations, collection groups, arbitrary functions or server query listeners.
- Firestore typed timestamps/references/bytes/vectors, server field transforms,
  automatic last-write-wins/CRDT merges or automatic conflict retry/rebase.
- Offline client transactions with server-wide atomicity, cross-partition batches,
  a global order across scopes or multi-write-region conflict resolution.
- Immediate revocation while fully offline, mandatory browser persistence under
  eviction/user deletion, transparent cache encryption/key management or guaranteed
  mobile/browser background execution.
- Automatic ingestion of arbitrary external Cosmos writes, hard deletes, TTL
  deletions or Change Feed events as a replacement for the journal protocol.
- Unlimited cache/scope/history size, production availability/latency/cost SLAs,
  or assurance that emulator behavior equals regional Azure behavior.

The selected scope can be expanded in later specifications. Missing features must
remain explicit differences rather than being hidden behind a Firestore parity
claim. Research supporting these boundaries is in [research-next](../research-next.md).
