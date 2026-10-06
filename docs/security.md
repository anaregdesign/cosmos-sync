# Security boundary and deployment obligations

The Go BFF is the only component with Cosmos data-plane credentials. End-user authentication proves an API identity; the BFF separately enforces application data authorization. Configure one trusted HTTPS OIDC issuer, the BFF-specific access-token audience and a required API scope. Accept only supported asymmetric signature algorithms and reject expired/not-yet-valid/incorrect-issuer/incorrect-audience tokens. Provider roles/groups, email and client document owner fields do not grant data permissions. The production entrypoint has no development authentication bypass.

Clients cannot provide an arbitrary owner, partition key, Cosmos SQL expression or trusted version/cursor. Strict IDs and bounded JSON payloads constrain batch serialization and cost. Unknown JSON fields are rejected. Expected principal/scope/mode/permission headers are assertions only; the BFF derives and compares the real scope before data access. Sync cursors and consistency envelopes are purpose-separated, HMAC authenticated and principal/scope/mode/permission/epoch bound, including optional server-verified identity generation/credential metadata. A caller cannot add that binding to a legacy scope. It remains separate from the numeric data-partition policy fence; only the explicit directory factory emits that identity binding, and it does not establish cross-partition atomic revocation. HTTPS and trusted server endpoints are essential because document data and bearer tokens cross the network. The Dart transport disables redirects and rejects non-HTTPS servers except explicit loopback development.

Explicit `authorization.mode=builtin` registers a durable issuer/subject account and a personal scope owned only by that account. Shared scopes have one immutable authenticated creator as owner; only that owner can assign registered accounts whole-scope reader/writer membership. Policy, membership audits and idempotency receipts persist in the same Cosmos container. Removed member generations remain as tombstones. No deployment-wide administrator, provider app-role dependency or document-specific ACL engine is introduced. [Application authorization](authorization.md) describes the management API, limits and migration. Absent/legacy mode retains server inline/file user/shared-tenant grants; distribute static changes to all replicas and advance permissionVersion. Never expose grant files or privileged Cosmos access to clients. Do not share a user's cache path with another account.

Builtin mutations include a policy ETag assertion in their single-partition
transaction. If membership revocation commits first, a stale authorized mutation
cannot subsequently commit; retry reloads and rechecks role/generation before
accessing receipts or writing. Legacy grants have no transaction fence, so an
already-authorized legacy mutation can finish. Neither mode promises instant
globally linearizable policy reads across independent Cosmos Session clients.
Access is denied at the next check after the server observes the change. SSE
rechecks before/after reads and on heartbeats; sync, snapshot and document/conflict
responses also recheck after storage work. A commit before revocation can still
lose its acknowledgement: HTTP403 does not prove no earlier commit happened.
The SDK's learned-revocation purge and in-flight drain prevent late responses
from repopulating its revoked cache, but cannot retract already received data.

The published BFF's opt-in `authorization.mode=directory` factory adds explicit
random-account registration/link/unlink and fresh trusted broker-binding reads.
Dedicated proof requests independently verify API/ID signatures, purposes,
object/tenant correlation, challenge nonce and integer authentication time.
Only the server reader has target-tenant Graph `User.Read.All`; product clients
receive no Graph permission or managed-identity assertion. Changed/added/removed
broker credentials fail closed instead of silently adopting the unchanged broker
object. Its current Graph reader is workforce-federation-specific, not a global
OIDC-provider allowlist or a generic social credential reader. A provider/broker
ID token is never an ordinary sync bearer.

Directory CAS consumes nonce/proof/audit/generation in one metadata partition.
Personal-policy initialization, Graph and personal/shared data are separate
boundaries. A write can commit between identity checks; a denied acknowledgement
does not prove rollback. Proofs are memory-only and do not replace primary
credentials, enter logs/caches or become replayable offline operations. The
application drains/purges before proof acquisition and verifies the new identity
before opening a cache. Submitted ambiguity requires fresh online sign-in.
Actual customer freshness, hosted MI exchange and out-of-band broker behavior
remain deployment gates; source fixtures are not those attestations.

Before delivery of an outbox, the client verifies `/session` and asserts the same identity on every mutation/sync. A scope/permission or optional identity-generation/credential mismatch, or HTTP 401/403, purges local cache/outbox and pauses the client. This is intentionally conservative and may discard unsent edits on expired credentials; applications should refresh tokens before delivery. Offline revocation cannot erase data or notify disconnected devices immediately. SQLite plaintext on disk, backups, disk remanence, OS compromise and malicious apps are not solved by a logical purge. Choose device encryption and sensitive-data retention policies before production.

Use a managed identity or an authorized server `TokenCredential` with a container-scoped Cosmos data-plane role. Never embed account keys in apps, source, example configuration, CI logs or package artifacts. Runtime signing keys must have high entropy, be secret-managed and shared between replicas; rotation or history restoration must invalidate/renew cursors deliberately. A signed consistency envelope is opaque transport metadata, not a Cosmos access credential. Monitor API authentication failures, conflict/retry rates, RU usage and journal/receipt growth without logging access tokens or full document payloads.

Cosmos account operations are not provisioned here. Deployment must configure an existing NoSQL container with `/scopeId`, no journal/tombstone/receipt TTL, one write region and the chosen consistency/backup model. All application writes must pass through the BFF to maintain the journal and receipts; out-of-band edits are unsupported. Bounded request/stream concurrency, principal rate buckets, payload/page limits and conservative retained-event/byte capacity caps are implemented. They apply per BFF process/scope rather than guaranteeing distributed aggregate quotas. Production abuse budgets and recovery drills still need the approved live environment. Live Cosmos SDK behavior and multi-replica consistency remain unverified until an authorized test environment exists.

Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/anaregdesign/cosmos-sync/security/advisories/new) after its activation is verified during the owner-approved public-source transition. Until then, use an established private channel to repository administrators. Never place exploit details, credentials or production data in a public issue. The [security policy](../SECURITY.md) describes the required report information; no response-time SLA is promised.

Browser CORS uses explicit exact allowed origins, streamed fetch bearer headers and exposed consistency/Retry-After headers. Origin approval is not authentication. Web Locks and IndexedDB provide cooperative SDK ownership/persistence within the origin; malicious same-origin code, XSS, OS compromise and browser eviction remain application risks. Notifications revalidate access repeatedly and carry no document payload. Rotate historyEpoch with restored history/signing keys; never TTL or manually prune protocol records.

The sample's explicit generic browser OIDC adapter keeps Code/S256 transactions,
ID/refresh credentials and verified subject in private memory. It independently
verifies signed ID issuer/client/expiry/nonce using trusted discovery/JWKS; the
provider library's decoded profile is not JWT verification or cache ownership.
Ordinary exports remain API-only. New refresh IDs are verified and must retain
the subject; absence of a refresh credential requires interactive sign-in, not
iframe or persistent-store fallback. Cancelled/late work cannot write into a
cleared guarded store. API JWTs and every cache rebind are still verified by the
BFF. The specialized Entra directory proof is explicitly unsupported by this
generic browser adapter; neither a provider name nor a normal ID token enables
account linking. See [the exact browser contract](web-auth.md).
