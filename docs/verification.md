# Verification

Local checks on 2026-10-03, macOS arm64. No Azure resources or real packages were created. Toolchain: Go 1.26.5, Dart 3.12.2, Docker 29.5.3.

| Check | Result |
| --- | --- |
| Go `go test -race ./...` | Passed: core/official-SDK fake transport and real JWT/JWKS integration tests; optional Dart fixture is skipped in ordinary runs |
| Go `go vet ./...` and CLI build | Passed |
| Dart `dart test` | 56 tests passed, real native SQLite |
| Dart `dart analyze --fatal-infos` | No issues found |
| Dart format check | No changes needed |
| Dart native example | Local pending data survived cache reopen, mutation acknowledged, deletion tombstone observed |
| `dart pub publish --dry-run` | Exit 0, 0 warnings; tooling accepts the pending LICENSE placeholder, but owner license/release authorization is still required |
| Go HTTP BFF + Dart cross-stack | Passed: signed JWT, SQLite restart/outbox, ACK, initial/incremental cursor sync, stale offline edit conflict after pull, delete/recreate |
| Docker local build | Passed; nonroot Go image, no registry push |
| Git whitespace check | Passed |

Critical failure cases covered include lost ACK/exact replay, overlapping server receipt lookup, operation payload mismatch, stale local base after remote pull, newer pending edits surviving old ACK, predecessor ACK version binding, local transaction rollback of page/cursor/token and ACK/dependency, delete retry persistence, scope/account switch, grant revocation, cursor/session purpose or scope tampering, 410 recovery, 429/5xx/backoff, poll Retry-After and in-flight logout before purge.

Cosmos adapter tests call the pinned official SDK using a deterministic fake HTTP transport. They verify partition/session request options, batch result status, receipt races, account policy and serialization boundaries. This is not a real Cosmos service/emulator test. Live single-write-region Cosmos and multiple BFF replicas, RU/load/retention/recovery behavior, mobile/desktop devices beyond this host and Flutter Web are unverified. These remain explicit release gates, not delivered production assurances. Web has no cache adapter in this slice.

GitHub CI repeats Go/Dart checks, the cross-stack fixture and Linux Docker build. See the draft PR checks for remote-run status. Publication workflows are gated/disabled and are not exercised by verification.
