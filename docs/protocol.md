# Wire protocol v0.2

All `/v1` endpoints require a validated OIDC access JWT. The BFF derives or authorizes partitions from identity and current server policy; request headers are assertions, never ownership authority. HTTPS is required outside explicit loopback development.

## Session and request binding

`GET /v1/session` returns `{scopeId, principalId, permissionVersion, scopeMode}`. The default mode is `user`. Legacy mode accepts `scope=user|tenant`: personal scopes/principals hash issuer/tenant/subject and authorized shared tenant scopes hash issuer/tenant. Its selected mode requires a current explicit grant.

Explicit builtin authorization accepts `scope=user` for the registered account's personal scope and `scope=shared&scopeId=<created ID>` for a membership-checked shared scope. Its principal is the durable issuer/subject account ID. IDs use distinct versioned namespaces and never adopt legacy data. The shared selector is 64 lowercase hexadecimal characters; duplicate scope selectors or malformed IDs are rejected. The owner has permission generation `1`; only an edited member's generation changes, including remove/readd. Other members' cursors remain valid.

Mutations, sync, snapshots and events send `X-Cosmos-Sync-Scope`, `X-Cosmos-Sync-Principal`, `X-Cosmos-Sync-Permission` and `X-Cosmos-Sync-Scope-Mode` from the verified session. Missing or mismatched assertions return 403 `session_mismatch` before data access. `X-Cosmos-Sync-Session` optionally echoes the BFF's opaque signed Cosmos consistency envelope. Its purpose and principal/grant/history context differ from every cursor. It is consistency metadata, never a Cosmos credential.

## Builtin account and membership management

These additional routes are available only with `authorization.mode=builtin`.
The staged internal identity directory adds no wire endpoints and does not
replace this account/session contract; see [its activation boundary](identity-directory.md).
`GET /v1/account` registers/returns `{accountId,personalScopeId}`.
`POST /v1/scopes` accepts `{operationId:UUID}` and returns the immutable creation
result `{scopeId,ownerAccountId,revision:1,members:[]}`; the verified creator is the
fixed owner. No caller owner/role fields are accepted.

Owner-only `GET /v1/scopes/{scopeId}/members` returns the current
`{scopeId,ownerAccountId,revision,members:[{accountId,role,permissionVersion}]}`.
Owner-only `POST` to the same path accepts
`{operationId:UUID,accountId,role:"reader"|"writer"|"none",baseRevision:integer}`.
Targets must already have a registered account. Policy/audit/receipt commit
atomically; exact replay returns the recorded response. Changed payload for an
operation returns 409 `idempotency_mismatch`; stale base returns 409
`membership_conflict`; owner changes return 409 `immutable_owner`; unknown
accounts return 404 `account_not_found`; nonowners return 403 `forbidden`.
Bodies are at most 4 KiB, revisions 1..10,000 and distinct retained member accounts
at most 128. Starting at revision 9,744, only rights reductions are accepted;
256 reserved revisions ensure every active member can be revoked. These online operations do not use the document outbox. Optional
`X-Cosmos-Sync-Principal` asserts the verified account and prevents a token-provider
identity switch. See [authorization](authorization.md) for limits and revocation.

## Documents and mutations

`Document = {id: string, data: JSON object|null, version: positive integer, deleted: boolean}`. Versions/sequences/preconditions are exact JSON integers at most `2^53-1`. Native and web reject unsafe integral JSON data rather than round it. IDs contain 1–128 ASCII letters/numbers, dot, underscore or hyphen, beginning with a letter/number. Data is bounded to 256 KiB on the BFF; the SDK uses a conservative 255 KiB bound. Unknown request fields and duplicate JSON keys are rejected.

`POST /v1/mutations` accepts `{operationId: UUID, documentId, kind: "put"|"delete", data: object|null, baseVersion: integer}`. Base zero means absent. Reply: `{document: Document}`. Metadata head, document, immutable journal event and receipt commit atomically inside one logical partition. Builtin mode also includes an ETag-conditional policy replacement as a fifth batch operation, preventing an old authorization from committing after a revocation commit. Receipt identity includes the authenticated principal and operation ID; its hash binds scope, principal, kind, document, data and original base. Identical replay returns the original result only with current write access; a changed payload returns 409 `idempotency_mismatch`. A stale base returns 409 `{code:"conflict",current:Document|null}`. Document/conflict responses reauthorize after storage; a denial after a pre-revocation commit does not prove rollback.

The SDK commits local acceptance before its write Future resolves. Confirmed data and pending overlays remain separate. A first edit records the observed server version; later pulls do not rebase it. Successors can depend on a predecessor's actual ACK. Before first transmission the exact resolved request is persisted. Retries never change an ambiguous operation. Explicit conflict retry creates a new operation ID; discard cannot remove a possibly committed unknown outcome.

## Journal and snapshot recovery

`GET /v1/sync?cursor=<opaque>&limit=1..100` returns `{changes:Document[],cursor:string,hasMore:boolean}`. Omit the cursor to replay from zero. Changes are contiguous per-scope committed sequences, including tombstones; there is no global/cross-partition order. Each page, resume cursor and consistency envelope commit together in local storage. A gap returns a retry error rather than claiming completion.

When enabled, `GET /v1/snapshot?cursor=<opaque>&limit=1..100` returns `{documents:Document[],cursor:string,syncCursor:string,cutoverSequence:integer,hasMore:boolean}`. The first request captures head H. Every page deterministically folds the immutable retained journal through H, including tombstones, and orders by ID. The signed snapshot cursor fixes H and offset. The final local commit adopts `syncCursor` at H; subsequent journal sync obtains H+1 onward. Intermediate pages retain incomplete coverage, durable snapshot progress and exact outbox identities. A newer confirmed ACK never moves backward. This is bounded replay, with O(retained history) work per snapshot page, not a Cosmos SQL snapshot. HTTP413 `snapshot_limit_exceeded` falls back to retained-journal bootstrap.

Cursor purposes are separate: `cursor-v1`, `snapshot-v1`, `events-v1`, and `session-v1`. All bind scope, principal, mode, permission version and configured history epoch. Invalid generation/signature/context returns 410 `resync_required`; the client clears confirmed coverage and resumes a snapshot or full journal while preserving pending identities and bases. Changing a grant instead follows the authorization purge policy.

Journal, receipts and tombstones have no TTL/garbage collection. Configured event/estimated-byte limits reject new writes with 507 `scope_capacity_exceeded` before storage growth crosses the supported envelope; accepted receipt retries still work. This preserves the replay horizon for all retained operations. Capacity increase and future compaction require explicit operator action and a separate recovery design.

## Change hints and browser requests

When enabled, `GET /v1/events` streams authenticated SSE. `Last-Event-ID` resumes a purpose-separated hint ID. An optional initial `cursor` query is a verified data cursor, not a bearer token. A `change` event has `id:<opaque>` and JSON `data:{cursor:<same opaque>,session?:<signed envelope>}`. It contains no document body. Hints may be duplicated, coalesced or lost and never advance the persisted data cursor. An `error` event terminates the stream with a typed authorization, resnapshot or store error. The BFF periodically revalidates JWT/grants; connection lifetime, stream count, heartbeat and write deadlines are bounded. The SDK reconnects with a fresh token and polling supplies correctness.

Browsers use streamed fetch with bearer authorization headers, not token URLs or cookie authentication. `allowedOrigins` is an explicit exact-origin list; wildcard origins are rejected. Preflight permits only supported routes/methods/headers. Responses expose the consistency envelope and Retry-After. Browser storage requires IndexedDB and lifetime exclusive Web Locks; unsupported persistent storage fails explicitly.

The ordinary [Flutter Web application](web-auth.md) keeps MSAL API/ID/refresh credentials in memory, separate from durable documents/outbox and SDK session/cursor metadata. A fresh document cannot restore offline authority: interactive sign-in and online BFF verification are required before reopening the retained cache. Native secure credential restore remains a separate application policy; neither platform derives cache ownership from client-decoded JWT claims.

## Errors and lifecycle

Errors are JSON `{code:string,...}`. HTTP401/403 purge local cache/outbox and pause synchronization, including a principal switch within a shared scope. Offline revocation is unknowable until reconnect. `await signOut()` waits for in-flight work before purging; close cancels notification/ACK waits and releases storage ownership.

Network/429/5xx failures preserve writes and apply persistent backoff with Retry-After. HTTP507 requires operator capacity action; blindly retrying cannot free retained history. A dry local enqueue is not server ACK: `waitForPendingWrites` captures the currently queued set, and later writes do not extend it. Conflict, discard, revocation and close fail that wait.
