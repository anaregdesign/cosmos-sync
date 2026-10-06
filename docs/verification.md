# Verification

Foundation v0.2 checks on 2026-10-03, macOS 26.7 arm64. Production BFF and SDK source
commits are `9c2bdb8` and `a7998fe`. Go 1.26.5, Dart 3.12.2, Flutter 3.44.6,
SQLite package 3.5.2 and Docker 29.5.3 were used. At that foundation stage, no paid Azure resource,
publication or deployment was performed. The foundation was subsequently merged
by explicit owner instruction in [PR #1](https://github.com/anaregdesign/cosmos-sync/pull/1),
with all seven [main CI jobs](https://github.com/anaregdesign/cosmos-sync/actions/runs/37122828485)
passing at `8d52024`. The new publication work in [Epic #2](https://github.com/anaregdesign/cosmos-sync/issues/2)
is a separate delivery and its real provider/cloud/device checks are not inferred
from these foundation fixtures.

| Check | Actual result |
| --- | --- |
| Go `go test -race ./...` | Passed official-SDK adapter/failure tests and real JWT/JWKS HTTP feature/security tests |
| Go vet, formatting and static CLI build | Passed |
| Native Dart full suite | **139 passed**, real SQLite; optional browser suite is separate |
| Chromium suite | **124 passed**, actual IndexedDB/Web Locks plus common cache, capabilities, models, queries and HTTP transport |
| Dart analysis/format | No issues or changes |
| Native runnable example | Passed offline reopen, pending ACK and tombstone scenario |
| Authenticated Go + native Dart HTTP | Passed durable restart/ACK, bootstrap/resume, stale edit conflict, delete/recreate |
| Authenticated Go + real Chrome HTTP | Passed CORS, IndexedDB reopen, ACK, snapshot, SSE, saved-cursor resume, query/tombstone/purge, and actual page reload without closing the cache |
| Native process death | SIGKILL of the disposable AOT fixture after commits preserved exact pending ID/base/retry/overlay, session/cursor/coverage, and released ownership for reopen |
| Official Cosmos emulator | Six race-enabled subtests passed against a fresh isolated digest-pinned container; only the test container/database was removed |
| Native Flutter application | Passed on macOS 26.7, iOS 26.5 Simulator and Android 14/API34 Emulator |
| Bounded benchmarks | Go three-sample workloads; native SQLite 1,000/10,000 records; real Chromium 1,000/50 records, with correctness checks |
| Docker build | Passed nonroot Go image using pinned Go/distroless base digests; no registry push |
| pub publish dry-run | Exit 0, zero warnings after SDK commit; 63 KiB archive excludes tools/reload probes/generated caches/data |
| Whitespace and Python syntax | Passed |

Independent review reproduced two production defects: learned SSE revocation
queued behind a pending response allowed another edit; lexical fractions near the
integer ceiling could be accepted by Go but rejected by Dart after floating-point
rounding. Both were fixed with native/browser and real JWT-backed shared-scope
regressions. An invalid-cursor browser assertion was also corrected. The reviewer
rechecked the original reproductions and found no remaining confirmed issue in
that review scope. This is evidence of the checked scenarios, not an exhaustive
security guarantee.

Durability/failure coverage includes exact lost-ACK replay and payload mismatch,
observed-version conflicts after a pull, predecessor ACK dependencies, late ACK
versus newer overlays, aborted page/snapshot/ACK transactions, injected quota
failure, schema rejection without deletion, unsupported Web Locks, ownership
contention, snapshot resume/cutover/restart, tombstones, epoch reset, 413 fallback,
401/403 purge, same-partition principal switching, role downgrade, in-flight
revocation/logout, pending ACK waiter failures, Retry-After/backoff, hint loss/poll
fallback, stream cancellation/backpressure and bounded payload/resource admission.
Quota failure is fault injection; it does not prove behavior under every OS/browser
storage exhaustion. SIGKILL recovery is not a filesystem power-loss guarantee.

The emulator uses the official Go SDK against actual service operations: atomic
batch, ETag rollback, receipts, pagination/concurrent writes, eight independent
SDK clients, session request propagation, and two TLS/JWT BFF instances sharing
Cosmos storage. Its advertised account consistency is **Eventual**, and production
policy correctly refuses it. A loopback-only test factory omits that policy guard
solely for storage tests. This does not prove live Azure Session/replica behavior,
RU, custom indexing, backup/failover, managed-identity RBAC or deployment readiness.
See [emulator evidence](emulator.md).

Platform results launch a native Flutter application with real SQLite and a
deterministic transport. They do not imply physical-device, Linux/Windows,
production identity or background-execution validation. Chromium has actual
browser persistence/network/reload evidence; Firefox and standalone Safari remain
unverified. See [platforms](platforms.md) and [performance](performance.md).

GitHub verification runs Go, native Dart, Chromium, official emulator, macOS
Flutter, container build and native/browser cross-stack/crash smoke checks.
Foundation remote outcomes are attached to [merged PR #1](https://github.com/anaregdesign/cosmos-sync/pull/1).
Publication workflows are deliberately gated; subsequent actual distribution is
recorded below. The owner approved MIT, public GitHub/GHCR visibility and the
0.2.0-dev.1 pub.dev preview. Foundation dry-run results alone did not establish
publication or provider/cloud/device evidence.

## Publication readiness checks

The new ordinary application is `examples/flutter_app`, separate from the
deterministic SDK fixture. Working-tree checks on 2026-10-03 passed:

| Check | Evidence scope |
| --- | --- |
| Flutter analysis and full app suite | No issues; 50 tests at this checkpoint, including shared-scope selection plus auth lifecycle/native-adapter/secure-store tests; later source/CI evidence is below |
| Latest native SDK suite | No analysis issues; all 165 tests passed, including typed account/membership management and shared-cache selection |
| Latest Chromium SDK suite | All 146 tests passed with actual IndexedDB/Web Locks and shared authorization/cache selection coverage |
| Release/environment control tools | Latest 127 tests passed, including bounded hosted acceptance and cursor-bootstrap guards; these unit tests perform no cloud resource or registry write |
| macOS app integration | Actual Go HTTP BFF, disposable signed JWT/JWKS issuer, SQLite, document/conflict/pending UI and an isolated native Keychain key; provider is a test adapter |
| Android physical SDK fixture | Pixel 9a / Android 17 API 37; actual SQLite and deterministic transport; cache close/reopen within the test process |
| Android physical application | Pixel 9a / Android 17 API 37; actual Go HTTP BFF, SQLite, offline reconnect/conflict/delete/purge UI and isolated native secure storage; signed-fixture auth adapter |
| Actual Entra native authentication | macOS AppAuth PKCE, callback, Keychain controller restore, refresh and local sign-out observed; both API JWTs independently verified; the latest wrapper failure is recorded separately below |
| Normal iOS release build | Unsigned arm64 build passed from core `e7fa4ccb`; no physical install or Apple portal operation |
| iOS simulator app integration | iPhone 16 Pro / iOS 26.5; actual HTTP BFF, SQLite and isolated Keychain probe; local ad-hoc simulator signing and ephemeral arm64 workaround, test auth adapter |
| MIT archive | 85 KB strict dry-run with zero warnings; actual published 87,507-byte archive matched the reviewed source and self-contained documentation |
| Multiarch OCI artifact | Linux amd64/arm64, nonroot runtime, checked provenance/SBOM subjects, MIT and Go/module license notices; local build, no push |
| Independent review | Auth reentry/purge defects and Azure request/deadline/partial-evidence defects reproduced, fixed and independently rechecked |

The Entra check used the approved native client and the owner's one account.
It verifies a controller restore within the process, not an OS process restart.
Its local sign-out cleared the isolated credential but does not revoke an
already-issued API access token. The Android application check ran reviewed
test-only small-screen interaction changes, subsequently committed in `8500ad2`;
the production app core was unchanged. Both physical Android fixtures use
test authentication, independently of the actual macOS provider check.

These client checks do not establish physical iPhone runtime or actual Android
provider sign-in. Actual artifact distribution and cloud data evidence are recorded
separately below. The owner chose
unsigned iOS verification and one-account live tests. Different-user isolation
remains an important live-provider gap even though independent signed-fixture
and emulator principal/partition tests pass. Keep actual release/CI links and
remaining scope in [Epic #2](https://github.com/anaregdesign/cosmos-sync/issues/2).
The exact unsigned/simulator commands and toolchain workaround are recorded in
[iOS validation](ios-validation.md). The owner approved the isolated East US
Cosmos validation target, current developer egress and container-scoped data
role, then explicitly required retaining the reusable Cosmos/Entra environment.
That retention instruction supersedes the earlier after-test deletion approval.

## Built-in authorization and Container Apps preparation

The subsequent preview source adds durable issuer/subject accounts, personal
self-access scopes and fixed-owner shared reader/writer membership. The actual
Go/Dart TLS fixture in `tools/authorization_cross_stack_smoke.py` exercises signed
RSA/JWKS identities, SQLite persistence, membership CAS/idempotency, reader and
nonowner denial, pending purge on demotion, connected SSE revocation, old cursors,
regrant and delete replay. Its identities are test fixtures, not actual Entra
users. The final official-SDK race/vet checks and seven emulator subtests passed,
including two-client policy fencing. Independent reproductions verified that
authorization reads preserve the client's data minimum, post-read checks deny
causally observed revocation, failed batches cannot release a revoked receipt,
and each physical query page/error retains its observed minimum. The final full
CI must pass for the release source; older green runs do not validate new changes.

The Container Apps reference adds trusted HTTPS-ingress runtime mode,
non-secret bounded JSON configuration, graceful process drain and pinned
Terraform providers. The latest workload format/init/validate, 31 mock-only plan
tests and TFLint passed; the new private-network prerequisites passed seven mock
tests and the same static checks. These checks do not contact Azure.

## Retained Azure and identity setup, 2026-10-04

The old East US group/account remains in ARM `Failed` state without a data
endpoint. The separately approved West US2 account reached `Succeeded`, with
NoSQL/serverless, Session consistency, one write region, disabled local
authentication, TLS 1.2 and continuous seven-day backup. Its database and
`/scopeId` v2 container have been created without TTL. A six-action Cosmos data
role is assigned to the selected operator and the hosted identity at the exact
container. Inherited governance disables public network access; no policy
exception, public-access restoration or network bypass was attempted.

Ten private-network/Key Vault prerequisites were applied from a reviewed saved
plan: VNet, delegated and endpoint subnets, private RBAC vault, two endpoints,
two private DNS zones and two links. A 32-byte random cursor key was created
once directly in memory through the existing authorized ARM identity. The public
bootstrap tool then successfully reused its exact existing version using metadata
only; it generated no new key and performed no rotation. Raw Terraform state,
reviewed configuration, secret URI and execution receipts remain private. The
vault has soft delete and purge protection; these resources are retained.

The first ACA workload attempt failed because ARM rejected the logging
`destination: "none"`. The reference now uses the official Azure CLI 2.88.0's
JSON-null representation, with a regression test. The next environment attempt
failed because this subscription lacked the required
`Microsoft.Network/AllowBringYourOwnPublicIpAddress` feature. It was registered
and the Network provider registration propagated within the authorized
subscription. The same owned failed environment was read back, imported into a
separate local state and updated from a reviewed plan with no deletion,
replacement or new IAM. That V3 ARM update returned `Succeeded`, but actual
readback found no `staticIp` and zero resources in the exactly owned managed
group. The app failed after about 21 minutes with `ContainerAppOperationError`
and zero revisions. Scoped Activity Logs contain the original six missing-feature
IP failures and no later IP/LB retry, supporting the inference that the update
did not rebuild the execution infrastructure.

The reviewed V4 saved plan successfully recreated only that unused empty
environment and failed app at 2026-10-04 02:49:28 UTC, with the same names;
four UAMI/IAM resources were no-op. Independent plan/source checks passed
26, 24 and 28 checks. The two destroy-guard exceptions exist only in the private
recovery copy; published module guards remain enabled. Cosmos, Key Vault/key,
private endpoints/DNS/VNet, identity/permissions and the old East US record are
retained. Actual readback verified a static IP, the owned platform load balancer
and IP, pinned image, managed identity, versioned secret reference, scoped roles
and private-endpoint/DNS configuration. A zero-replica revision reported
`ActivationFailed`; system logs contained only normal KEDA deactivation and
console logs had no running replica. The initial HTTPS check failed because
this Mac's Python/OpenSSL has no default CA file or directory; macOS
SecureTransport then verified TLS and returned Envoy `RBAC: access denied`.
The current Mac IPv4 was independently confirmed and matches the sole ingress
allow rule; one DNS A record matches the current static IP, there is no AAAA
record or local proxy/tunnel, and environment public access is enabled.
A reviewed app-only update temporarily raised the minimum to one replica without
changing its image, ingress or permissions. This exposed the actual startup
fatal: the published image's explicit `-config /run/config/config.json` default
conflicts with `COSMOS_SYNC_CONFIG_JSON`. The environment configuration must
explicitly invoke `/cosmos-sync-bff` without that file flag. No Cosmos permission
denial is inferred from this configuration failure. The command-only saved plan
was applied at 03:43 UTC. At 03:44:58 UTC, the actual latest revision was healthy
and ready, with one running/started container, zero restarts and a listening log;
all 11 scoped runtime checks passed. This includes startup initialization, not a
document read/write contract. A protected saved plan restored minimum replicas to
zero while preserving the command, image, ingress and permissions. Five failed
probe attempts are retained in the aggregate request budget, including a further
TLS-verified ingress denial after healthy startup. No hosted SDK execution or
application document write is claimed.

The environment-only Azure Monitor logging update was applied from a reviewed
plan with one environment update and five no-ops. A retained PerGB2018 workspace
reached `Succeeded`, with 30-day retention, a 0.023 GB/day cap and local key
authentication disabled. The new diagnostic setting enables only HTTP;
readback expands disabled categories and metrics, which remain disabled.
Independent configuration checks passed 17/17. Requested `Dedicated` returned
actual `null`; that RP difference is unresolved. A scoped ARM read confirmed
HTTP schema availability. Three exact app/environment/request queries within
74.793 seconds and one seven-second alternative allowing empty routing fields
all succeeded with zero rows. Log delivery and the ingress rejection cause are
unproven. A fresh two-service Mac IPv4 check still matched the allowed `/32`.
No extra ingress allowance, IAM, credential or retry mutation was introduced.

At 04:41:33 UTC, a fresh actual ARM checkpoint passed 19/19 checks. The app and
environment were `Succeeded`, with min0/max1, the executable-only command,
original pinned image, runtime configuration and sole `/32` unchanged. The
latest-ready revision was `Healthy`/`Provisioned`/`ScaledToZero`; both its
replica count and an independent actual replica list were zero. This is a dated
zero-replica observation, not proof of a running pod's current readiness or
permanent zero billing. Requests or later revisions can scale the app again;
retained private networking, storage and logs have separate charges.
The [retained deployment runbook](aca-validation-plan.md) documents topology,
costs, bootstrap, deployment and reuse.

A fresh macOS native AppAuth lifecycle was observed after reopening the correct
account's system-browser login: PKCE callback, Keychain controller restore,
refresh and local sign-out. The native test log reported success, but its wrapper
exited with a verification-phase failure; that failure is retained separately.
Initial and refreshed API JWTs subsequently passed independent signature,
issuer, audience, delegated scope, tenant and approved-owner checks, with a stable
subject. This is historical workforce identity proof, not consumer-provider or
Cosmos proof. A later live window requires a new unexpired API JWT.

The separate External ID directory reached `Succeeded` and was verified as CIAM.
Its API and native apps, service principals, API identifier and API-only delegated
admin consent were created. Exact discovery/issuer origins and the native config
constructor were checked. Google/Apple providers, linked sign-up/sign-in flow and
actual consumer login remain pending. See [External ID setup](external-id-setup.md).

## Hosted Azure SDK acceptance

The new `tools/hosted_azure_live.py` is offline by default. Its 13 loopback/offline
tests passed, as did Dart formatting/analysis. Approved execution uses one actual
ACA replica and a fresh workforce API JWT with system TLS, private SQLite and
a bounded live window: at most 120 seconds, 40 aggregate BFF protocol attempts
and three accepted create/update/tombstone mutations. Each readiness/denial or
diagnostic probe counts against that request allowance. The latest offline-only
manifest uses a 70-second SDK bound and 33 SDK calls. It is stale after five
root attempts: 35 calls remain, and four new readiness/denial probes leave at
most 31 SDK calls. Update it before execution from the preserved ledger. Infrastructure
construction and separated failed diagnostic phases are not represented as one
120-second wall-clock run. Protocol limits do
not bound physical Cosmos SDK requests, retries, RU or billing. Actual execution
results will be recorded here after the hosted endpoint is ready. It does not
prove two replicas, another real user, ordinary Flutter UI, Android provider login,
OS process death, consumer login or regional recovery.

## Actual first distribution

[PR #25](https://github.com/anaregdesign/cosmos-sync/pull/25) merged release source
`82e937c8659e9ec0263a78e6e3ad2f43e05be20a`. Its latest
[main CI](https://github.com/anaregdesign/cosmos-sync/actions/runs/37140346546)
passed all eight jobs. GitHub public visibility and private vulnerability reporting
were confirmed by API readback; the authenticated private advisory form was
inspected without submitting an advisory.

The actual [pub.dev preview](https://pub.dev/packages/cosmos_sync/versions/0.2.0-dev.1)
archive SHA256 is `5fe3f46ec981815c90e9dd68cdaac58519a7af8667e99672b499d92a0a8d404a`.
All archive files matched the original clean source. Fresh isolated hosted-package
consumers passed native Dart SQLite offline/reopen/ACK/tombstone, Flutter native
SQLite, Chromium IndexedDB, API analysis and release Web build. These storage
consumers use synthetic transport and do not establish live-cloud authentication.

The public BFF index is
`sha256:a23ab75eb4518597aa26e4833787b9b77a07def717868e080944555594adc1b3`.
Independent anonymous pulls of both platform children, source/version/MIT/nonroot
configuration and SHA/subject-bound BuildKit provenance/SPDX SBOM passed. The
initial verifier encountered a same-index platform collision in the classic
Docker image store; [#34](https://github.com/anaregdesign/cosmos-sync/issues/34)
corrects verification to pull child manifests without changing the original
runtime/SDK artifacts. Final repository-authenticated verification passed in the
[registry workflow](https://github.com/anaregdesign/cosmos-sync/actions/runs/37143709428);
[#15](https://github.com/anaregdesign/cosmos-sync/issues/15) is complete.

## Native admission and Azure deployment source

[PR #37](https://github.com/anaregdesign/cosmos-sync/pull/37) merged as
`76c1f46876b3dfd13f4bd7d4dd144cdf74efa5c0`. All eight jobs passed in its
[main CI](https://github.com/anaregdesign/cosmos-sync/actions/runs/37175675742).
The new optional signed `azp` admission setting, Flutter broker navigation and
Container Apps command fix are included in that source.
The later Terraform enum/probe-order patch preserves all settings while matching
actual ARM readback, preventing an unchanged app PUT for an environment-only
logging update. Its fmt/validate/TFLint and all 31 mock checks passed; the real
saved environment-only plan separately showed one update and five no-ops.

The new source-addressed BFF image was actually published and verified by the
[release workflow](https://github.com/anaregdesign/cosmos-sync/actions/runs/37176169762):

```text
ghcr.io/anaregdesign/cosmos-sync-bff@sha256:2651a4bca6df6f751b7f5e46d317ea9f6e4ca83081374badae142d57cdfc812a
```

The workflow verified public visibility, both authenticated platform pulls,
source/version/MIT/nonroot configuration and SHA/subject-bound BuildKit
provenance/SPDX SBOM. BuildKit provenance is not a signed GitHub attestation.
The version remains `0.2.0-dev.1`; its source tag and immutable digest distinguish
this BFF from the first image. The Dart SDK library is unchanged, so the existing
pub.dev archive was preserved. The Azure runtime checkpoint above still refers
to the first pinned image; publication does not establish new-image cloud
acceptance, actual provider login or linked-identity behavior.

## Resumed internal and Android verification, 2026-10-04

The owner resumed the remaining Issues and selected Android-only physical
verification. This checkpoint is work on top of `082f895`, not a new package,
container publication or Azure deployment. The retained Azure image and public
preview versions above are unchanged.

| Check | Measured evidence and limits |
| --- | --- |
| BFF vet, race suite and build | Passed, including the inactive-directory HTTP boundary with valid server-derived session assertions; raw provider ID tokens remain rejected |
| Staged identity-directory core | Internal proof-stamp/fake-store and official-SDK wire checks passed; no cryptographic upstream-provider verifier, production factory or route is activated |
| Actual Cosmos emulator | All eight subtests passed, including independent SDK clients racing for one directory binding in a single partition; only the newly owned test container/database was removed |
| Native Dart and Chromium SDK suites | 165 native and 146 browser tests passed; Dart analysis was clean; browser storage uses actual IndexedDB/Web Locks |
| Flutter app and control tools | App analysis/full suite and all 136 Python tool tests passed; package documentation synchronization passed |
| Native/browser cross-stack and crash checks | Actual signed Go HTTP/TLS fixtures, Dart SQLite, Chromium sync/page reload, authorization fencing and disposable native SIGKILL recovery passed; identities are fixtures, not additional real users |
| Actual physical Android workforce authentication | Owner-operated Microsoft AppAuth code/PKCE callback, isolated native secure-record controller restore, real refresh and local signout passed; the runner exited successfully |
| Independent Android API credential proof | Both initial and refreshed access JWTs passed signature, exact issuer/API audience, delegated scope, tenant and approved-owner checks; verified principal was stable; no grant was applied |
| Ordinary physical Android application | Actual local Go HTTP BFF, app-private SQLite, native secure storage and offline/conflict/delete/purge UI passed; authentication remains a signed test adapter, not the real-provider/cloud journey |
| Physical Android SDK fixture | Actual app-private SQLite SDK fixture passed with its expected runtime marker and deterministic transport; no live OIDC/BFF/Azure or OS process-death claim |
| Offline infrastructure reference | Both pinned Terraform validators passed formatting, locked initialization, validation, TFLint and 31 workload / seven prerequisite mock tests; no Azure plan/apply |

The first resumed native run reached the real Microsoft browser but was
interrupted while the owner was unavailable; it captured no API token. The first
ordinary application retry timed out. Later read-only device checks observed
dozing/locked state, which is a missing prerequisite, not a proven sole cause of
that timeout. Those failed/interrupted receipts were preserved. After the owner
powered up and unlocked Android, the fresh native and application runs above
passed. Cleanup closed the private control listener and removed only exact owned
ADB reverse mappings; credentials, private identities and raw logs are not
published.

A separate physical SDK retry failed without retained raw tool output. Its
project analysis then confirmed missing dependency resolution in this isolated
checkout. After lock-enforced restoration without a version upgrade, analysis
was clean and the fresh physical SDK retry passed. The earlier failed receipt
was retained rather than overwritten.

Controller restoration does not prove Android OS process death/relaunch.
System airplane mode and suspension, integrated ordinary real-provider Flutter
through hosted BFF/Cosmos, multiple actual principals and Google/Apple consumer
acceptance remain unverified. The
[internal directory contract](identity-directory.md) is deliberately separate
from active account/session/cursor/cache behavior; its tests cannot close the
production linking and broker-bypass criteria in Issues #27-29.

### Subsequent owner-directed scope and verification order

On 2026-10-04 the owner cancelled actual Google/Apple connections, configuration,
credential operations and live-provider acceptance. Issue #30 is not planned,
not passed; those operations are no longer prerequisites. Preserve deterministic
provider/security tests and keep the real-provider capability flags disabled.
The intended broker architecture remains useful future reference.

The owner then deferred physical checks until the final Android-only gate.
Continue development and native/browser/simulator checks first; do not spend
live request budget or relaunch physical fixtures merely to revise this scope.
Common External ID OIDC, trusted linking/authorization, hosted Cosmos and clean
onboarding remain unperformed where recorded above. The successful actual
workforce login does not prove CIAM login or Google/Apple federation.

The resumed ARM readback preserved successful app/environment provisioning,
executable-only startup, the original pinned image, min0/max1 and the sole
approved ingress `/32`. One additional system-TLS IPv4 health probe returned
Envoy 403 `RBAC: access denied`, although two independent IPv4 checks matched
that rule. The cumulative BFF ledger is **6/40 attempts**, with **34 remaining**;
reserve four fresh endpoint/auth gates, leaving at most 30 SDK calls before any
further probe. No hosted SDK run or Azure application mutation occurred. The old
70-second/33-call SDK manifest must not be replayed or used to reset that ledger.

Bounded historical and fresh delivery queries returned zero rows without a
partial-query error. Their scope includes the owned resource-specific HTTP
table and legacy diagnostic route, but they do not establish log delivery or
the rejection's evaluated source/peer. Diagnostic-setting readback points to
the exact owned workspace ARM resource, while requested `Dedicated` still
reads back as null. Explicit-window platform detector calls failed; a successful
default networking report contradicted ARM's VNet configuration and is not
authoritative ingress evidence. Subsequent metadata-only hypothesis checks found
workspace ingestion/query access enabled and app client-certificate mode
`Ignore`; neither explains the denial. No IP-policy broadening, role, secret,
resource, image or replica-setting change was made.

## Signed proofs and simulator-first checkpoint, 2026-10-04

The additional source remains an inactive internal primitive, not a production
linking endpoint or a new release. Actual Google/Apple connections stay cancelled
and physical Android verification stays deferred to the final gate.

| Check | Measured evidence and limits |
| --- | --- |
| Internal OIDC ID-proof verifier | Actual RSA-signed local TLS/JWKS proofs passed issuer/client/nonce/purpose/integer authentication-time checks, negative claims/headers, independent wrong signatures, cancellation, bounded key rotation/failure and redirect denial; trusted targets are server configuration, not client input |
| Directory transactions with signed proofs | Registration, explicit link/unlink, replay, equal-email separation and retained ownership tombstone tests passed; OAuth callback/PKCE, broker upstream binding and production account/session/cache integration remain unimplemented |
| Actual Cosmos emulator | All eight subtests passed, including cryptographically verified local proofs before independent SDK clients race for one directory binding; only the newly owned container was removed |
| Go and Python checks | Full BFF vet/race/build and all 139 tool tests passed; emulator selection guards reject connected physical devices without fallback |
| Native and actual Chromium SDK | Full 165 native / 146 actual browser tests and native analysis passed; this is fixture evidence, not CIAM or hosted Cosmos |
| Ordinary Flutter app | Analysis and all 61 app tests passed |
| Android SDK on disposable simulator | Actual Android 14 / API 34 arm64 execution passed the expected SDK runtime marker and test result using real app-private SQLite with deterministic transport |
| Ordinary app on disposable simulator | Local signed Go HTTP, SQLite, native secure storage and offline/conflict/delete/purge UI passed; receipt reports emulator=true, physical_device=false, live_oidc=false, live_azure=false and successful owned cleanup |

The simulator receipt names the dirty working tree based on `94d8d50`; it must
not be relabeled as an exact later-commit run. The first AVD creation failed
before any emulator/app/SDK execution. After restoration of missing official
command-line tools into the actual SDK root, a fresh disposable AVD passed.
Both attempts remain distinct private evidence. The successful emulator was
stopped, its owned AVD registry/data removed and its ports confirmed closed.
No physical target was selected or launched.

A separate read-only cloud diagnosis preserved `Succeeded` app/environment,
global public networking enabled, `internal=false`, the same direct local
network route and no proxy environment. The exact platform-auth read returned
`AuthConfigNotFound`, not a denied operator read. Resource Health reported an
unsupported resource type, so it supplies no health conclusion. Historical
Requests metrics had no nonzero points. One system-TLS differential probe to
the exact latest revision hostname still returned Envoy 403. This does not
identify the evaluated source/peer or establish diagnostic delivery.

The cumulative BFF ledger is now **7/40 attempts**, with **33 remaining**.
Reserve four fresh readiness/auth gates, leaving at most 29 SDK calls before
any further probe. This supersedes earlier request-allocation checkpoints, not
their recorded results. No Azure configuration, network, identity, role, image,
replica, secret or application-data write was performed. Common actual CIAM
login, production trusted linking/Web lifecycle, hosted Cosmos/onboarding and
final Android OS/real-cloud acceptance remain open; inactive proof and
simulator successes cannot close those criteria.

## Resumed security capacity and management access, 2026-10-04

The owner lifted the historical blanket work pause and directed tasks that do
not need physical iOS to proceed first. The remaining Issue bodies now carry
that active authorization; cancelled actual Google/Apple connections, narrow
network/live bounds and separate physical evidence remain unchanged.

The inactive directory now reserves audit/proof/challenge/revision/generation
and serialized-byte capacity for unlinking every additional active credential
while keeping one. Normal challenges leave a fourth slot for unlink. Only unused
expired challenges can be pruned inside a valid conditional operation;
consumed proof/challenge/audit and owner tombstones remain retained. Exact counter
boundaries, audit/proof saturation, generation-invalidated pending challenges,
and JSON-expanding large callbacks passed real removal of every additional
credential. Normal-capacity failures did not partially commit. This does not
activate any production identity/session/HTTP/client boundary or establish
universal recovery for old saturated metadata, storage failures or changed targets.

Full BFF vet/race/build and all eight actual official-SDK Cosmos emulator subtests
passed after this change. The fresh emulator container was removed. Protocol
mirrors and package-doc checks remain aligned; no protocol wire surface changed.

CIAM management provider access initially failed for missing operator OAuth
permissions, then Azure CLI's requested scope flow returned first-party
`AADSTS65002`. A separate secret-free setup public client was verified with
exactly two Graph delegated management permissions and `Principal` consent for
the existing administrator. Product API/native permissions, users and roles were
unchanged. Its MSAL code/PKCE callback, independently verified ID JWT and scoped
Graph provider read passed through bounded IPv4 system TLS. Earlier failed
self-profile/network attempts remain separate and supply no acceptance claim.
This administrative authentication is not a customer user flow. No additional
customer profile, actual common CIAM login, hosted data write, publication or
physical device operation occurred at this checkpoint.

## Shared native/Web application checkpoint, 2026-10-04

The ordinary Flutter application now has a Web target with locally bundled
MSAL Browser 5.24.0, memory-only credentials, an exact same-origin SPA redirect
bridge and real IndexedDB/Web Locks. It shares the native UI, auth controller,
transport and BFF-verified cache ownership; native AppAuth, secure restore and
SQLite paths remain intact. No new sync wire endpoint, cookie-auth boundary,
production auth bypass or package publication was introduced.

| Check | Measured evidence and limits |
| --- | --- |
| MSAL adapter | All 14 Node tests passed, including the actual pinned constructor, renewal/account pinning, sanitized failures, late callbacks, bounded initialization/cleanup and failed-logout cleanup; provider responses are deterministic fixtures |
| Ordinary Flutter application | Analysis/format clean, all 70 native app tests and 18 actual Chromium repository/interop/memory-auth tests passed |
| Ordinary production Web build | `flutter build web --no-pub --no-web-resources-cdn` succeeded with local auth and engine resources; compilation is not live OIDC |
| Actual Chromium Web UI | Attempts 4 and 5 passed signed Go HTTP/JWT validation, real IndexedDB, separately observed full page reload, exact pending operation retention, refused offline rebind, online BFF rebind, server ACK and logout purge |
| SDK and BFF preservation | SDK analysis/format, all 165 native and 146 actual Chromium SDK tests, full Go vet/race/build passed |
| Portable control tools | All 146 Python tests, package-doc mirror check and prepare-only release preflight passed |
| Exact-head portable Web checkpoint | Pushed `57f9835f332f35d6722103f4c5de68d31db550b5` passed all nine jobs in [CI 37210246196](https://github.com/anaregdesign/cosmos-sync/actions/runs/37210246196), including the actual ordinary HTTP/Chromium/full-reload Web job |

Both successful Web runtime receipts identify the dirty tree based on `0cc3a8d`,
not an exact subsequent commit. The first three failures remain preserved.
The reload failure exposed startup purging that assumed native credential
restore: a fresh browser document now retains the locked outbox but has no
offline cache authority until new sign-in and online BFF verification. Native
missing-credential purge is preserved. Actual Web helpers cleaned up their
owned browser/HTTP/Go processes; no physical or hosted cloud operation occurred.

CI now includes a ninth `flutter-web` job with pinned Flutter/action sources,
locked local MSAL dependencies, native/browser regressions, the production Web
build and actual signed-Go-HTTP Web UI/reload fixture. The release verifier also
requires this job. Older eight-job green runs do not validate this source.
That exact remote run independently verifies the committed source; it does not
relabel the earlier dirty local receipts.

The owner explicitly approved exactly one customer profile for the same existing
human in [#2](https://github.com/anaregdesign/cosmos-sync/issues/2#issuecomment-5980142363).
That resolves the unanswered permission exception; no profile/flow write or live
customer login is inferred. Actual CIAM, trusted production linking,
hosted Cosmos/onboarding and final physical Android remain separate open gates.
Physical iOS and cancelled actual Google/Apple connections are not blockers.

## Authorized workforce-to-CIAM preparation and strict profile check

Both focused owner approvals are recorded in #2. Fresh explicit-tenant Graph
calls verified the original workforce caller/CIAM administrator, exact product
apps, API-only consent and no preexisting exact customer or flow. The dedicated
source app/SP now requires the sole approved human's default sign-in assignment
and Principal-only `email openid profile` consent; no Graph `User.Read` or
directory role was added. Exactly one password-free customer profile was created
and uniquely read back in the documented tenant-specific federated namespace
using the original source **object ID**, not email/API subject/operator ID.

Actual beta custom-OIDC provider creation/readback accepted the workforce issuer
and source `oid` mapping. A seven-day source secret was transferred directly in
memory to the broker, with only safe key/expiry metadata retained. The product
flow has no signup/local password/OTP, exactly one provider and exactly one
product appId relationship. Source/product assignment is required, the reviewed
SPA bridge is registered, native/API-only contracts are preserved, the customer
has no directory roles, and privileged administrative identity/roles are unchanged.
Graph tag ordering and an undocumented `includeAllApplications` guard initially
failed; exact fresh readback resolved both without repeated mutations.

The first actual native run completed PKCE/callback, secure-controller restore,
refresh and local signout, but shared SSO selected the **administrative profile**,
not the approved customer. Both signed API tokens passed cryptographic
issuer/audience/lifetime/scope/client checks; the strict selected-customer owner
check rejected them. Preserve that failed wrapper and separate diagnostic proof;
no customer pass is inferred. A relative explicit-input path bug was corrected
before Go changes working directory. Exact tenant-ID-host CIAM/owned-client pins,
private input validation and explicit fresh Apple-ephemeral/Android-login request
regressions passed; ordinary native defaults/configuration binding are unchanged.

Two explicitly isolated retries timed out before callback/token capture. In the
first, the owner was still operating the login. The owner later clarified they
had not noticed another retry while doing other work. Fixed timeout markers,
not a provider denial, classify those failures. Their owned control listeners
were closed; no captured initial/refreshed API JWT or customer pass is inferred.

A subsequently owner-ready attempt displayed Microsoft's security-information
registration `invalid_request` page and was stopped. That generic page does not
establish a timeout, policy or ephemeral-browser root cause. The owner then
reported successful ordinary-browser passkey login. A following attempt showed
a CIAM Security defaults/MFA registration page after the owner used the admin
address; the owner could not recall whether the customer provider button had
been selected. Without a signed
token, that screenshot does not identify an exact authenticated object ID.
Security defaults, MFA and Conditional Access were not disabled.

Anonymous exact-native-client navigation independently confirmed the linked
CIAM flow, exactly one approved workforce provider button and its exact source
client. The advertised upstream callback used the tenant-ID hostname, absent
from the retained original friendly-host registration. Before repair, source
Graph rejected a still-unexpired cached token with HTTP 401, CAE
`InteractionRequired` and an actual claims challenge. Successful owner browser/
CLI login alone did not replace that cached Graph credential. Targeted silent
refresh of the already authorized Graph `.default` scope with the challenge
returned a credential accepted by Graph HTTP 200; all recorded original owner
profile fields matched, and normal CLI Graph acquisition subsequently passed.

One exact upstream callback-only PATCH returned 204. Initial full comparison
stopped on Graph's generated null-index `redirectUriSettings` entry and reordered
callback list. Fresh recovery readback verified precisely those computed
changes and the added callback, preserving both original returns/settings,
claims, permissions, secret keys/expiry and administrator profile/roles.
The PATCH was not repeated. A fresh anonymous request confirmed its advertised
tenant-ID-host callback is registered. These observations establish routing
configuration, not selected-customer authentication. The subsequent explicitly
owner-ready native retry ended with the fixed app cancellation error before any
API capture. The owner then clarified they had not noticed the browser. It is an
uncompleted owner interaction, not a measured provider rejection or customer
pass. Its owned helper/listener was stopped; another unchanged retry is not
required for independent implementation work.

### Authorized secret-free broker reader

The separately approved source-homed multitenant app/home service principal,
exact retained UAMI federated credential and target CIAM service principal were
created and independently read back. Only the target has Graph application
`User.Read.All`; source application grants remain zero. No secret/certificate,
product Graph grant, user-write permission, directory-role change, paid resource
or paid M2M add-on was created. The initial target service-principal 400 and
deduplicated repeat 201 remain distinct results, not a proven replication cause.
Configuration evidence is persisted in
[#27](https://github.com/anaregdesign/cosmos-sync/issues/27#issuecomment-5986382891).

The new internal Go reader uses that secret-free SDK credential design with a
pinned public-cloud authority, exact user GET, ten-second/64-KiB bounds and no
cookies, redirect or result cache. Full BFF vet/race/build passed after the
explicit cloud-authority pin and actual Azure SDK assertion/exchange transport
fixture; the latest repeat main-package race run completed in 172.716 seconds.
The fixture
uses the configured MI assertion, exact target tenant/client/Graph scope and no
secret/default-credential fallback despite conflicting environment variables.
MSAL's standard OIDC scope additions are distinguished from Graph application
grants. Token caching is allowed, but two lookups execute two Graph GETs.
Targeted regressions
cover enabled-state, object/namespace/credential-set checks, generated-UPN
separation, fixed private failure codes and expected-fingerprint replacement
denial. It is not connected to production routes, signed API/ID-proof correlation,
fresh challenge evidence or account/session/cursor/cache generations. Actual
managed-identity exchange/Graph execution from ACA and integration remain
unverified; the old retained image has not changed. All 153 portable Python
tests, ordinary Flutter analysis/all 72 native app tests/format and the actual package-doc
check/release preflight also passed at this working-tree checkpoint. The earlier
nine-job remote CI for committed `a21dd3eb7fb900fde96a458b30b056f345086af5`
[passed all nine jobs](https://github.com/anaregdesign/cosmos-sync/actions/runs/37258933306),
including actual Cosmos emulator, macOS Flutter and native/browser cross-stack.
That exact-head outcome does not verify the later internal broker adapter below.

No BFF request, ARM/network/image/replica/data change or package/container
publication occurred here. The cumulative BFF ledger remains 7/40, with
33 remaining and zero accepted application mutations. Selected-customer OIDC,
trusted active linking/recovery/migration, hosted Cosmos/onboarding and final
physical Android remain separate acceptance gates.

## Internal correlated broker proofs and durable account lookup

The next source checkpoint adds internal, inactive API/ID/Graph correlation
and expected-binding persistence. API and native ID subjects may differ; exact
independently signed object/tenant/client metadata, fresh signed challenge/
authentication time and an uncached approved Graph profile supply the proof.
No production route, authorization mode, session/cursor/cache protocol,
publication or Azure workload is activated by this component.

Signed local RSA/TLS/JWKS and strict Graph-transport tests pass registration,
explicit link/unlink, generation advancement, retained tombstone/relink,
generic-proof rejection, altered/recreated broker-object denial, corruption and
duplicate-object ownership checks. The read-only resolver returns only the
existing random account and generation, rechecks the profile on every lookup,
and never registers, repairs or changes account/nonce/audit state. Wrong
signatures, audiences, scopes, clients, object/tenant claims, nonce and stale
authentication time fail before Graph. Profiles/tokens are fixtures, not live
customer authentication.

The full BFF vet/format/race/build checkpoint passed; the main race suite took
175.969 seconds. The subsequent targeted broker race suite also passed the
additional read-only/corruption/tombstone checks. The actual digest-pinned
official Cosmos emulator passed all nine subtests in a fresh owned container:
an independent SDK client reloaded the exact expected broker fingerprint,
resolved the same random account, and rejected a changed upstream credential
without changing the ETag/state. Only that new container/database was removed.
This remains signed-local-provider and Eventual-emulator evidence, not hosted
MI/Graph or production Session consistency. Exact-new-source remote outcomes
are separate, not inferred from the earlier `a21dd3e` CI result.

The existing numeric permission revision remains the data-partition write
fence. Identity generation needs a separate coordinated BFF/Dart/session/
cursor/cache field; it must not be concatenated into that revision. Active
production identity/client lifecycle, actual CIAM freshness and hosted MI/
Cosmos/onboarding, plus final physical Android, remain unfinished. The cloud
ledger is unchanged at 7/40 attempts and zero accepted data mutations.

Committed broker checkpoint `2adb51fbeea1f9dfa47c094ceecacd6baa5be746`
independently passed all nine jobs in
[CI 37261483463](https://github.com/anaregdesign/cosmos-sync/actions/runs/37261483463).
That exact-source outcome is separate from the following protocol extension.

## Coordinated optional identity-generation protocol

The BFF and Dart SDK now support optional paired `identityGeneration` and
`identityId` fields, their exact request assertions, and signed session/journal/
snapshot/event context binding. Identity generation is 1..10,000; credential
IDs are server-issued 64-hex bindings. Membership `permissionVersion` remains
the original numeric data-partition write fence. Current legacy/builtin scopes
omit the new fields; no production directory authorization mode is activated.

Model/HTTP and actual native SQLite/Chromium IndexedDB checks cover persistence,
independent generation/credential changes, partial/malformed/out-of-range
metadata, purge before pending transmission, typed pending-waiter failure,
SSE authorization loss and refusal to adopt an old in-flight consistency
envelope. Legacy JSON/envelopes remain compatible, but cannot transfer to a
bound identity scope. Actual signed-JWT HTTP checks deny client-added bindings
before storage and verify explicit browser preflight for both new headers.

The full BFF vet/format/race/build passed (main176.431s), all176 native and157
actual Chromium SDK tests passed with clean analysis, all9 actual Cosmos emulator
subtests passed, and signed-Go-HTTP/native-Dart authorization cross-stack
preservation passed. The ordinary Flutter app retained clean analysis/format
and all72 native tests;153 portable Python tests and protocol/package-doc
synchronization passed. Fixture identities remain labeled; no real customer,
hosted MI/Graph/Cosmos or final physical acceptance is inferred.

Production account/policy initialization for random directory accounts,
explicit lifecycle routes, native/Web fresh-challenge/link UI and the actual
OIDC/cloud gates remain open. No BFF attempt, resource/network/image/replica/
data change or publication occurred; physical iOS is not a prerequisite.

The coordinated protocol checkpoint was committed as
`d8da58cc21726ec45f1968c9688fde3ada04dbbf` and independently passed all nine
jobs in [CI 37263540553](https://github.com/anaregdesign/cosmos-sync/actions/runs/37263540553).

## Internal random-account authorization bridge

The memory and official-SDK Cosmos stores now support deliberate random-account
personal-policy initialization. Exact immutable provenance distinguishes the
directory namespace from legacy issuer/subject accounts; mismatches, partial
metadata and corruption fail closed without implicit migration or repair.
Personal account/policy creation is one acknowledged, session-bound batch in
the personal partition. It is not atomic with the separate directory transaction.
Generation changes preserve the account, existing personal data and numeric
membership/write fence. Registered random accounts can create shared scopes and
receive ordinary owner-managed grants.

The directory also retains a request-local revision/body high-water mark and
rejects rollback, disappearance or same-revision equivocation. Memory directory
CAS returns defensive copies and rejects stale writes; no Graph/profile-result
cache or cross-request permission cache was added.

Full BFF race tests passed (main214.613s), vet/format/build passed, and all nine
actual emulator subtests passed. The extended broker/emulator case independently
reloads random-account provenance and personal policy, writes/reads owned data
through the unchanged numeric fence and creates a shared scope. Additional
memory/SDK-wire tests verify atomic initialization, concurrent idempotency,
generation-independent policy retention, invalid inputs and unchanged corrupt
metadata on failure.

This remains an internal capability, not a configured production directory mode,
lifecycle route or hosted identity acceptance. No live BFF attempt, Azure or
physical-device operation, deployment or publication occurred; the live ledger
remains 7/40 attempts and zero accepted application mutations.

That bridge source, `c006759cae99f9c98d7c55e4b382d8ee254fd842`, independently
passed all nine jobs in
[CI 37264986518](https://github.com/anaregdesign/cosmos-sync/actions/runs/37264986518).
It does not verify the following separate runtime checkpoint.

## Opt-in coordinated account lifecycle, 2026-10-05

The new unpublished source explicitly selects directory authorization, strict
registration/list/link/unlink HTTP routes and trusted broker revalidation. Native
AppAuth and isolated memory-only MSAL fresh proofs feed matching transport and
application lifecycle paths. Random account/personal/shared ownership remains
stable; identity generation is separate from numeric membership permission.
Legacy/builtin behavior is preserved. No old data namespace, published archive,
image or retained Azure runtime is migrated or replaced.

| Check | Measured evidence and limits |
| --- | --- |
| BFF validation | Full vet/format/race/build passed, main race package 226.778 seconds; subsequent race-enabled added/removed/replaced/disabled/deleted broker-profile HTTP cases also passed |
| Actual lifecycle HTTP | Explicit production factory, signed local API/ID/JWKS and uncached Graph fixtures cover freshness/replay/assertions, read-only resolution, ownership, initialization recovery, old cursors, slow reads and active events |
| Native/browser SDK | Clean format/analysis, 183 native SQLite tests and 164 actual Chromium tests; typed lifecycle models/transport, generation purge and independent numeric membership fences |
| Ordinary application | Clean format/analysis, 99 native unit/widget tests, 24 actual Chromium tests and 19 Node/MSAL tests; pending confirmation/cancellation, proof preservation/signout/close, ambiguity/recovery and rejection before cache open |
| Coordinated native lifecycle | Actual Go TLS, signed fixture proofs, real Dart HTTP/SQLite, two BFFs, register/ACK/link/pending purge/typed waiter/unlink/removed denial/remaining-credential resume and retained data passed |
| Actual Cosmos emulator | All 11 subtests passed, including production-factory lifecycle and the same real Dart driver through two independently constructed official-SDK stores; owned emulator removed, Eventual semantics remain nonproduction |
| Preservation smokes | Native HTTP restart/ACK/conflict/delete, TLS shared-authorization fencing, disposable SIGKILL recovery, actual Chromium HTTP/SSE and ordinary macOS HTTP/SQLite/isolated Keychain UI passed |
| Production compilation and ordinary Web | Normal local Web build and Android debug APK passed; ordinary signed-fixture Chromium UI observed reload, exact outbox retention, offline rebind denial, online rebind/ACK and logout purge with successful owned cleanup |
| Control/release preparation | All 153 Python tests, package-document mirrors and prepare-only preflight passed; the post-commit package dry-run passed with zero warnings and performed no publication |

Local receipts identify a dirty tree based on `c006759`, not an exact subsequent
commit. Runtime source
[`8ba5a11`](https://github.com/anaregdesign/cosmos-sync/commit/8ba5a11ef844e21b53aea24f2217acf5a1a73211)
is committed and pushed in PR #39. Its exact-head
[CI 37277515244](https://github.com/anaregdesign/cosmos-sync/actions/runs/37277515244)
passed all nine jobs: `dart`, `bff`, `container`, `flutter-web`, `cosmos-emulator`,
`browser`, `flutter-macos`, `release-tools` and `cross-stack`. CI includes portable
lifecycle/panel tests and explicitly enabled native/emulator Go/Dart directory
drivers, without adding a tenth job. This completes deterministic automation
acceptance in #29, not the separate live or final physical acceptance Issues.
The first final browser cross-stack invocation lacked `CHROME_EXECUTABLE`; the
same check passed with the actual installed Chrome explicitly selected. No
dependency/version change or browser installation was needed.

The mock application fixture initially lacked its real snapshot route, correctly
leaving pending edits and preventing an identity change. Accurate snapshot and
ACK assertions fixed the fixture; pending-loss consent was not relaxed. The
coordinated Go fixture similarly required snapshots to be enabled. Its driver
now asserts the existing exact learned-scope `StateError` and
`PendingWritesException.reason == authorization_changed`, rather than changing
SDK contracts. Dialog initiation uses real async for actual SQLite continuations.

The supplied ACA Terraform template still supports builtin/legacy only. Directory
hosting needs an explicitly reviewed compatible image/configuration and the
already prepared secret-free reader; the retained image cannot accept these new
fields. Actual selected-customer initial/refreshed API JWTs, server nonce and
integer `auth_time`, hosted UAMI/Graph/Cosmos and final physical Android
OS/relaunch/airplane/suspension remain unverified. Physical iOS is not a prerequisite;
actual Google/Apple connections remain owner-cancelled.

Fresh exact-app ARM metadata still reports Succeeded, one top-level UAMI,
external HTTPS, insecure ingress disabled, HTTP port 8080, client-certificate
Ignore, executable-only command, one Allow rule and min0/max1. A 24-hour query
of the retained resource-specific HTTP table succeeded with zero rows. Neither
metadata nor that empty result identifies the evaluated ingress peer or the
historical Envoy403/log-delivery cause. The separate environment read reports
public access Enabled, internal false, an existing subnet and azure-monitor log
destination. The serving revision is Provisioned/Healthy/ScaledToZero with zero
replicas and all traffic; the inactive revision is stopped. Resource Health
explicitly returned `UnsupportedResourceType`, not an application failure or a
verified health signal. These reads do not establish successful request routing.
No new BFF probe, resource/identity/network/
image/replica change, data mutation, publication or physical operation occurred;
the ledger remains **7/40 attempts, 33 remaining and zero accepted mutations**.

## Foreground input and clean-source simulator evidence, 2026-10-05

The attended harness changes are committed at
[`e7f0f37`](https://github.com/anaregdesign/cosmos-sync/commit/e7f0f379038a122b6fbe15eed7c7d4f498f11fab)
and
[`3214d0d`](https://github.com/anaregdesign/cosmos-sync/commit/3214d0d7f5de0a8debf5a83a67ad0f127dd3a0cd).
Their exact-head runs
[37283327743](https://github.com/anaregdesign/cosmos-sync/actions/runs/37283327743)
and
[37288105353](https://github.com/anaregdesign/cosmos-sync/actions/runs/37288105353)
each passed all nine CI jobs. The intervening evidence commit `ed1b67d` also
passed all nine jobs in
[37279188219](https://github.com/anaregdesign/cosmos-sync/actions/runs/37279188219).

The initial native attempt entered AppAuth but displayed no browser; scoped
Android diagnostics measured Background/BAL_BLOCK. The manual mode requires
one explicit start while resumed. Its first run timed out waiting for that
action, without requesting authentication. A subsequent physical tap was
discarded by Flutter's integration-test binding: live device pointer events
are disabled by default. The correction enables them only for the manual
test target, before registration. Three real live-binding/device-source
regressions and the existing owner/auth regressions passed (75 targeted
Flutter cases), with clean analysis/formatting and 31 native-control Python
cases. Production auth and Android policy are unchanged.

The corrected attempt reached `browser_request_started`. This means entry
into AppAuth, not proof that a browser displayed, returned a callback or
issued a token. No actual selected-customer callback/API token was captured.
The owner-reported AADSTS50020 is uncorrelated UI evidence. The owner
subsequently clarified that the requested browser-profile reopening was
**Mac**, not Android, and deferred attended verification. The phone remains
connected, but the owner cannot operate it; no further device/provider or
Mac management/customer login was started.

A fresh, exclusively owned Android 14/API 34 emulator then ran the clean
committed source `3214d0d`, without selecting the physical phone:

| Check | Measured evidence and limits |
| --- | --- |
| Native SDK fixture | Exit 0 and exact `COSMOS_SYNC_NATIVE_PASS android`; real app-private SQLite, deterministic transport, debug app; no live BFF/OIDC/Azure |
| Ordinary application fixture | Exit 0 and exact Android app marker; actual local signed-issuer Go HTTP, SQLite and isolated native secure storage; no actual provider or Azure |
| Directory lifecycle repeat | Race-enabled current-source Go TLS/signed JWT/Dart HTTP/SQLite lifecycle passed in 5.838 seconds; local fixture, not hosted reader execution |
| Clean-checkout prerequisites | A separate clean checkout of `3214d0d` passed format, locked backend-free init, validate, all 7 mock-plan cases and TFLint |
| Clean-checkout workload | The same clean checkout passed format, locked backend-free init, validate, all 31 mock-plan cases and TFLint; existing builtin/legacy configuration only |
| Owned cleanup | App fixture's processes and individual reverse mappings removed; owned emulator stopped, exact disposable AVD deleted and ports 5562/5563 released; physical phone unused |

The simulator receipts explicitly record a clean source tree, emulator=true,
physical_device=false, Flutter 3.44.6/Dart 3.12.2 and the exact commit. Private
`0600` receipts are retained in ignored `artifacts/`; raw runtime logs and
device identities are not retained in those receipts. The Terraform checks
used mock providers and did not acquire Azure credentials or run a real
plan/apply. They do not establish directory hosting or a deployed onboarding
journey.

Actual CIAM initial/refreshed API credentials, fresh ID nonce/integer
`auth_time`, hosted UAMI/Graph/Cosmos, ingress/evaluated-peer/log delivery and
final physical Android OS/relaunch/airplane/suspension are still open. The
retained image and supplied Terraform remain builtin/legacy-only; a compatible
directory runtime/configuration requires separate review. No additional
people, permission/scope/secret changes, callback repair, cloud data operation,
paid provisioning, deployment or publication occurred. The live ledger is
unchanged at **7/40 attempts and zero accepted application mutations**.

## Directory delivery preparation, 2026-10-06

The owner approved P1/P2/P3 implementation in the
[delivery plan](../.azure/deployment-plan.md), retaining separate artifact,
deployment, identity-coverage and attended-operation gates. The new source
provides typed directory Terraform, shared authentication-only proof verification,
fresh native failure receipts/transient directory control, actual emulator restart
tooling and a bounded recorded-directory SDK driver. No Azure mutation,
publication, physical operation or attended customer login occurred in this
preparation checkpoint.

| Check | Measured result and scope |
| --- | --- |
| Directory IaC | All 61 workload mock plans, locked init/format/validate/TFLint, actual generated mock JSON to strict Go schema/factory contract and three extraction tests passed; no Azure plan/apply |
| BFF candidate | Formatting/vet/race/build passed; root race suite 221.419 seconds, with signed fresh API/ID and transient CLI regressions |
| SDK candidate | 186 native SQLite tests and 164 Chromium cases passed; analyzer clean |
| Application candidate | 108 native tests, 24 Chromium auth/lifecycle cases and 19 Node/MSAL tests passed; analyzer/format clean |
| Portable tools | 196 tests passed, including origin/configuration/candidate binding, preserved aggregate history, transient proof cancellation, new preflight/failure receipts, SDK timeout/ambiguous partial counts and owned cleanup |
| Shared signed directory path | Actual TLS/Go/Graph-fixture/Dart/SQLite passed; complete lifecycle 54/80 requests, six directory operations, one shared-policy operation, four proof pair checks, five accepted document responses and one conflict |
| Recorded preflight plus data journey | The same empty-scope fixture measured 25/29 BFF requests and all 16 stages; old builtin target reuses its data journey without becoming directory-enabled |
| Actual Android emulator OS death | Initial working-tree r4 receipt passed: one installation, old PID gone/new PID different, restored native secure binding and exact pending operation/session, matching ACK, backend deduplication and owned app/link cleanup |
| Current local Docker limitation | Docker Desktop processes exist but neither configured engine socket is available; current container/Cosmos-emulator attempts failed before a usable engine. They are not recorded as passed; exact-candidate portable CI remains required |

The initial restart receipt identifies planning commit `c9f3402` with
`sourceTreeDirty=true`; it is not a clean committed-candidate result. Exact
candidate hashes, clean repetition and current portable CI outcomes are recorded
on #27/#28/#24. Earlier failed restart attempts are retained, not overwritten.
The previously completed planning-head
[CI 37397985564](https://github.com/anaregdesign/cosmos-sync/actions/runs/37397985564)
does not validate these later implementation changes.

Native directory proof requires a matching healthy immutable hosting readback,
selected customer trust and attended foreground action before its four BFF
requests. A standalone CLI proves the provided nonce only; server challenge
provenance, directory registration and session correlation belong to the control.
Fresh API/ID proofs are transient, while historical API capture files remain
private. The SDK successor reuses a just-completed matching native receipt and
its initial API credential; it performs no new proof/identity writes.

The shared private ledger preserves the historical seven attempts. Four native
proof reservations and a 29-request SDK envelope fit its remaining 33; fixture
budgets never erase actual history. These are logical request/operation
reservations and observed HTTP outcomes, not physical SDK/CAS attempts, Graph/
issuer requests, RU or billing. Unknown submitted outcomes stop, retain partial
counts and do not imply rollback. Directory and document retention are explicit.

The supplied Terraform can now prepare directory mode; the retained/public
images still cannot run it. Actual CIAM native/SPA callback and freshness,
hosted UAMI/Graph/Cosmos, ingress/evaluated peer/log delivery, ordinary hosted UI,
independent credentials/members/two real BFFs and final physical Android remain
their distinct open acceptance gates. No additional identity, grant, secret,
network policy, replica change, paid provisioning, rollout or release is implied.

### Restart resumption and directory fixture correction

After the owner restarted and approved continuation, implementation source
`f300273` had eight successful jobs and one failed Cosmos-emulator job in
[CI 37426148153](https://github.com/anaregdesign/cosmos-sync/actions/runs/37426148153).
The signed HTTP/Dart lifecycle was the only failed emulator subtest: its private
manifest used the broker's default namespace rather than the configured
`dart-http-emulator-v1`. The shared preflight correctly rejected that mismatch.

The manifest now takes its namespace from the actual fixture configuration.
Default and nondefault namespaces have independent signed memory-backed
lifecycle cases; the nondefault case reproduced the CI failure before the fix
and passed afterward. The recorded wrong-namespace/account rejection cases
remain unchanged and pass. No production verification, audience, nonce,
freshness, authorization or consistency guard was weakened.

Docker became available after restart. All eleven official Cosmos-emulator
subtests passed locally, including the same signed TLS/Dart/SQLite lifecycle
with two independent Cosmos clients. It measured the unchanged 54/80 complete
fixture and 25/29 recorded directory path; its isolated database and owned
container were cleaned. These are actual local emulator operations, not live
Azure/customer/hosted Graph acceptance. The earlier Docker failures and failed
`f300273` CI remain historical failures.

Clean committed-candidate restart repetition, nonpublishing image checks and
portable CI are subsequent evidence, pinned in #27/#28/#24. This checkpoint does
not claim them complete or waive the separate live and physical criteria.

### Clean candidate preparation acceptance

Runtime candidate `36f502fe5040f81164a9304992f6819b9d382c5a` passed all nine
individual [CI 37428407923](https://github.com/anaregdesign/cosmos-sync/actions/runs/37428407923)
jobs, including official Cosmos emulator, both application targets and the
nonpublishing container/release-tool contracts. A clean local repeat passed all
61 workload mock plans and the generated JSON/Go contract. Local OCI validation
passed amd64/arm64 source/version/MIT/nonroot, BuildKit provenance and SPDX checks
with `sourceTreeDirty=false`, `published=false` and owned builder removal.

The Android14/API34 process-restart receipt at `2026-10-06T07:16:54Z` identifies
that exact clean source. It verifies exact old-PID death/different new PID, the
same installation, restored native secure binding and pending operation/session,
offline reopen without refresh, matching ACK, backend deduplication and local
signout purge. App/reverse/backend cleanup passed; the newly owned emulator,
private AVD/registration and target file were then removed and its ports released.
The receipt remains a signed test-issuer adapter:
`liveOidc=false`, `liveAzure=false`, `physicalDevice=false` and
`systemAirplaneModeTested=false`.

Scoped preparation #27/#28 is completed, and #24's offline implementation
checklist is complete. Actual provider/cloud/physical criteria are unchanged.
Earlier dirty restart receipts and the failed `f300273` CI are preserved.

### Retained hosting read-only follow-up

Post-restart reads found the original builtin image/configuration, assigned
UAMI, sole ingress allow rule, min0/max1 and active Healthy/ScaledToZero revision
unchanged. App/environment/workspace are Succeeded; ResourceHealth's
UnsupportedResourceType is not an app failure. HTTP diagnostic category/destination
exists, but the target query returned zero HTTP/health/403/peer records since
October 4. Request/replica metrics each had 52 hourly values, totaling zero
requests and a maximum of zero replicas; missing values were not converted to
zero.

These observations do not establish the evaluated peer, request-log delivery,
current BFF reachability or hosted UAMI/Graph execution. The
[HTTP table reference](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/containerapphttplogs)
describes ingress metadata; the
[generic diagnostic REST contract](https://learn.microsoft.com/en-us/rest/api/monitor/diagnostic-settings/create-or-update?view=rest-monitor-2021-05-01-preview)
describes null versus Dedicated destinations. Neither a table's existence nor
nullable readback proves actual delivery or a root cause. No logging/network
change or new BFF probe was made; the historical ledger remains seven requests
and zero accepted application mutations. Exact retained routing/identity and
compatible activation remain #16, before actual #24/#32/#20 acceptance.

## Published directory artifact and read-only activation-plan validation, 2026-10-06

The owner separately approved normal code-only merge of
[PR #39](https://github.com/anaregdesign/cosmos-sync/pull/39). Exact merged main
`36d2680e5f88d31acfafa4473d0d4996f1de0ff7` passed all nine
[main-push CI jobs](https://github.com/anaregdesign/cosmos-sync/actions/runs/37433122046).
The merge message retains literal backslash-n separators before its coauthor
text; the source tree is unchanged and the original contributing commits have
canonical trailers. No amend, history rewrite or force push was authorized or
performed.

A distinct BFF-only approval authorized
[release 37438116005](https://github.com/anaregdesign/cosmos-sync/actions/runs/37438116005),
which finished `distribution_verified` at
`ghcr.io/anaregdesign/cosmos-sync-bff@sha256:adfe83a08dcd8754f85652641a85138e9a90993c1766ce70c86953365b9a6102`.
Both platform pulls, metadata, checksummed subject-bound BuildKit
provenance/SPDX and public anonymous access passed. BuildKit provenance is not a
signed GitHub attestation. Version/MIT/public visibility and the immutable SDK
archive are unchanged; old tags were not overwritten. The early pushed/pending
receipt is historical, superseded by final distribution verification.

The original private Terraform state was intentionally not brought into the
isolated worktree. The owner approved exact existing-resource GET/import and
saved-plan verification in a new **validation-only**, nonauthoritative local
mirror, not Azure apply or original-state migration/replacement. Six existing
workload resources were imported from a clean exact-main checkout with locked
providers, registration disabled and no secret values or Cosmos keys read.

Initial import plans showed provider reconstruction metadata/defaults rather
than a baseline no-op. Those plans were preserved. Reimporting the two AzAPI
bindings at the documented `2025-07-01` API and guarded, backed-up mirror-local
metadata reconstruction preserved all configured ARM values and the exact
existing infrastructure group. No cloud resource update was used to clear drift.
A new provider-refreshed baseline returned exit 0 with all six resources no-op,
SHA256 `654e044e8ce72e06a4bf4f702f035733a2dbacb75687c15d814bc399323607a7`.

The reviewed directory plan is SHA256
`01e4fb81fe4af80073220f6a79214595724582b102dca8ec6a00de77590a851e`:
one in-place app update, five no-ops, zero creates/deletes/replacements. Only its
image and `COSMOS_SYNC_CONFIG_JSON` change; runtime JSON changes only OIDC and
authorization/directory trust. Cosmos, UAMI, roles, environment, network/sole
Allow, min0/max1, command/probes/resources, cursor/versioned reference, history,
events/snapshots/limits/retention and other environment variables are unchanged.
The new namespace `cosmos-sync-ciam-directory-v1` does not adopt builtin data.

The canonical Azure Validate Terraform preflight passed all nine applicable
steps, using the exact private inputs and locked init. AZD's `main.tfvars.json`
check is not applicable. Its independently saved plan has the same resource
actions/values, SHA256
`173c2425b7ac6b931b875013fbb46e0c5ab89294d452900ade27b10a57125593`.
The exact generated JSON passed the released strict Go decoder/pure directory
factory through a private test overlay; the released BFF build passed without
source changes or network execution. Static custom Cosmos/container and cursor
Secret User scope review passed. Existing reader/FIC/target-only `User.Read.All`
metadata matches the configuration, but is not fresh Graph or hosted exchange
evidence. The applicable inherited app-policy query returned zero assignments.
Private mirror directories/files use 0700/0600; raw plans/state/identifiers are
not public evidence.

The retained Azure app is still on its original builtin image/configuration.
No Azure write, BFF probe, owner login or physical operation occurred, and the
real ledger remains 7/40 attempts with zero accepted application mutations.
Empty `allowedOrigins` was deliberately preserved: a registered loopback SPA
callback does not permit cross-origin Web acceptance. Original-state handback,
concrete update approval, Web origin arrangements, actual routing/log delivery,
hosted UAMI/Graph/Cosmos execution and #24/#32/#20 acceptance remain open.
