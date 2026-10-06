# Opt-in External ID identity directory

The Go BFF now wires bounded registration, explicit link/unlink transactions,
trusted broker-profile reads and identity-bound authorization through explicit
`authorization.mode:"directory"`. The Dart transport and native/Web application
include matching ephemeral fresh-proof and account-lifecycle paths. **This is an
unpublished, opt-in source implementation, not a deployed or live-accepted CIAM
service.** Legacy/builtin modes retain their issuer/subject behavior and omit
directory lifecycle routes. No existing personal partition or data owner is
migrated. The retained Azure image has not been updated. The owner
cancelled actual Google/Apple connections in #30 as not planned on 2026-10-04;
trusted linking/authorization requirements remain. Use simulators during
development and defer physical Android checks until the final gate.

## Explicit server configuration

Start from [the directory example](../bff/config.directory.example.json), replacing
every placeholder with the exact approved deployment identifier. This mode requires
the GUID-host CIAM v2 issuer and tenant, a distinct GUID API audience and public
client, `tenantClaim:"tid"`, exactly one `allowedClientIds` entry and 1..16 distinct
approved callbacks. Native and SPA callbacks may share that client and namespace;
verify the actual application registration supports both before deployment.
Callbacks do not form ownership keys. Separate client registrations cannot be
silently admitted as the same namespace.

The server-only directory settings pin the CIAM initial domain, the dedicated
reader application's client ID, managed-identity client ID, approved workforce
tenant IDs and immutable namespace. They contain no credential. The reader's
source-homed multitenant app, retained UAMI federated credential and target-only
Graph `User.Read.All` grant must already exist. The runtime does not provision
them or fall back to CLI/default credentials for Graph. Cosmos continues to use
the configured server data-plane credential and existing `/scopeId` container.
Directory settings under any other mode, mixed legacy grants, unsupported
storage or inconsistent trust fail startup. Memory storage is development-only.
Readiness indicates completed startup/configuration, not continuous Graph or
Cosmos availability.

The ACA Terraform workload now admits explicit directory opt-in with typed trust
and a reviewed immutable image/source assertion; builtin/legacy remain unchanged.
Its [directory example](../infra/terraform/azure-container-apps/directory.tfvars.example)
is unapproved by default. Generated mock-plan JSON is checked with the strict Go
schema and the actual factory target restrictions. The managed-identity client
comes from the identity assigned to the app. A configuration assertion is neither
registry source verification nor permission to publish/apply; the known old
images cannot be relabeled directory-capable. Follow the
[activation/rollback runbook](azure-container-apps.md)
without adopting existing legacy/builtin ownership or removing retained metadata.

The [wire protocol](protocol.md#directory-identity-lifecycle) specifies the
capability/challenge/register/list/link/unlink routes. Registration is explicit;
ordinary account resolution never creates a directory account. Recovery uses
only a remaining linked credential; deletion and migration require operator
review and have no HTTP endpoint.

## Trusted proof boundary

The core accepts internal proof stamps, not JWTs or client JSON. An internal
OIDC ID-proof verifier now checks an operator-approved exact issuer, sole public
client audience and HTTPS JWKS URL; asymmetric signatures and bounded key
rotation; exact server nonce; integer `auth_time`, `iat`, `exp` and optional
`nbf`; and ID-token purpose. It rejects API scope/access-token headers, ambiguous
audiences, missing authentication time, refresh-as-reauthentication, key redirects
and unapproved targets. Profile/email claims are not ownership inputs. The
directory still checks authentication against stored challenge issuance and
consumes the proof atomically; the JWT component alone does not consume a nonce.

This verifier is used only by the dedicated lifecycle proof boundary, not as an
API-token replacement or browser/code/PKCE adapter. The broker adapter below
correlates verified API/ID tokens and
the freshly read upstream identity; actual OAuth callback and broker issuance
evidence remain separate. A broker ID token identifies the broker subject, not
necessarily an upstream provider subject. Production integration must prove broker
self-service additions/removals cannot bypass BFF approval. An unchanged broker
subject, signed `azp`, `domain_hint`, email, refresh, `iat` or a client timestamp
cannot supply that proof. The configured BFF rechecks the complete broker profile
and denies added/replaced credentials instead of adopting them. Actual deployment
self-service/freshness acceptance remains unverified; do not enable it merely
because signed fixtures pass.

Approved targets pin the issuer, provider, namespace, client and exact callback.
Account ownership keys include the issuer, upstream subject, provider and client
namespace, not email/profile information or the callback. Account IDs are
independent server-generated 256-bit values; their personal scope namespace is
stable across linking. Registration has its own server-issued challenge.
There is no recovery, account deletion or automatic migration endpoint.

Internal memory and Cosmos authorization stores now initialize the random
account's personal policy without deriving a new issuer/subject account.
An explicit `identity-directory-v1` provenance marker distinguishes these
records from existing hash-derived accounts; a mismatched origin or incomplete
account/policy pair fails closed without repair, adoption or migration. The
account record and personal policy are created together in the personal data
partition, with acknowledged-session readback. Subsequent identity-generation
changes leave that policy and ownership unchanged. Directory registration and
personal initialization remain two separate partition transactions; a failed
initialization returns an error, not a globally atomic signup. A new verified
online `/session` can recover that exact account's personal initialization
idempotently; it cannot repeat or infer a successful registration challenge.

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
sessions cannot start or commit another transaction. Directory authorization
emits the paired `identityGeneration`/`identityId` fields in personal/shared
sessions and binds all signed contexts, request assertions and SDK caches.
They do not establish globally atomic or offline identity revocation.

### Trusted broker-profile reader

A separate internal Microsoft Graph reader now checks the configured CIAM
customer's exact object ID, enabled state and complete credential set. It accepts
one approved workforce-federated identity in the documented source/target-tenant
namespace and at most one generated UPN in the exact initial domain. The UPN is
directory metadata, not an independent login proof or ownership key. Local,
administrative, foreign, added, missing and replaced credentials fail closed.
The broker-required directory now retains the exact object, upstream issuer/
subject and namespaced fingerprint in the registration/link transaction.
Online revalidation never adopts a different credential merely because the
broker object ID is unchanged. Broker-object ownership is unique within the
approved client/provider namespace, including inactive tombstones.

The server-only credential uses the configured managed identity's assertion for
`api://AzureADTokenExchange/.default`, a dedicated cross-tenant application and
only resource-tenant Graph `User.Read.All`. Its authority is pinned to Azure
Public Cloud, with no CLI/default-credential fallback. Graph access is one exact
user GET, bounded to ten seconds, 64 KiB and sixteen identities, with no cookies,
redirects or result cache. Errors contain fixed protocol codes, not raw Graph
messages or credentials. Configured trust is not proof of an actual hosted
managed-identity token exchange.

The explicit directory factory wires this reader and adapter. The adapter uses
the existing API JWT signature, audience, delegated-scope and
client-admission checks, then requires signed exact `oid`, `tid`, client and
v2 metadata. It correlates the independently signed fresh ID proof by object/
tenant rather than assuming API/native `sub` equality. Only the configured
CIAM issuer and distinct API/public-client audiences are accepted. Ownership derives
from the freshly read upstream issuer/object namespace, never email.

The broker-required directory rejects generic ID-proof stamps without this
correlated binding. Its existing one-partition CAS consumes the nonce/proof/
audit and expected binding together. Link/unlink reauthentication and relinking
must match the retained binding; neither a recreated broker object nor a replaced
upstream credential can adopt ownership. A read-only API resolver
rechecks Graph and returns only an existing active exact account/generation.
It does not implicitly register, repair metadata, migrate ownership or consume
an identity challenge. A profile GET alone supplies neither authentication time
nor the server challenge's signed nonce. See the
[authorized reader setup](external-id-setup.md#authorized-secret-free-server-reader).

## Atomic storage and deliberate limits

One fixed, versioned Cosmos logical partition contains one bounded directory
record. A conditional exclusive create or ETag-matched replacement atomically
covers account mappings, unique identity bindings, challenge consumption, proof
replay entries, session generations and audit. The official SDK uses Session
consistency and the existing request-local authorization session chain.
Within a request, directory reads additionally retain only a revision/body
security high-water mark. A missing, older or conflicting same-revision read
after an observed directory version fails closed; this is not an identity or
Graph profile-result cache. An acknowledged directory write advances that
request-local mark. Independent requests still perform current reads.
Conditional write conflicts cause at most eight reload/revalidation attempts.
An ambiguous failed write returns an error, not an inferred successful account;
the committed challenge, if any, still cannot assign twice.

Graph, directory metadata and personal/shared data are separate boundaries.
Directory revalidation before access and after slow reads/writes is not a
transactional identity fence inside each data partition. An in-flight authorized
write can commit between directory checks even if its old-session response is
then denied. The existing same-partition numeric membership-policy fence still
applies. Neither a denial nor cache purge proves rollback of an earlier commit.

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
live Cosmos acceptance. The actual emulator contention test verifies signed
local proofs before racing independent SDK clients. A separate factory/HTTP
case uses two independently constructed Cosmos stores and the real directory
routes: registration, owned writes, shared ownership, link, generation/cursor
rejection, unlink and removed-credential denial. A fresh SDK client then checks
retained provenance, tombstones and unchanged data history. It is not a
CIAM/provider deployment or production-consistency result.

An opt-in coordinated driver additionally runs real Dart `HttpSyncTransport` and
SQLite through two TLS BFF instances, first with shared memory storage and then
with independently constructed actual Cosmos-emulator stores. Signed local API/
ID proofs drive registration, an ACKed edit, remote link before pending delivery,
learned-generation purge and typed waiter failure, linked read/write, stable shared
ownership, unlink/removed-credential denial, explicit remaining-credential resume
and retained version-two data. Go owns the test-only proof issuer, certificate
and bounded child; native TLS trusts only that fixture certificate without
disabling verification. No such proof issuer exists in the production binary.
These results remain separate from actual code/PKCE, customer freshness and
hosted MI/Graph/Cosmos.

That coordinated driver also invokes the shared recorded-directory preflight and
data journey used by `tools/directory_azure_live.py`: capabilities, verified
registered session, offline reopen/exact ACK, two-client conflict/discard, hint,
tombstone/reopen and SDK signout purge. The signed empty-scope fixture measures
25 requests within its separate 29-request recorded-path allowance; the entire
register/link/unlink lifecycle remains a separately bounded 80-request fixture.
The same Dart path is selected for official Cosmos-emulator verification, not
substituted by an in-memory transport. These budgets reserve logical requests and
operations, not RU, physical SDK/CAS attempts or a live 40-request run.

The [manual native proof control](native-auth-live.md#directory-fresh-proof-mode)
obtains an actual authenticated challenge only in a separately approved live run.
Its transient-stdin CLI reuses production API/ID verification but deliberately
does not call Graph, consume the stored nonce or authorize an account. Standalone
provided-nonce verification and coordinated server-challenge provenance are
distinct receipt fields. Signed fixture receipts are not actual customer issuance.

Additional RSA/TLS/JWKS API/ID and Graph-transport fixtures verify differing
subjects with matching signed objects, wrong signatures/claims/audiences/scopes/
clients/nonce/authentication time before Graph, fresh uncached profile reads,
broker-only registration, durable fingerprint corruption and duplicate-object
denial, explicit link/unlink, generation advancement, tombstone/relink and exact
read-only account resolution. Production-factory HTTP adversarial tests directly
change the simulated broker's credentials outside the BFF transaction: added,
removed and replaced credentials, disabled accounts and deleted profiles all
deny a correctly signed token for the same broker object at session/account/
identity/sync/snapshot routes. Client-forged `providerData` is rejected, registration
cannot adopt the changed object, and directory proof/audit/ownership state remains
unchanged. Restoring only the exact original trusted fixture profile reveals the
same owned data; no alternative credential is adopted. These are deterministic
broker mutations, not actual live provider SDK operations.
The emulator also reloads an expected broker
fingerprint through an independent actual SDK client and rejects a changed
credential without adopting it. These Graph responses are local fixtures,
not managed-identity or customer-login acceptance.

Native AppAuth and isolated memory-only MSAL proof paths request the server nonce,
`prompt=login`, `max_age=0` and essential `auth_time`. Proof exchanges never replace
or persist the primary credentials. The application confirms local pending-data
loss, drains/purges before a challenge and independently checks the resulting
account/session before opening SQLite/IndexedDB. Ambiguous submitted outcomes
require signout and new online resolution, never proof replay. Removing the
current credential requires explicit sign-in with a remaining one.

Before production use, verify actual CIAM upstream-binding/fresh-auth issuance
and out-of-band mutation behavior; review production capacity and recovery;
provide common External ID OIDC, cloud and
the final Android evidence required by the active Issues. Deterministic signed
provider fixtures remain necessary, but actual Google/Apple connection evidence
is not part of this delivery. The UI is visible only after verified BFF directory
capabilities and is disabled offline or without fresh-proof support. Do not deploy
that capability or accept raw provider ID tokens at sync routes merely because
these tests pass.

Identity generation remains separate from the numeric membership
`permissionVersion` used by the data-partition write fence. Concatenating a
generation into that version violates the current BFF/Dart contract and cannot
replace explicit session/cursor/cache integration. The optional
`identityGeneration`/`identityId` session fields and corresponding request headers
are coordinated across signed contexts, SSE revalidation and native/browser
SDK cache equality; directory account/policy authorization supplies the trusted
values only when that mode is deliberately configured.
