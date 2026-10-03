# Cosmos Sync BFF

Go HTTP BFF for **Azure Cosmos DB for NoSQL**, using the official `azcosmos` Go SDK v1.5.0. The SDK supports conditional transactional batches and explicit session metadata, so this implementation needs no custom Cosmos REST client. Go 1.26 is used by the build.

## Run

Copy `config.example.json` to an untracked configuration and mount a grants file using `grants.example.json`. Set `COSMOS_SYNC_CURSOR_KEY_BASE64` to at least 32 cryptographically random bytes encoded as base64; all replicas must use the same secret. Use separate keys for separate environments. Rotation invalidates saved cursors and consistency envelopes and requires client resynchronization. Never ship this secret to an app.

```sh
go test -race ./...
go build -o cosmos-sync-bff ./cmd/cosmos-sync-bff
./cosmos-sync-bff -config /run/config/config.json
```

Production requires `COSMOS_SYNC_TLS_CERT` and `COSMOS_SYNC_TLS_KEY` paths for direct TLS. A TLS ingress must re-encrypt its connection to the BFF. Forwarded headers are not trusted. `development: true` requires a loopback listener such as `127.0.0.1:8080`; it does not bypass JWT verification. Memory storage is allowed only with this development setting and is deliberately volatile.

The OIDC issuer must use HTTPS and expose discovery/JWKS. Use a dedicated API audience and an access-token scope (`cosmos_sync` by default). Tokens need `sub`, a configured tenant claim (`tid` by default), valid issuer/audience/signature/expiry, and a complete space-delimited required scope. `nbf` is enforced. For issuers such as Cognito, configure `tokenUse: "access"` when that claim is available. The BFF never exchanges credentials or accepts ID tokens lacking the API scope.

The external grants JSON is read on every request, allowing active-token revocation and permission-version changes. Replace the file atomically and update all replicas together. An unreadable or invalid grants source fails closed. Bump `permissionVersion` whenever access policy changes. Removing a grant or setting `active: false` returns 403; previously issued cursors cannot survive a version change. Revocation cannot be discovered by an offline client until reconnection.

## Existing Cosmos resources

The BFF never provisions databases or containers. Grant its Azure managed/workload identity the minimum Cosmos data-plane rights on an existing container; local development can use existing Azure CLI identity through `DefaultAzureCredential`. No account key is configured in this sample or returned to clients.

Use `/scopeId` as the single logical partition path, enable range indexing of `sequence`, and use **one write region with Session or stronger consistency**. `singleWriteRegion: true` is an explicit deployment declaration; an SDK pipeline policy also rejects account metadata containing multiple write locations or weaker consistency. Container metadata is checked for the required partition key and no default TTL expiry. Disable external hard deletion, per-item TTL, and out-of-band modifications: retained documents, immutable journal entries, receipts and partition head must be owned exclusively by the BFF.

Each mutation uses one four-operation transactional batch: conditional sequence head, conditional document replacement/create, immutable journal event, and idempotency receipt. Head and document ETags prevent lost updates; request hash and operation ID detect replay and payload reuse. The receipt and document are reread after an overlapping retry to distinguish an accepted operation from a version conflict. Deletes retain tombstones. Journal replay begins at sequence zero, so initial loading has no separate snapshot/feed race. A sequence gap returns a retryable failure instead of advancing the cursor.

The partition key is SHA-256 over framed issuer, tenant and subject values derived from verified JWT and server grants. Expectation headers are compared with this result and never select a partition. Neither cross-partition transactions nor global order are provided. A head item serializes writes within each principal's partition and limits throughput. Journals/receipts/tombstones have no expiry in v0, creating ongoing RU/storage costs and a logical partition storage ceiling. Compaction requires a later explicit cursor-expiry/resync design.

`X-Cosmos-Sync-Session` carries an opaque HMAC-signed, scope/grant-bound Cosmos session token. It is nonprivileged consistency metadata. The client must persist/return it through writes and sync reads across replicas; point reads, partition queries, and batches forward it to Cosmos. The signed cursor is a different purpose and cannot be substituted. Client restarts and BFF replica switches rely on this propagation for read-your-writes. This behavior has fake-transport coverage, but needs live Cosmos multi-replica validation before deployment.

## Verification status

Tests use real RSA-signed JWTs and TLS OIDC discovery/JWKS, plus deterministic memory storage. Cosmos adapter tests drive the official SDK through a fake transport to verify the overlapping-receipt race, scoped requests and session headers. Additional tests cover causal batch failures and account consistency checks. No live Cosmos account or emulator was provisioned. Polling `/v1/sync` is the change notification mechanism in this slice; no SSE endpoint is advertised.

`TestDartFixture` in `tests` is skipped normally. Set `COSMOS_SYNC_E2E_READY_FILE` and `COSMOS_SYNC_E2E_STOP_FILE` for a bounded, local HTTP fixture with real signed JWT verification. It writes a disposable token into a mode-0600 ready file and stops after the stop file or 89 seconds.
