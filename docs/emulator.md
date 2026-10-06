# Local Cosmos integration verification

The test suite uses the official Cosmos DB for NoSQL Go SDK against a local
official Linux vNext emulator. It must create only ephemeral emulator databases;
it refuses non-loopback endpoints. Production BFF authentication remains Azure
identity based and does not accept an emulator key.

The integration acceptance criteria are atomic document/head/journal/receipt
writes, failed ETag batch rollback, exact idempotent replay after a lost ACK,
payload-mismatch rejection, ordered paginated bootstrap and incremental sync,
delete/recreate tombstones, scope isolation, and session-token propagation across
independent SDK clients. The TLS HTTP BFF must validate real signed JWTs and
server grants with its normal production request handler, keep each actor's
idempotency receipts isolated in a shared tenant scope, and authenticate cursor
and session transfer between independent BFF instances. An explicitly configured
test endpoint that is not
available or fails these checks must fail the suite. An ordinary unit-test run
without the opt-in environment variable may skip it.

The emulator cannot establish Azure replica consistency, real RU costs, custom
index effectiveness, regional failover or production authorization with managed
identity. Those checks require a separately approved Azure environment and remain
release gates even when this suite passes.

Run `bash tools/emulator.sh test` from the repository root with Docker and Go
installed. The script uses a pinned official image digest, container name
`cosmos-sync-emulator`, API endpoint `http://127.0.0.1:8085`, readiness port 8086,
and no explorer, telemetry or persisted volume. It verifies the container's
ownership label before reusing or removing it. It removes a container it started
for the test, and leaves a previously started emulator running. The suite creates
a uniquely named database and deletes it with a separate cleanup timeout.
`bash tools/emulator.sh start` and `bash tools/emulator.sh stop` are available for
explicit local lifecycle control.

Only the `_test.go` file contains the public emulator key. It refuses non-loopback
endpoints. Do not pass an Azure account URL to these tests or reuse this key factory
in production. HTTP is scoped to this loopback test container; production Cosmos
continues to require HTTPS and Azure identity credentials. An opt-in test failure
is never treated as a skip.

## Evidence and limits

On 2026-10-03, macOS ARM64 and Docker 29.5.3, the official image digest
`sha256:2db1f9e74c506bcf6fc347aa937aea1c00fa756061296a5a9efba530ce86ec02`
reported emulator version EN20260907. `go test -race` against its real API passed:

- Atomic four-item mutation, matching idempotency replay with a fresh SDK client,
  request-hash mismatch rejection and exactly one journal entry.
- A stale ETag replacement failing a transactional batch, with neither a preceding
  create nor the replacement committed.
- Initial sync, resume with one-item pages, a concurrent update between pages,
  delete tombstone, recreation, conflict rejection and separate scope isolation.
- Eight independent SDK clients committing concurrently into one partition with
  eight contiguous journal sequence numbers.
- Explicit session-token transfer reaches the request of a fresh SDK client.
- Two independent TLS BFF instances, normal JWT discovery/JWKS verification and
  real Cosmos stores: shared tenant scope with actor-specific idempotency receipts,
  exact replay through the other BFF, signed cursor/session transfer, denied
  principal spoofing and rejected invalid JWT signatures.
- The actual production account guard rejects the emulator's `Eventual`
  account metadata.

One run returned session token `0:0#87` from the mutation response. The suite
captured the same token in a fresh client's actual head-read request. This records
real header propagation, rather than simulated session consistency. All six
subtests passed with the Go race detector. A fresh-container rerun returned
`0:0#1`, also transferred to the fresh client's request, and the runner removed its
own labeled container on success. The BFF replicas in this suite are
separate HTTPS server/SDK instances inside one test process; they do not model
Azure's geographic replicas or independent operating-system processes.

The emulator metadata advertises `Eventual` as its account consistency. The
production BFF's account guard correctly rejects this value. The test-only
factory omits that guard to verify the emulator's actual storage API, while
retaining the production batch serialization policy. This test is not evidence
that `Eventual` is safe, that the guard can be relaxed, or that session consistency
works across real Azure replicas. Production Session-or-stronger metadata and
cross-replica read-your-writes require the approved Azure verification gate.

Reference: [Microsoft vNext emulator documentation](https://learn.microsoft.com/en-us/azure/cosmos-db/emulator-linux)
lists ARM64, gateway API, batch, query pagination and health-probe support. It also
states that request units are not implemented and custom indexes are a no-op.

## Internal identity and broker persistence checkpoint

The later suite adds one-partition directory contention and durable broker
fingerprint checks; all nine subtests passed with the race detector in a fresh
owned container. Independently signed local API/ID proofs and a strict local
Graph response register a random account with its exact expected upstream
binding. A separate actual SDK client reloads that binding and resolves the
same account. A replaced upstream credential is denied without modifying the
record or its ETag. These provider/Graph responses are fixtures, not actual
customer login or hosted managed-identity execution. Production consistency
guards, retained Azure resources and active HTTP authorization are unchanged.
