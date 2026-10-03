# Verification

Local v0.2 checks on 2026-10-03, macOS 26.7 arm64. Production BFF and SDK source
commits are `9c2bdb8` and `a7998fe`. Go 1.26.5, Dart 3.12.2, Flutter 3.44.6,
SQLite package 3.5.2 and Docker 29.5.3 were used. No paid Azure resource,
publication, merge or deployment was performed.

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
Current remote outcomes are attached to [draft PR #1](https://github.com/anaregdesign/cosmos-sync/pull/1).
Publication workflows remain disabled/gated and are not exercised by verification.
Owner gates [#14](https://github.com/anaregdesign/cosmos-sync/issues/14),
[#15](https://github.com/anaregdesign/cosmos-sync/issues/15) and
[#16](https://github.com/anaregdesign/cosmos-sync/issues/16) remain open. A successful
pub dry-run does not approve the pending LICENSE, source disclosure or publication.
