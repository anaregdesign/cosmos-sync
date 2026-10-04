# Staged identity-directory core

The internal Go identity-directory core implements bounded registration,
explicit link/unlink transactions and corresponding storage/failure tests.
**It is not connected to a production factory, configuration setting or HTTP
route.** Existing `/v1/account`, authorization, session, cursor and SDK behavior
still use the published issuer/subject contract. No existing personal partition
or data owner is migrated. This work does not enable Google/Apple federation,
prove broker self-service enforcement, or complete Issues #27-30.

## Trusted proof boundary

The core accepts internal proof stamps, not JWTs or client JSON. A future
identity-proof adapter must independently verify the exact upstream issuer,
subject, provider, client/project namespace, audience, signature, expiry,
server-issued challenge binding and recent authentication. It must prove broker
self-service additions/removals cannot bypass BFF approval. An unchanged broker
subject, signed `azp`, `domain_hint`, email, refresh, `iat` or a client timestamp
cannot supply that proof. Until those properties are established, activation
remains disabled; the core is not an authentication verifier.

Approved targets pin the issuer, provider, namespace, client and exact callback.
Account ownership keys include the issuer, upstream subject, provider and client
namespace, not email/profile information or the callback. Account IDs are
independent server-generated 256-bit values; their personal scope namespace is
stable across linking. Registration has its own server-issued challenge.
There is no recovery, account deletion or automatic migration endpoint.

Challenges use 256 random bits; only their SHA-256 digest is retained. They expire
after 300 seconds and bind the operation, account/session generation, approved
proof target and callback. At commit, both current-account reauthentication and
independent new-identity control must be challenge-bound, authenticated no earlier
than issuance, no later than the server clock and less than 300 seconds old.
Missing authentication time is rejected rather than replaced by token issuance
or refresh time. The raw proof is never stored; a digest replay ledger is consumed
with the transaction.

Unlink requires independently verified fresh control of a remaining active
credential. The existing reauthentication proof may also serve as that proof
when it is the same retained credential. The last credential cannot be removed.
Both link and unlink advance the internal session generation; old internal
sessions cannot start or commit another transaction. These generations are
**not yet wired into production JWT/session/cursor checks or Flutter cache
rebinding**, and therefore do not claim current preview-wide revocation.

## Atomic storage and deliberate limits

One fixed, versioned Cosmos logical partition contains one bounded directory
record. A conditional exclusive create or ETag-matched replacement atomically
covers account mappings, unique identity bindings, challenge consumption, proof
replay entries, session generations and audit. The official SDK uses Session
consistency and the existing request-local authorization session chain.
Conditional write conflicts cause at most eight reload/revalidation attempts.
An ambiguous failed write returns an error, not an inferred successful account;
the committed challenge, if any, still cannot assign twice.

This is a small, serialized reference boundary, not a production-scale directory.
It retains at most 64 accounts, 256 identity bindings, 256 challenges, 512 proof
digests, 256 audits and 512 KiB of serialized state. An account has at most eight
active identities and four unexpired pending challenges; directory revision and
session generation stop at 10,000. There is no TTL/GC. Capacity exhaustion is an
explicit 507 and can also block unlink: reserved security-operation capacity,
recovery/cleanup, production sizing and contention review are activation gates,
not delivered guarantees. A single hot record intentionally serializes writers.
No cross-partition transaction or monetary cost ceiling is claimed.

Unlinked identity ownership remains as a tombstone. Only its original account
can relink it with fresh proof; another account cannot adopt it. Reassignment,
deletion and data migration need a separate reviewed policy. Corrupt or internally
inconsistent directory metadata fails closed rather than being repaired by an
implicit write. Directory records are outside document/journal ID namespaces
and are not returned by the existing sync APIs.

## Evidence and remaining activation gates

Core tests use explicitly labeled internal verified-proof stamps, **not actual
providers or signed provider-token acceptance**. They cover account/namespace
isolation, stable ownership, freshness/callback/session/operation binding,
replay and simultaneous assignment, last-credential denial, retained tombstones,
corruption, bounded retries, ambiguous outcomes and capacity limits. Official-SDK
transport tests verify the actual one-partition create/conditional-replace wire,
operation count, ETag and session propagation. These are offline tests, not
live Cosmos acceptance.

Before production use, settle and verify the CIAM upstream-binding/fresh-auth
adapter and out-of-band mutation policy; review capacity reservations and
recovery; wire every account lookup, authorization management route, session,
cursor and client cache surface; and provide actual provider/platform/cloud
evidence. Do not expose linking UI or accept raw provider ID tokens at sync
routes merely because these internal transactions pass.
