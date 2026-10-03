# Verification

Foundation v0.2 checks on 2026-10-03, macOS 26.7 arm64. Production BFF and SDK source
commits are `9c2bdb8` and `a7998fe`. Go 1.26.5, Dart 3.12.2, Flutter 3.44.6,
SQLite package 3.5.2 and Docker 29.5.3 were used. No paid Azure resource,
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
Publication workflows remain disabled/gated and are not exercised by verification.
Owner gates [#14](https://github.com/anaregdesign/cosmos-sync/issues/14),
[#15](https://github.com/anaregdesign/cosmos-sync/issues/15) and
[#16](https://github.com/anaregdesign/cosmos-sync/issues/16) remain open. A successful
pub dry-run does not establish actual publication. The owner has now approved MIT,
public GitHub/GHCR visibility, the selected pub.dev account and the proposed
0.2.0-dev.1 preview. Actual artifact publication/access, provider/cloud operations
and physical device results remain separate evidence.

## Publication readiness checks

The new ordinary application is `examples/flutter_app`, separate from the
deterministic SDK fixture. Working-tree checks on 2026-10-03 passed:

| Check | Evidence scope |
| --- | --- |
| Flutter analysis and full app suite | No issues; latest 50 tests, including shared-scope selection plus auth lifecycle/native-adapter/secure-store tests |
| Latest native SDK suite | No analysis issues; all 165 tests passed, including typed account/membership management and shared-cache selection |
| Latest Chromium SDK suite | All 146 tests passed with actual IndexedDB/Web Locks and shared authorization/cache selection coverage |
| Release/environment control tools | All 81 tests passed; no actual cloud resource or registry write is performed by these unit tests |
| macOS app integration | Actual Go HTTP BFF, disposable signed JWT/JWKS issuer, SQLite, document/conflict/pending UI and an isolated native Keychain key; provider is a test adapter |
| Android physical SDK fixture | Pixel 9a / Android 17 API 37; actual SQLite and deterministic transport; cache close/reopen within the test process |
| Android physical application | Pixel 9a / Android 17 API 37; actual Go HTTP BFF, SQLite, offline reconnect/conflict/delete/purge UI and isolated native secure storage; signed-fixture auth adapter |
| Actual Entra native authentication | macOS system-browser AppAuth PKCE, callback, Keychain controller restore, provider refresh and local sign-out passed; both API JWTs independently verified against issuer/JWKS/audience/scope/tenant/approved owner |
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

These checks do not establish live Cosmos data operations, physical iPhone
runtime, actual Android provider sign-in or registry distribution. The owner chose
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

The Container Apps preparation adds trusted HTTPS-ingress runtime mode,
non-secret bounded JSON configuration, graceful process drain and a pinned
Terraform reference. Format/init/validate, 15 mock-only plan tests and TFLint
passed. No ACA environment/application, managed identity, Key Vault or hosted
role assignment was created. The reference uses container-scoped Cosmos native
RBAC and versioned Key Vault secret references; a reviewed real plan and the
owner's exact resource/network authorization are still required for deployment.

The reusable Azure validation target retains its owned tagged resource group
and intended serverless account in ARM `Failed` state with no data endpoint.
Direct account readback on 2026-10-03 corrected the earlier empty-group inventory;
the Cosmos list command still returned zero. No usable account, database,
container, data-role assignment or cloud data result exists. Free-tier creation
was rejected by the subscription offer and the approved East US serverless
attempt failed for capacity. An alternative region and target require updated
owner approval; retain the failed record and reject empty-group retargeting.
No hosted clean-checkout onboarding is inferred from local/emulator evidence.

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
runtime/SDK artifacts. Final repository-authenticated registry workflow evidence
belongs in [#15](https://github.com/anaregdesign/cosmos-sync/issues/15).
