# Application data authorization

Authentication belongs to the configured OIDC provider. Cosmos Sync validates a
BFF-specific API access JWT; provider app roles, groups, email addresses, tenant
claims and document `owner` fields do not assign application data permissions.
Apple and Google require an approved authentication integration or broker that
issues the expected API proof; their identity tokens are not automatically BFF
access tokens. See [social authentication](social-auth.md).

The recommended new-deployment configuration is:

```json
{"authorization":{"mode":"builtin"},"grants":[]}
```

Use the existing Cosmos DB for NoSQL container with `/scopeId`, no default TTL and
one write region. The BFF's managed identity needs the documented container-scoped
read/create/replace/query actions. No Entra group synchronization, external policy
service, additional authorization database, client Cosmos credential or deployment
administrator account is required. Memory storage implements the same policy
model for development tests only. Legacy inline/file grants remain the default
when `authorization.mode` is absent or `legacy`; combining builtin mode with
nonempty grants or `grantsFile` fails startup.

## Small permission model

A verified issuer and subject register an internal account. The BFF derives the
account ID from a namespaced hash of those two values and durably records that
mapping. No email matching or client-selected account ID is involved. The issuer
is limited to 2,048 bytes and subject to 512 bytes. An issuer/subject change means
a different account; account linking and provider migration are not part of this
preview.

Every account has one personal scope with an immutable owner and full read/write
access. Its first trusted API request creates the account and personal policy in
one partition transaction. This needs no grant setup. Personal access does not
require a `tid` claim. All other accounts are denied.

An authenticated account can create a shared scope. Its creator becomes the one
immutable owner. That owner can add an already registered internal account as a
`reader` or `writer`, or set its membership to `none`. Readers can sync, snapshot
and receive change hints; writers can additionally put/delete documents. Ownership
cannot be removed, transferred or assigned by a request. A member cannot promote
itself or manage other members. There are no organization groups, invitations,
field ACLs, policy language, account deletion or owner-transfer flows.

## Account and shared-scope APIs

These routes require the same validated API access JWT as data routes. They do
not accept an administrator role claim. When a client already knows its account,
`X-Cosmos-Sync-Principal` can assert that account ID; an identity switch returns
403 `session_mismatch` before the management action.

| Request | Response or purpose |
| --- | --- |
| `GET /v1/account` | `{accountId, personalScopeId}` |
| `POST /v1/scopes` with `{operationId}` | `{scopeId, ownerAccountId, revision:1, members:[]}` |
| `GET /v1/scopes/{scopeId}/members` | Owner-only current shared-scope policy |
| `POST /v1/scopes/{scopeId}/members` | Owner-only membership change |

Account and scope IDs are 64 lowercase hexadecimal characters. Operation IDs use
UUID syntax, are normalized to lowercase and must be retained for retries.
Creating a scope replays the same immutable initial response for the same creator
and operation ID, even after later membership changes. Its server-derived scope
ID cannot adopt an existing legacy scope.

A membership change contains:

```json
{
  "operationId":"11111111-1111-4111-8111-111111111111",
  "accountId":"<registered account ID>",
  "role":"reader",
  "baseRevision":1
}
```

Fetch the current policy before editing. The response is
`{scopeId, ownerAccountId, revision, members:[{accountId,role,permissionVersion}]}`,
with members sorted by account ID. The owner is separate from the members array.
The base revision protects against concurrent administration. Policy, immutable
audit entry and request receipt commit together in the shared data partition.
Audit entries record the verified actor, target, prior/new role, operation,
revision and UTC time; their storage records are not user documents. Exact
request replay returns its recorded response even after a later policy change.
Changing the payload/base for an existing operation ID fails with 409
`idempotency_mismatch`; a stale new edit fails with 409 `membership_conflict`.

Nonowners get 403 `forbidden`. An unregistered target gets 404
`account_not_found`; changing the owner gets 409 `immutable_owner`. Unknown fields,
duplicate JSON keys, malformed IDs/roles and bodies above 4 KiB are rejected.
These APIs are online operations; they do not create a separate offline permission
outbox. The immutable SDK request objects let an application retry an ambiguous
response using exactly the original operation ID and payload.

## Data sessions and revocation

`GET /v1/session?scope=user` returns the personal scope. For a shared scope use
`GET /v1/session?scope=shared&scopeId=<created ID>`. The returned
`{scopeId,principalId,permissionVersion,scopeMode}` uses the internal account as
`principalId`; the scope ID is a selector checked against current membership,
never a client assertion of ownership. Data routes retain the existing four
scope/principal/permission/mode headers and signed cursor/session bindings.

The owner has permission generation `1`. A changed member gets the new policy
revision as its generation; unrelated members keep their generations and caches.
Removing a member retains a `none` tombstone. Readding it gets a later generation,
so earlier headers, cursors and consistency envelopes cannot regain validity.

A builtin document transaction includes an ETag-conditional replacement of the
unchanged policy together with head, document, immutable journal and receipt.
A membership change alters that ETag in the same partition. If revocation commits
first, an already-authorized stale write cannot subsequently commit: its batch
fails, and a bounded reload checks the member's role and generation before
retrying. Previously accepted receipt replay also requires current write access.
This guarantee concerns commits, not the order in which network responses arrive.
A write can commit before revocation and lose its acknowledgement afterward. A
403 response does not prove that no earlier authorized commit occurred.

Policy is loaded for every request. SSE rechecks before and after reads and on
heartbeats; ordinary sync, snapshots and document/conflict responses recheck after
potentially slow storage work. Authorization and document operations keep
separate opaque session-token chains: an earlier policy read cannot replace the
validated client document consistency envelope. Document operations carry their
latest observed token through receipt reads, batch retries and every physical
query page, including empty pages and service errors.

Before accessing data and when rechecking a data response, the BFF reads policy
against both the authorization chain and the validated/latest document minimum.
It selects the higher application policy revision and its matching ETag;
Cosmos tokens themselves are never parsed, compared or merged. Missing or
incompatible policy observations, changed immutable owner/mode, and different
content at the same revision fail closed. A bounded request-local high-water
guard also rejects a later policy revision regression. Every check still reads
policy; this guard never supplies a cached permission decision. The guards hold
at most eight partitions per request and never persist across requests.

Cosmos Session consistency does **not** establish immediate globally linearizable policy reads
across independent BFF replicas. A policy check rejects access after that replica
observes the change. The conditional write fence remains effective against a
stale policy read. There is also an unavoidable interval between a final check and
physical response delivery; already received data cannot be retracted.

The SDK purges its cache/outbox and pauses when it learns of 401/403 or a bound
identity/permission mismatch. An offline device cannot learn revocation or erase
cached data immediately. Logical purge is not secure erase. Use device encryption
and appropriate application retention; see [the security boundary](security.md).

## Bounded metadata, operation and migration

A shared policy holds at most 128 distinct member accounts, including removed
members. Policy revisions stop at 10,000, bounding retained membership audits and
receipts. Revisions from 9,744 reserve 256 operations for reducing existing
rights: writer→reader/none or reader→none. Adds, reactivations, increases and
same-role edits stop at that threshold, so every active nonowner can still be
revoked within the final capacity. A full-cap policy with an active nonowner is
invalid and fails closed. Exhaustion returns 507
`authorization_capacity_exceeded` and requires operator action; the preview has no unsafe metadata compaction or automatic
history deletion. Membership receipts contain the recorded policy result and add
storage costs separate from the document journal cap. API rate/concurrency limits
are per BFF process, not a cumulative or distributed quota on account/scope
creation. Configure operational budgets and application admission controls before
exposing an unrestricted registration workflow.

All authorization records use protected `a:` item IDs, while user documents use
`d:`, journal changes use `c:` and document receipts use `r:`. Public document IDs
cannot contain a colon, and user sync/snapshot queries only replay document
changes. Application writes and permission changes must pass through the BFF;
out-of-band Cosmos edits are unsupported and can invalidate these guarantees.

Switching an existing deployment to builtin mode creates new account/personal/
shared namespaces. It never imports old user/tenant data or guesses an owner.
Keep the legacy configuration while planning an explicit, verified export/import
and provider-account mapping. Separate caches by identity/mode/scope and require
a fresh server session. Do not rewrite old partition keys, disable fences or
copy grants from an unverified token to make a migration appear successful.

The local HTTP/security, official SDK wire and emulator suites validate this
contract. Their results are recorded separately from actual hosted Azure tests;
passing an emulator test is not a cloud RU, availability or consistency SLA.
