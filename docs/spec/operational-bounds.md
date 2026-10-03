# Operational bounds and benchmark acceptance

Status: v0.2 target and local measurement contract, 2026-10-03. Actual observations
belong in [performance](../performance.md). These requirements bound development
fixtures and supported preview usage; they are not a Cosmos RU, latency or
availability SLA.

## Capacity and correctness

The server retains every committed event, tombstone and immutable operation
receipt. Compaction/TTL/unsafe garbage collection is disabled. Per-scope admission
checks bound journal event count and conservative estimated retained bytes before
committing a new mutation. Exact receipt replay remains possible when capacity is
full; rejected admissions do not consume a sequence or leave a partial document,
event or receipt. Return 507 `scope_capacity_exceeded`, report the condition to operators
and stop accepting new work until capacity is deliberately resolved.

Current defaults are 10,000 retained events and 128 MiB estimated retained bytes
per scope. They are safety defaults, not experimentally proven cloud capacity.
The byte estimate is conservative accounting rather than physical Cosmos billing
or disk allocation: three encoded document copies plus a 4,096-byte allowance per
committed mutation; replacements add rather than credit earlier bytes. Large
documents can hit the byte budget far before the event count. A scope with
repeated edits can reach its event cap with few
live documents. Do not reset counters, remove receipts or raise limits silently.

Request controls are finite: when enabled, 64 concurrent HTTP requests, a
per-principal 120 requests/minute token bucket with burst 30, and at most 10,000
principal buckets. SSE has an eight-stream semaphore even when ordinary rate
limits are disabled. These controls are per BFF process; multiple replicas require
an upstream/distributed policy before claiming a global limit. Defaults and
configured ranges must be documented alongside validation tests.

Mutation bodies are at most 512 KiB, server document JSON at most 256 KiB and
native/client document JSON conservatively at most 255 KiB. Sync pages have at
most 100 records and a configurable payload-byte budget, default 4 MiB. Returning
a partial bounded page must advance only through included contiguous records;
an oversized individual record produces an error rather than an empty complete
page. Payload limits protect work and serialization, not total history size.

The snapshot endpoint folds immutable history only through its captured cutover
sequence and sorts IDs deterministically. Default limits are 4,096 replayed
changes and 64 MiB replay bytes. Over-budget folding returns a typed 413; callers
can resume ordinary retained-journal synchronization. Every snapshot page can
repeat the fold, so endpoint limits do not imply cheap pagination. No snapshot
or generation change authorizes removal of old events or receipts.

SSE notifications are hints backed by ordinary resume/poll synchronization.
Default server poll interval is one second, heartbeat 15 seconds and stream
lifetime 60 seconds. Production polling has a 100 ms floor and stream lifetime
cannot exceed 300 seconds. Each polling stream adds authorization and journal
read work even without changes; operators must budget that load and reconnects.
Closed-app/background delivery is not promised.

## Cache ownership and practical local size

One owner writes a cache at a time. Native files use a single isolate owner;
browser IndexedDB uses an exclusive lifetime Web Lock. Synchronous get/list/query
reads operate on an opened cache. Await put/delete, acknowledgment, page and
snapshot commits before claiming durable local success. Preserve the outbox on
quota/disk errors and never switch silently to volatile storage.

The initial reproducible workload uses 1,000 and 10,000 small documents, sequential
durable edits, a bounded outbox, page size 100 and bounded query result limits.
Use a small native fixture first, record actual results, and do not advertise the
upper fixture as verified on browsers or mobile devices without their evidence.
Native SQLite and browser in-memory mirrors have different size/latency behavior.
Use a dedicated isolate/worker for larger workloads and keep foreground writes
and query watches within application responsiveness budgets.

The native fixture's transport is an in-process journal with exact operation
receipts; it excludes HTTP, OIDC, Cosmos, network latency and server backpressure.
Its flush rate measures client orchestration/storage only. Every benchmark checks
accepted-write count, restart persistence, acknowledgments, final replay cursor
and query/snapshot result counts. A faster incorrect run must fail.

## Reproducible measurement requirements

Go benchmarks measure validated MemoryStore mutation batches with one/four/sixteen
bounded workers, full paginated replay, tail reads and bounded snapshot folding.
Each mutation batch uses a fresh store with a fixed number of operations so an
adaptive `testing.B` run cannot accumulate unbounded history. Record allocations
per workload and, in an opt-in profile, elapsed time and retained heap after GC.
MemoryStore is a development/test fixture with a process-wide mutex; its results
do not model Cosmos throughput or regional concurrency.

Dart native benchmarks measure durable enqueue, close/reopen, outbox flush,
paginated replay, local filtering/sorting and snapshot installation where supported.
Record per-phase elapsed time, operation count, current/maximum process RSS and
SQLite database/WAL/SHM sizes at documented checkpoints. RSS is process memory,
not Dart managed heap. The SDK has no portable public exact-heap API; do not label
RSS as heap. Retain no real user data or credentials and clean up temp fixtures.

Include runnable commands, toolchain/OS/architecture/CPU/memory facts, fixture
sizes, page size, JSON payload bytes, warmup policy and measurement repetitions.
Record successful runs as observations, not pass/fail throughput promises. Tests
gate count/version/cursor/receipt correctness and capacity behavior. CI may run a
small smoke fixture; environment timing variation must not cause false failures.

## Expected growth and external validation

Retained server storage grows with committed history and payload size, including
journal and receipt copies, not just current documents. Native SQLite stores
confirmed documents plus pending mutations; WAL/free pages and acknowledged
history affect disk measurements. Local queries scan the cache and sort matching
views; a limit bounds output, not the input scan. Snapshot folding traverses
history and keeps the latest document per ID, then sorts IDs; repeated pages
repeat that work. All these costs need measurement as scopes/outboxes grow.

Production release still requires approved live Cosmos measurements of RU,
indexing, throttling, account/session consistency, failover, replica effects,
managed identity and backup/recovery. Validate per-scope limits against the chosen
Cosmos logical-partition limits and shared-head contention. Publishing an image
or a benchmark does not authorize paid resources, broader credentials, secrets,
deployment, package publication or a legal-license decision.
