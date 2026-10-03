# Cosmos Sync

A **Go** authentication/authorization BFF for **Azure Cosmos DB for NoSQL** and a native Dart offline document SDK for Flutter apps. Early prototype, private repository. Inspired by Firestore's offline experience; no Firestore compatibility claim.

The first slice provides native SQLite cache, local reads/watch streams, durable pending writes, retry-safe mutation IDs, explicit version conflicts, retained delete tombstones, initial/incremental journal sync and periodic polling. The BFF validates OIDC access JWTs and enforces server-owned tenant/user scopes. Apps receive no Cosmos credentials.

## Layout

- `bff/`: Go HTTP service, official Azure `azcosmos` adapter, memory test store and JWT/security/concurrency tests.
- `packages/cosmos_sync/`: Dart SDK, SQLite cache/outbox, HTTP transport, example and tests.
- `docs/`: [requirements](docs/spec/offline-sync.md), [wire protocol](docs/protocol.md), [architecture and limits](docs/architecture.md), [security boundary](docs/security.md), [official-source research](docs/research.md), [release preparation](docs/release.md).
- `.github/workflows/`: verification, image build without publication and disabled-by-default manual GHCR preparation.

## Verify locally

Use Go 1.26+ and Dart 3.12+ (Flutter's bundled Dart is suitable).

```sh
cd bff
go vet ./...
go test -race ./...
go build ./...
cd ../packages/cosmos_sync
dart pub get
dart analyze --fatal-infos
dart test
dart pub publish --dry-run
cd ../..
python3 tools/cross_stack_smoke.py
docker build -t cosmos-sync-bff:check bff
```

The cross-stack test starts a disposable local Go BFF with real RSA JWT validation and a memory store, then checks Dart's offline/restart/sync/delete path. It requires no Azure account. Cosmos production/emulator behavior is a separate integration gate. The pub dry-run never uploads; a pending/UNLICENSED placeholder is not release authorization.

## BFF configuration

Start from `bff/config.example.json` and `bff/grants.example.json`. Configure a trusted HTTPS OIDC issuer, API-specific audience/required scope, current server grants and an existing Cosmos container with `/scopeId`. Supply a shared, random signing key through `COSMOS_SYNC_CURSOR_KEY_BASE64` and readable TLS certificate/key paths through `COSMOS_SYNC_TLS_CERT`/`COSMOS_SYNC_TLS_KEY`; keep these in approved runtime secret storage. The entrypoint serves TLS directly, so ingress must re-encrypt to it. Cosmos authentication uses `DefaultAzureCredential` on the server; no client receives credentials. The service reads the configured grants file per request, so publish grant changes atomically and distribute them to every replica.

```sh
cd bff
go run ./cmd/cosmos-sync-bff -config /path/to/config.json
```

Startup connects to an existing container, verifies its partition key/retention configuration and never provisions resources. `development=true` plus `storage=memory` is an ephemeral local test store, while JWT verification remains enabled. Production requires TLS and a durable Cosmos store. See [security](docs/security.md) before hosting it.

## Dart use

```dart
final transport = HttpSyncTransport(
  baseUri: Uri.parse('https://your-bff.example'),
  tokenProvider: () async => identityProviderAccessToken(),
);
final client = await CosmosSyncClient.open(
  path: '/app-private/per-account-cache.db',
  transport: transport,
);
await client.sync();
client.put('note', {'title': 'Works offline'});
print(client.get('note')!.hasPendingWrites); // true, durably queued
await client.flush();
client.startPolling();
// At logout: purge local documents/outbox before another account uses this path.
await client.signOut();
await client.close();
```

New cache initialization verifies the server session. Reopening a cache can work offline; all network delivery rechecks identity and permission version. Local data is a partial cache; undiscovered server data is unavailable offline. Conflict resolution is explicit through pending state, retry/discard APIs; no automatic LWW. See the package example/README for lifecycle and cleanup details.

## Guarantees and limits

One committed mutation atomically changes a document, journal event, receipt and sequence **inside one user logical partition**. There is no global ordering, offline transaction or cross-partition transaction. Every receive page and cursor commits together locally. A late ACK preserves later pending edits. Scope/permission assertions checked against the validated token prevent account-switch delivery; 401/403 or changed scope conservatively purges and pauses the cache/outbox. A disconnected device cannot know about revocation.

Journal, tombstones and receipts currently have no TTL. History grows and creates Cosmos storage/RU cost; snapshot compaction, quota and production load/recovery tests are follow-up work. Only BFF-mediated writes maintain synchronization. Flutter Web, general query syntax, shared document ACLs, automatic merges and realtime fanout are outside this slice. Native platform metadata does not replace device testing; current validation is reported in [verification](docs/verification.md).

## Release status

No package, image or site has been published and no paid Azure resources have been created. Planned image: `ghcr.io/anaregdesign/cosmos-sync-bff`; Dart package: `cosmos_sync`. Repository visibility remains private. License/publication/publisher decisions and production OIDC/Cosmos/hosting configuration remain with the owner. GHCR name collision lookup needs `read:packages`, absent from the current user token; no scope was expanded. See [release preparation](docs/release.md).
