# Local performance evidence

Measured on 2026-10-03 against the v0.2 development tree. Native Dart timing rows were rechecked after the SQLite compatibility and review fixes; timing is a single-run observation per size. The benchmarks exercise
Go MemoryStore and real native SQLite with an in-process Dart transport. They do
not contact Cosmos/Azure, create cloud resources, or measure HTTP/OIDC, network
latency, RU, regional consistency or a production SLA. The supported bounds and
correctness requirements are in [operational-bounds](spec/operational-bounds.md).

## Environment and method

| Item | Observation |
| --- | --- |
| CPU/architecture | Apple M3 Max, arm64, 16 logical processors |
| OS | macOS 26.7, build 25G229 |
| Go | 1.26.5, `GOMAXPROCS=16`; race detector disabled for timing |
| Dart | 3.12.2 stable, native JIT via `dart run`; final runs use sqlite3 3.5.2 (Flutter-compatible constraint) |
| Go fixture | 286-byte JSON data, 1,000/10,000 unique document mutations, page size 100 |
| Dart fixture | 256 ASCII text bytes plus group/score fields; sample JSON 287 bytes, 1,000/10,000 documents and peak pending edits |
| Repetitions | Go: three adaptive 200 ms samples per case; retained-heap profile: three runs; Dart: one final process run per size, ten query evaluations after one warmup query |
| Storage/memory | Native SQLite WAL with `synchronous=FULL`; Go allocation/heap counters and Dart current/maximum RSS; physical RAM was not collected |

This is a development machine with other development work possible, not an
isolated laboratory. Go setup for replay/snapshot cases is outside the timer;
mutation cases include a new store, bounded workers, canonical validation and
retained admission accounting. Dart startup/build hooks are outside phase timing,
but first cache open includes native-library initialization/JIT work. There is no
explicit warmup for non-query Dart phases. Different fixture sizes are separate
processes, so their timings are observations rather than a controlled scaling law.

## Go MemoryStore results

Times are medians of three samples. `B/op` and allocations are **per whole
workload**, not per document; each mutation iteration starts a fresh bounded store.
Parallel workers write unique IDs to the same scope. MemoryStore's mutex serializes
the store commit; parsing/validation can overlap. It is a test/development store,
not a substitute for Cosmos throughput measurement.

| Workload | 1,000 documents/history | 10,000 documents/history |
| --- | ---: | ---: |
| Validated mutation batch, 1 worker | 5.834 ms | 55.763 ms |
| Validated mutation batch, 4 workers | 3.880 ms | 47.936 ms |
| Validated mutation batch, 16 workers | 4.213 ms | 42.779 ms |
| Full retained replay, pages of 100 | 0.107 ms | 1.451 ms |
| Last 100 events read | 11.406 microseconds | 16.864 microseconds |
| Fold snapshot, all IDs distinct | 1.559 ms | 14.504 ms |
| Mutation allocation bytes, 1 worker | 4,954,768 | 49,462,142 |
| Mutation allocation count, 1 worker | 43,096 | 430,335 |
| Full replay allocation bytes | 450,080 | 4,500,800 |
| Snapshot fold allocation bytes | 1,604,746 | 15,377,256 |

The direct snapshot benchmark explicitly permits the fixture's 1,000/10,000
history changes and a calculated byte budget. The HTTP default of 4,096 changes
would reject the 10,000-change fold with 413 and use the client's ordinary journal
fallback. Raising the fold limit in a benchmark does not change that default.

The separate opt-in profile performs a GC before and after seeding a live store.
Median retained Go-heap delta was **854,048 bytes** for 1,000 documents and
**7,875,168 bytes** for 10,000. Total allocation during those seed runs was
5,036,504 and 50,338,424 bytes. The server's conservative retained admission
estimate was 5,139,679 and 51,426,682 bytes. Those quantities differ deliberately:
Go objects can share payload buffers, while admission accounting reserves three
encoded document copies plus fixed metadata allowance. None is physical Cosmos
storage or a billable RU estimate. MemoryStore has no persistent disk footprint.

Go's [MemStats](https://pkg.go.dev/runtime#MemStats) defines managed heap/allocation
counters; `TotalAlloc` includes allocations already collected. The
[testing benchmark API](https://pkg.go.dev/testing#hdr-Benchmarks) reports allocation
and elapsed-workload metrics. GC/profile overhead is not included in the mutation
milliseconds printed by the separate profile.

## Dart native SQLite results

Every phase passed count/replay-ID/version/cursor/coverage checks. Both runs
closed and reopened the pending cache, flushed every accepted write, replayed
the server journal and installed a fresh initial snapshot.

| Phase | 1,000 documents | 10,000 documents |
| --- | ---: | ---: |
| First empty cache open | 173.615 ms | 183.213 ms |
| Sequential durable enqueue | 165.573 ms | 911.885 ms |
| Close cache with pending writes | 3.806 ms | 4.977 ms |
| Reopen pending cache | 2.678 ms | 6.415 ms |
| Flush and commit ACKs, in-process transport | 188.798 ms | 4,710.066 ms |
| Replay changes after ACKs | 7.070 ms | 63.722 ms |
| Local filtered/sorted query, mean of ten | 13.602 ms | 131.721 ms |
| Fresh cache initial journal replay | 8.004 ms | 76.186 ms |
| Fresh cache initial snapshot install | 8.569 ms | 79.330 ms |

The query scans all cached views, filters `group == 3`, sorts descending score
with deterministic ID ties, and returns at most 100. A small result limit did not
avoid the full scan. The 10,000-document query took about 132 ms on this desktop;
run larger caches/query watches in an isolate and measure responsiveness on the
actual device. The observed flush uses an immediate deterministic fixture, so its
rate must not be advertised as an HTTP/Cosmos synchronization rate. Snapshot
installation uses a fixed fixture cutover and excludes server fold cost.

| SQLite file checkpoint | 1,000 documents | 10,000 documents |
| --- | ---: | ---: |
| Pending main database after close | 487,424 bytes | 4,575,232 bytes |
| Confirmed main database after close | 495,616 bytes | 4,583,424 bytes |
| Fresh journal-replay database after close | 405,504 bytes | 3,723,264 bytes |
| Fresh snapshot database after close | 405,504 bytes | 3,723,264 bytes |
| Active main DB + WAL + SHM at enqueue | 4,611,696 bytes | 8,687,168 bytes |

Disk records distinguish the database, WAL and shared-memory files. The main
cache's acknowledged outbox pages can remain allocated for reuse; this is not the
minimum logical size of the confirmed documents. The tool's later aggregate
directory size includes three separate fixture caches, not one cache. It deletes
its temporary directory after printing JSON.

Current RSS after first open was 241.17/241.41 MiB for the 1,000/10,000 runs and
after query evaluation 279.64/299.62 MiB. RSS includes JIT/runtime, native SQLite
and the in-process server journal/receipt fixture. Maximum RSS can include earlier
startup/compiler work, so it is not an isolated cache-memory measurement. The tool
prints RSS at every phase, not Dart managed heap. Dart defines
[currentRss](https://api.dart.dev/dart-io/ProcessInfo/currentRss.html) and
[maxRss](https://api.dart.dev/dart-io/ProcessInfo/maxRss.html) as process resident
memory metrics whose accounting is platform dependent.

## Reproduce without cloud access

From the repository root, with the Go version required by `bff/go.mod`:

```sh
GOCACHE="$PWD/.cache/go-build" GOMODCACHE="$PWD/.cache/go-mod" \
  go -C bff test -run '^$' -bench '^BenchmarkMemory' -benchtime=200ms -count=3

COSMOS_SYNC_RUN_BENCHMARK=1 \
GOCACHE="$PWD/.cache/go-build" GOMODCACHE="$PWD/.cache/go-mod" \
  go -C bff test -run '^TestMemoryOperationalProfile$' -count=3 -v

GOCACHE="$PWD/.cache/go-build" GOMODCACHE="$PWD/.cache/go-mod" \
  go -C bff test -race -run '^TestOperationalSnapshotBudgetBoundaries$' -count=1
```

From `packages/cosmos_sync`, after the normal package dependency setup:

```sh
CI=true PUB_CACHE="$PWD/../../.cache/pub" \
  dart --suppress-analytics run tool/benchmark.dart --documents=1000 --query-repetitions=10

CI=true PUB_CACHE="$PWD/../../.cache/pub" \
  dart --suppress-analytics run tool/benchmark.dart --documents=10000 --query-repetitions=10
```

On the measured host, the cached Dart SDK executable was used directly to avoid
the Flutter wrapper updating files outside the workspace. The tool writes one
JSON result to stdout and phase progress to stderr. Arguments bound documents to
1..10,000, text bytes to 1..4,096 and query repetitions to 1..1,000. A CI smoke run
can use `--documents=1000 --query-repetitions=1`; do not gate CI on elapsed-time
thresholds from this machine. The Go profile is opt-in in normal unit-test runs.

## Cost and practical use implications

Retained server growth follows **committed mutations**, including repeated edits,
deletions and immutable receipts, not just live document count. A 10,000-event
scope cap does not mean 10,000 distinct documents will always fit the byte cap.
Capacity exhaustion stops new admissions with 507 and preserves exact receipt
replay; it does not permit deletion of the history or lost-ACK identities.

Native list/query currently obtains every cached ID and performs document/outbox
reads for each view, then filters and sorts matches. Its work includes roughly two
SQL lookups per ID plus JSON decoding. A query's finite AST/limit bounds query
shape/output, not the entire input scan. Browser caches have their own map-copy
and transaction costs and require separate browser measurements; these native
numbers do not validate Chromium/mobile/other OS performance.

MemoryStore replay scans from the start of the journal per page: full replay can
perform O(H * ceil(H/P)) version checks for H events and page size P. Snapshot
folding also encodes H events for the byte budget, retains latest views and sorts
D IDs. The HTTP snapshot repeats the fold per output page, so total work can grow
with both history and output-page count. Cosmos uses its own indexed query path;
its RU/read cost is not inferred from this development-store complexity.

One scope's head serializes committed sequence allocation. Increasing request
concurrency does not remove that contention. Process-local rate/semaphore limits
are not cluster-wide limits. Poll/SSE subscriptions repeatedly authorize/read
even when unchanged, and many scopes/replicas require operational budgeting.

Before production, approved live Cosmos tests must measure RU/read-write costs,
index policy, 429 behavior, shared-scope contention, replica Session continuity,
failover and recovery under the selected capacity limits. Real device/browser
fixtures must establish responsiveness, cache storage and ownership behavior.
No publication, deployment or paid resource creation is authorized by these
measurements.

## Real Chromium IndexedDB measurements

A separate benchmark ran on 2026-10-03 at 12:09:35 UTC in real headless Chromium
154 on the macOS/Apple Silicon host above. Dart compiled the fixture to JavaScript
with `-O2`; compilation and browser startup are outside phase timing. Chromium's
reduced user-agent string reports Intel/macOS 10.15.7 and is not an independent
measurement of the actual host OS or CPU. The Python runner uses a fresh temporary
profile and an ephemeral loopback-only HTTP origin, waits up to 60 real seconds,
then stops the browser/process group and removes the profile. It does not use
virtual-time advancement.

The measured phases, query samples, storage estimates and correctness result are
preserved in the [raw JSON result](evidence/chromium-indexeddb-2026-10-03.json).

The fixture uses the actual IndexedDB adapter, its strict-durability transactions
and synchronous loaded mirror. It enqueues 1,000 unique document edits
sequentially, awaiting every durable commit. Each contains 256 ASCII text bytes,
group/score fields and about 287 JSON bytes. It closes and reopens the store with
all pending edits, compares exact outbox IDs/payloads/order/preconditions, then
prepares and commits 1,000 deterministic fixture acknowledgments. Each
acknowledgment involves separate prepare and ACK transactions. It installs
contiguous journal pages of 100, checks cursor/coverage, closes/reopens confirmed
state and checks the last version. There is no transport, OIDC server, BFF, Cosmos,
network synchronization, RU or server throughput in these timings.

| Phase, one browser run | 1,000 documents and peak pending edits |
| --- | ---: |
| First empty cache open | 46.900 ms |
| Sequential durable enqueue | 1,332.800 ms |
| Close cache with pending writes | 0.201 ms |
| Pending cache reopen | 10.900 ms |
| Prepare and commit fixture ACKs | 1,522.600 ms |
| Commit journal pages of 100 | 7.401 ms |
| Close confirmed cache | 0.200 ms |
| Confirmed cache reopen | 8.800 ms |
| Local scan/filter/sort query median, ten samples | 3.601 ms |
| Local query sample minimum / maximum | 3.301 / 4.299 ms |

The query scans all loaded document views, filters `group == 3`, sorts descending
score with ID tie-breaking and returns at most 100. One explicit warmup query is
excluded. Rows, pending state and coverage are checked on every measured query.
Other phases have one sample and no explicit warmup; browser startup, JIT and
concurrent machine activity may influence them. These are observed timings,
not responsiveness guarantees, a hardware-neutral rate or a production SLA.

`navigator.storage.estimate()` reported approximate whole-origin usage of
4,560 bytes before edits, 2,023,553 bytes with pending edits and 2,867,612 bytes
after confirmation/journal commits. Corresponding quota estimates were
10,737,422,800, 10,739,441,793 and 10,740,285,852 bytes. These are not physical
IndexedDB file sizes or an isolated cache allocation. They include origin storage
overhead and may reflect allocation retained after outbox deletion. The reported quota is
browser/profile policy, not an application entitlement or a promise that storage
will persist. No persistence permission was requested. The benchmark deletes its
own database before delivering its result; the runner also deletes the entire
disposable profile.

The browser adapter stores metadata, confirmed documents and outbox records
separately and persists only changed records. It still copies in-memory maps,
compares map entries and orders/scans pending records during writes. A sequence
of N growing enqueues can therefore incur O(N²) aggregate map/queue work even
though it does not rewrite one serialized whole-cache record. These measurements
establish a tested 1,000-document/1,000-pending-edit envelope for this small-payload
fixture only. Larger caches, repeated edits to the same document, large payloads,
browser UI responsiveness and mobile browsers need their own measurements;
10,000 browser records were deliberately not claimed from native results.

From the repository root after `dart pub get` in `packages/cosmos_sync`:

```sh
CI=true PUB_CACHE="$PWD/.cache/pub" \
DART_BIN=/path/to/dart \
CHROME_EXECUTABLE=/path/to/chromium \
  python3 tools/browser_benchmark.py --documents=1000
```

`--documents` is bounded to 1..1,000. A portable correctness smoke can use 50;
correctness and cleanup failures or a 60-second timeout fail the runner. Do not
use the development-machine timing values as CI pass/fail thresholds.

This 1,000-document rerun returned `PASS` after its database cleanup, and the
runner exited with code 0, stopped its dedicated browser and removed the
temporary profile. The standalone Dart benchmark passed `dart analyze` with no
issues and formatter verification; the Python runner passed syntax compilation.
CI uses a separate 50-document correctness smoke; its timing is not represented
in this table. The tools remain opt-in and contain no elapsed-time acceptance
threshold.
