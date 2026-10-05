# Staged identity-directory core

The internal Go identity-directory core implements bounded registration,
explicit link/unlink transactions and corresponding storage/failure tests.
**It is not connected to a production factory, configuration setting or HTTP
route.** Existing `/v1/account`, authorization, session, cursor and SDK behavior
still use the published issuer/subject contract. No existing personal partition
or data owner is migrated. This work does not enable Google/Apple federation,
prove broker self-service enforcement, or complete Issues #27-29. The owner
cancelled actual Google/Apple connections in #30 as not planned on 2026-10-04;
trusted linking/authorization requirements remain. Use simulators during
development and defer physical Android checks until the final gate.

## Trusted proof boundary

The core accepts internal proof stamps, not JWTs or client JSON. An internal
OIDC ID-proof verifier now checks an operator-approved exact issuer, sole native
client audience and HTTPS JWKS URL; asymmetric signatures and bounded key
rotation; exact server nonce; integer `auth_time`, `iat`, `exp` and optional
`nbf`; and ID-token purpose. It rejects API scope/access-token headers, ambiguous
audiences, missing authentication time, refresh-as-reauthentication, key redirects
and unapproved targets. Profile/email claims are not ownership inputs. The
directory still checks authentication against stored challenge issuance and
consumes the proof atomically; the JWT component alone does not consume a nonce.

This verifier is also inactive and is not a browser/code/PKCE adapter. A future
production identity-proof adapter must bind that verified identity to the actual
OAuth callback and reviewed upstream provider/client namespace. A broker ID token
identifies the broker subject, not necessarily an upstream provider subject.
The adapter must prove broker
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

### Trusted broker-profile reader

A separate internal Microsoft Graph reader now checks the configured CIAM
customer's exact object ID, enabled state and complete credential set. It accepts
one approved workforce-federated identity in the documented source/target-tenant
namespace and at most one generated UPN in the exact initial domain. The UPN is
directory metadata, not an independent login proof or ownership key. Local,
administrative, foreign, added, missing and replaced credentials fail closed.
The expected namespaced binding fingerprint must be retained by a future account
transaction; online revalidation never adopts a different credential merely
because the broker object ID is unchanged.

The server-only credential uses the configured managed identity's assertion for
`api://AzureADTokenExchange/.default`, a dedicated cross-tenant application and
only resource-tenant Graph `User.Read.All`. Its authority is pinned to Azure
Public Cloud, with no CLI/default-credential fallback. Graph access is one exact
user GET, bounded to ten seconds, 64 KiB and sixteen identities, with no cookies,
redirects or result cache. Errors contain fixed protocol codes, not raw Graph
messages or credentials. Configured trust is not proof of an actual hosted
managed-identity token exchange.

This reader is also **not wired into production**. A future adapter must obtain
the broker object/tenant/client from an independently verified API JWT, correlate
the signed ID proof's object ID despite differing API/native subjects, and bind
the approved upstream credential and expected fingerprint into the durable
transaction. A profile GET alone supplies neither authentication time nor the
server challenge's signed nonce. See the
[authorized reader setup](external-id-setup.md#authorized-secret-free-server-reader).

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
active identities. Normal operations can use three unexpired pending challenges;
a fourth slot is reserved for unlink. Directory revision and session generation
stop at 10,000. Unused expired challenges are removed only inside the next valid
conditional transaction; consumed challenges, proofs, audit and ownership
tombstones are never pruned or given TTL.

Admission reserves metadata for removing every additional active credential
while retaining one. It budgets a challenge/commit revision pair, an audit,
two proof digests, worst-size approved callbacks and counter digit growth per
potential unlink. Only one allocated unlink challenge per account receives
credit, because generation advancement invalidates that account's other
challenges. Registration/link cannot spend those reservations. Normal saturation
therefore returns an explicit 507 before consuming the reserved unlink path,
under the unchanged reviewed target configuration. Individual challenge limits,
last-credential denial, unavailable/corrupt storage, entropy and ambiguous-write
failures remain distinct; there is no universal recovery guarantee.
Previously saturated experimental records are not silently repaired or migrated;
the reservation guarantee applies to state admitted under the new rules.

Production sizing, target-configuration changes, cleanup/recovery and contention
review remain activation gates. A single hot record intentionally serializes
writers. No cross-partition transaction or monetary cost ceiling is claimed.

Unlinked identity ownership remains as a tombstone. Only its original account
can relink it with fresh proof; another account cannot adopt it. Reassignment,
deletion and data migration need a separate reviewed policy. Corrupt or internally
inconsistent directory metadata fails closed rather than being repaired by an
implicit write. Directory records are outside document/journal ID namespaces
and are not returned by the existing sync APIs.

## Evidence and remaining activation gates

Core unit tests use explicitly labeled internal verified-proof stamps. Additional
tests use actual RSA-signed local TLS/JWKS ID-token fixtures, **not actual
provider connections or a production broker-binding contract**. They cover account/namespace
isolation, stable ownership, freshness/callback/session/operation binding,
replay and simultaneous assignment, last-credential denial, retained tombstones,
corruption, bounded retries, ambiguous outcomes and capacity limits. Capacity
tests reach the exact revision/generation boundaries, audit/proof saturation and
the serialized byte limit with JSON-expanding large callbacks, then actually
unlink every additional credential without changing ownership. They also verify
the reserved challenge slot, unused-challenge expiry and pending-generation
credit independently across accounts. Official-SDK
transport tests verify the actual one-partition create/conditional-replace wire,
operation count, ETag and session propagation. These are offline tests, not
live Cosmos acceptance. The actual emulator contention test now verifies signed
local proofs before racing independent SDK clients; it does not activate HTTP
linking or establish a CIAM/provider deployment.

Before production use, settle and verify the CIAM upstream-binding/fresh-auth
adapter and out-of-band mutation policy; review production capacity and
recovery; wire every account lookup, authorization management route, session,
cursor and client cache surface; and provide common External ID OIDC, cloud and
the final Android evidence required by the active Issues. Deterministic signed
provider fixtures remain necessary, but actual Google/Apple connection evidence
is not part of this delivery. Do not expose linking UI or accept raw provider ID tokens at sync
routes merely because these internal transactions pass.
