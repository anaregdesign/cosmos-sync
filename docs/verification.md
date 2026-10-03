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
| Flutter analysis and full app suite | No issues; 46 tests, including 37 auth lifecycle/native-adapter/secure-store tests |
| macOS app integration | Actual Go HTTP BFF, disposable signed JWT/JWKS issuer, SQLite, document/conflict/pending UI and an isolated native Keychain key; provider is a test adapter |
| Android physical SDK fixture | Pixel 9a / Android 17 API 37; actual SQLite and deterministic transport; cache close/reopen within the test process |
| Android physical application | Pixel 9a / Android 17 API 37; actual Go HTTP BFF, SQLite, offline reconnect/conflict/delete/purge UI and isolated native secure storage; signed-fixture auth adapter |
| Actual Entra native authentication | macOS system-browser AppAuth PKCE, callback, Keychain controller restore, provider refresh and local sign-out passed; both API JWTs independently verified against issuer/JWKS/audience/scope/tenant/approved owner |
| Normal iOS release build | Unsigned arm64 build passed from core `e7fa4ccb`; no physical install or Apple portal operation |
| iOS simulator app integration | iPhone 16 Pro / iOS 26.5; actual HTTP BFF, SQLite and isolated Keychain probe; local ad-hoc simulator signing and ephemeral arm64 workaround, test auth adapter |
| MIT archive | 72 KB strict pub publish dry-run, zero warnings; no upload |
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
