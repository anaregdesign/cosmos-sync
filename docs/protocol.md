# Wire protocol v0.2

All `/v1` endpoints require a validated OIDC access JWT. The BFF derives or authorizes partitions from identity and current server policy; request headers are assertions, never ownership authority. HTTPS is required outside explicit loopback development.

## Session and request binding

`GET /v1/session` returns `{scopeId, principalId, permissionVersion, scopeMode}`. The default mode is `user`. Legacy mode accepts `scope=user|tenant`: personal scopes/principals hash issuer/tenant/subject and authorized shared tenant scopes hash issuer/tenant. Its selected mode requires a current explicit grant.

Explicit builtin authorization accepts `scope=user` for the registered account's personal scope and `scope=shared&scopeId=<created ID>` for a membership-checked shared scope. Its principal is the durable issuer/subject account ID. IDs use distinct versioned namespaces and never adopt legacy data. The shared selector is 64 lowercase hexadecimal characters; duplicate scope selectors or malformed IDs are rejected. The owner has permission generation `1`; only an edited member's generation changes, including remove/readd. Other members' cursors remain valid.

Mutations, sync, snapshots and events send `X-Cosmos-Sync-Scope`, `X-Cosmos-Sync-Principal`, `X-Cosmos-Sync-Permission` and `X-Cosmos-Sync-Scope-Mode` from the verified session. Missing or mismatched assertions return 403 `session_mismatch` before data access. `X-Cosmos-Sync-Session` optionally echoes the BFF's opaque signed Cosmos consistency envelope. Its purpose and principal/grant/history context differ from every cursor. It is consistency metadata, never a Cosmos credential.

### Optional identity-generation binding

The coordinated BFF/Dart extension also supports
`{identityGeneration:integer,identityId:string}` in a verified session.
Both fields must be present together: generation is 1..10,000 and the identity
ID is 64 lowercase hexadecimal characters identifying the approved credential
binding, not an email or caller account claim. Current legacy/builtin modes
omit both fields. Explicit `authorization.mode=directory` emits them from a
fresh verified broker-profile/directory lookup. The opt-in source implementation
does not automatically activate or migrate a deployment.

An identity-bound data request additionally sends
`X-Cosmos-Sync-Identity-Generation` and `X-Cosmos-Sync-Identity` from that session.
Missing, stale, malformed, duplicated or mismatched identity assertions return
401 `identity_session_invalid` before data access. A legacy scope cannot adopt
a caller-provided identity binding. The existing numeric membership
`permissionVersion` remains unchanged and independently fences writes in the
data partition; it is not a composed identity/policy version.

Signed consistency, journal, snapshot and event contexts bind both identity
fields when present. An older context without them cannot transfer to an
identity-bound scope. SDK session equality, SQLite/IndexedDB persisted session
metadata, query coverage and late-response consistency checks include both.
An observed generation/credential change purges and pauses the old cache/outbox
before pending transmission. Old metadata remains readable as an unbound
session, never silently upgraded into a bound authority. Offline revocation is
still unknowable until online revalidation; these fields alone are not a
cross-partition atomic revocation guarantee.

## Builtin account and membership management

These additional routes are available with `authorization.mode=builtin` or
`directory`. `GET /v1/account` returns `{accountId,personalScopeId}`; builtin
registers its issuer/subject account, while directory requires an existing
explicitly registered account and rechecks its broker binding.
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
identity switch. Directory management additionally requires the exact principal
and identity-generation/identity headers. It sends no data scope/mode/permission
assertions or Cosmos consistency envelope. See [authorization](authorization.md)
for limits and revocation.

## Directory identity lifecycle

Only explicit `authorization.mode=directory` exposes these routes. Every request
still needs a valid API access JWT; raw provider/broker ID tokens never become
bearer credentials for ordinary account/session/data routes. The trusted server
configuration and bounded metadata store are described in
[the identity directory](identity-directory.md). These interfaces are implemented
by the published BFF from `36d2680` and the explicitly pinned repository SDK;
the old SDK archive and retained hosted image are unchanged. Publication does
not prove actual CIAM issuance or hosted directory acceptance.

| Request | Body or result |
| --- | --- |
| `GET /v1/identity/capabilities` | Version 1, approved `{issuer,provider,namespace,clientId,callback}` targets, freshness 300 seconds, maximum 8 identities, recovery `remaining-identity-only`, deletion/migration `operator-review-required` |
| `POST /v1/identity/challenges` | `{operation:"register"|"link"|"unlink",callback,removeIdentityId?}`; returns `{challenge,operation,expiresAt,target}` with the persisted UTC expiry |
| `POST /v1/identity/register` | Fresh correlated API bearer plus `{challenge,idToken}` |
| `GET /v1/identities` | Current account and its active opaque identity IDs/providers |
| `POST /v1/identities/link` | `{challenge,reauthentication:{accessToken,idToken},identity:{accessToken,idToken}}` |
| `POST /v1/identities/unlink` | Same proof-pair shape; `identity` proves control of a remaining linked credential |

Capabilities require an approved fresh broker profile but not prior registration.
Register challenge/commit requests carry no principal or identity assertions and
cannot replace an existing assignment or ownership tombstone. Other lifecycle
requests require exact `X-Cosmos-Sync-Principal`,
`X-Cosmos-Sync-Identity-Generation` and `X-Cosmos-Sync-Identity` assertions from a
verified session. `removeIdentityId` is required only for an unlink challenge.
It selects an existing binding; it is never proof of control or ownership.

Register/list/link/unlink return
`{accountId,personalScopeId,identityGeneration,currentIdentityId?,identities:[{identityId,provider}]}`.
Link/unlink keep the immutable account/data owner and increment generation by
one. Removing the active credential omits `currentIdentityId`; the old bearer
cannot open another session. The last credential cannot be removed. Ownership
remains reserved after unlink; only its original account can relink it.

Lifecycle bodies reject unknown/duplicate fields and exceed neither 128 KiB nor
the individual proof bounds. Challenges/proofs bind the exact approved target,
operation, account and generation. Signature/issuer/audience/scope/client,
signed object/tenant correlation, server nonce and integer fresh `auth_time` are
verified independently; email, refresh or `iat` alone is not reauthentication.
Directory CAS atomically consumes challenge/proof/audit/generation once. Replay
is rejected, not success-shaped idempotency. A lost/ambiguous result requires new
online resolution, never resubmission of the old proof.

Directory registration and personal-policy initialization are separate
transactions. Initialization failure returns an error; a new verified `/session`
can initialize that exact committed account idempotently. Graph, directory and
personal/shared partitions are not globally atomic. An in-flight data write can
commit between directory checks while its old-session response is denied; the
numeric same-partition membership fence is unchanged. Non-SSE directory requests
have a 30-second context; SSE retains its bounded lifetime/revalidation.

The application explicitly confirms pending-data loss, drains/purges before
proof acquisition and verifies the new identity before reopening any data cache.
Submitted failures or an unverifiable new session require signout and explicit
online reauthentication. Proofs never replace primary credentials or enter an
offline outbox. Recovery is normal sign-in with a remaining linked credential,
not an email search, replacement registration, deletion or migration endpoint.

Validation tools do not extend this wire contract. The standalone fresh-proof
stdin verifier checks authentication against an exact *provided* nonce; it
does not establish server provenance, read Graph, consume directory state or
authorize a session. The separately approved native control obtains the actual
authenticated challenge, keeps proof credentials transient and submits a single
registration before verifying the account/session. Its recorded-token SDK
successor permits only reads and three document mutations, with no new lifecycle
writes. Both share an existing origin-bound aggregate request ledger and stop on
unknown submitted outcomes. Request/operation reservations and acknowledged
HTTP responses are not measurements of Cosmos CAS attempts, audit items, RU or
cross-partition atomicity. See [native proof](native-auth-live.md#directory-fresh-proof-mode)
and [directory acceptance tooling](developer-onboarding.md#directory-acceptance-tooling).

## Documents and mutations

`Document = {id: string, data: JSON object|null, version: positive integer, deleted: boolean}`. Versions/sequences/preconditions are exact JSON integers at most `2^53-1`. Native and web reject unsafe integral JSON data rather than round it. IDs contain 1–128 ASCII letters/numbers, dot, underscore or hyphen, beginning with a letter/number. Data is bounded to 256 KiB on the BFF; the SDK uses a conservative 255 KiB bound. Unknown request fields and duplicate JSON keys are rejected.

`POST /v1/mutations` accepts `{operationId: UUID, documentId, kind: "put"|"delete", data: object|null, baseVersion: integer}`. Base zero means absent. Reply: `{document: Document}`. Metadata head, document, immutable journal event and receipt commit atomically inside one logical partition. Builtin/directory policy storage also includes an ETag-conditional policy replacement as a fifth batch operation, preventing an old data-membership authorization from committing after its same-partition revocation commit. Receipt identity includes the authenticated principal and operation ID; its hash binds scope, principal, kind, document, data and original base. Identical replay returns the original result only with current write access; a changed payload returns 409 `idempotency_mismatch`. A stale base returns 409 `{code:"conflict",current:Document|null}`. Document/conflict responses reauthorize after storage; a denial after a pre-revocation commit does not prove rollback.

The SDK commits local acceptance before its write Future resolves. Confirmed data and pending overlays remain separate. A first edit records the observed server version; later pulls do not rebase it. Successors can depend on a predecessor's actual ACK. Before first transmission the exact resolved request is persisted. Retries never change an ambiguous operation. Explicit conflict retry creates a new operation ID; discard cannot remove a possibly committed unknown outcome.

## Journal and snapshot recovery

`GET /v1/sync?cursor=<opaque>&limit=1..100` returns `{changes:Document[],cursor:string,hasMore:boolean}`. Omit the cursor to replay from zero. Changes are contiguous per-scope committed sequences, including tombstones; there is no global/cross-partition order. Each page, resume cursor and consistency envelope commit together in local storage. A gap returns a retry error rather than claiming completion.

When enabled, `GET /v1/snapshot?cursor=<opaque>&limit=1..100` returns `{documents:Document[],cursor:string,syncCursor:string,cutoverSequence:integer,hasMore:boolean}`. The first request captures head H. Every page deterministically folds the immutable retained journal through H, including tombstones, and orders by ID. The signed snapshot cursor fixes H and offset. The final local commit adopts `syncCursor` at H; subsequent journal sync obtains H+1 onward. Intermediate pages retain incomplete coverage, durable snapshot progress and exact outbox identities. A newer confirmed ACK never moves backward. This is bounded replay, with O(retained history) work per snapshot page, not a Cosmos SQL snapshot. HTTP413 `snapshot_limit_exceeded` falls back to retained-journal bootstrap.

Cursor purposes are separate: `cursor-v1`, `snapshot-v1`, `events-v1`, and `session-v1`. All bind scope, principal, mode, permission version, optional identity generation/credential and configured history epoch. Invalid cursor/signature/context returns 410 `resync_required`; the client clears confirmed coverage and resumes a snapshot or full journal while preserving pending identities and bases. An observed identity-generation change or grant denial instead follows the authorization purge policy.

Journal, receipts and tombstones have no TTL/garbage collection. Configured event/estimated-byte limits reject new writes with 507 `scope_capacity_exceeded` before storage growth crosses the supported envelope; accepted receipt retries still work. This preserves the replay horizon for all retained operations. Capacity increase and future compaction require explicit operator action and a separate recovery design.

## Change hints and browser requests

When enabled, `GET /v1/events` streams authenticated SSE. `Last-Event-ID` resumes a purpose-separated hint ID. An optional initial `cursor` query is a verified data cursor, not a bearer token. A `change` event has `id:<opaque>` and JSON `data:{cursor:<same opaque>,session?:<signed envelope>}`. It contains no document body. Hints may be duplicated, coalesced or lost and never advance the persisted data cursor. An `error` event terminates the stream with a typed authorization, resnapshot or store error. The BFF periodically revalidates JWT/grants; connection lifetime, stream count, heartbeat and write deadlines are bounded. The SDK reconnects with a fresh token and polling supplies correctness.

Browsers use streamed fetch with bearer authorization headers, not token URLs or cookie authentication. `allowedOrigins` is an explicit exact-origin list; wildcard origins are rejected. Preflight permits only supported routes/methods/headers. Responses expose the consistency envelope and Retry-After. Browser storage requires IndexedDB and lifetime exclusive Web Locks; unsupported persistent storage fails explicitly.

The ordinary [Flutter Web application](web-auth.md) keeps MSAL API/ID/refresh credentials in memory, separate from durable documents/outbox and SDK session/cursor metadata. A fresh document cannot restore offline authority: interactive sign-in and online BFF verification are required before reopening the retained cache. Native secure credential restore remains a separate application policy; neither platform derives cache ownership from client-decoded JWT claims.

## Errors and lifecycle

Errors are JSON `{code:string,...}`. HTTP401/403 purge local cache/outbox and pause synchronization, including a principal switch within a shared scope. Offline revocation is unknowable until reconnect. `await signOut()` waits for in-flight work before purging; close cancels notification/ACK waits and releases storage ownership.

Network/429/5xx failures preserve writes and apply persistent backoff with Retry-After. HTTP507 requires operator capacity action; blindly retrying cannot free retained history. A dry local enqueue is not server ACK: `waitForPendingWrites` captures the currently queued set, and later writes do not extend it. Conflict, discard, revocation and close fail that wait.
