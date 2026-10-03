# Cosmos Sync

A Go OIDC authentication/authorization BFF for **Azure Cosmos DB for NoSQL**, with a Dart/Flutter SDK for durable offline documents. Private, unpublished v0.2 preview. Firestore inspires the offline experience; this is a separate API with [documented query and guarantee differences](docs/query.md).

Native SQLite and Chromium IndexedDB store confirmed documents and a durable outbox. Awaited local edits survive reopen; server ACKs are separate. The SDK provides local document/query watches, deterministic cached queries, pending/conflict metadata, retry-safe operation identities, explicit conflicts, tombstones and resumable sync. Optional shared tenant scopes and authenticated SSE hints use the same server authorization boundary. Polling recovers lost hints. Apps receive no Cosmos keys or privileged tokens.

Development is tracked by [epic #2](https://github.com/anaregdesign/cosmos-sync/issues/2). [Verification](docs/verification.md) reports actual results; owner-controlled distribution and live-cloud gates remain explicit.

## Layout and verification

- `bff/`: Go service, official Azure SDK, security/atomicity tests and opt-in emulator integration.
- `packages/cosmos_sync/`: native/browser SDK, cache/query/HTTP tests and examples.
- `examples/flutter_smoke/`: platform integration fixture.
- `docs/`: [product scope](docs/spec/product-completion.md), [protocol](docs/protocol.md), [architecture](docs/architecture.md), [security](docs/security.md), [platforms](docs/platforms.md), [performance](docs/performance.md), [release](docs/release.md).

Use Go 1.26+ and Dart 3.12+; Flutter 3.44.6 is the measured native fixture baseline.

```sh
cd bff
go vet ./...
go test -race ./...
go build ./...
cd ../packages/cosmos_sync
dart pub get
dart analyze --fatal-infos
dart test
dart test --platform chrome test/browser test/cache_conformance_test.dart test/src/query_test.dart test/src/http_transport_test.dart
dart pub publish --dry-run
cd ../..
python3 tools/cross_stack_smoke.py
bash tools/emulator.sh test
docker build -t cosmos-sync-bff:check bff
```

The local authenticated HTTP fixture needs no Azure account. The emulator runner uses a pinned official image, isolated loopback ports and an ephemeral test database; it does not touch other development stacks. Its Eventual account metadata is deliberately rejected by production policy. Test-only SDK construction exercises storage operations; actual cloud consistency/RU/backup remains a separate gate.

## Dart use

```dart
final transport = HttpSyncTransport(
  baseUri: Uri.parse('https://your-bff.example'),
  tokenProvider: () async => identityProviderAccessToken(),
  scopeMode: SyncScopeMode.user, // tenant requires a current server grant
);
final client = await CosmosSyncClient.open(
  path: '/app-private/per-principal-scope-cache.db',
  transport: transport,
);
await client.sync();
await client.put('note', {'title': 'Works offline', 'rank': 1});
print(client.get('note')!.hasPendingWrites); // durable local acceptance
await client.flush();
final rows = client.query(LocalQuery(limit: 20));
print(rows.documents);
client.startWatching(); // optional hints, with polling recovery
// On logout, wait for in-flight work before purging.
await client.signOut();
await client.close();
```

On web, `path` identifies an origin-local IndexedDB database. The default cache opens the appropriate native/browser implementation. New caches verify a server session; existing caches reopen offline. Cache identities should include principal and scope. A query cannot discover documents that have never been synchronized, and coverage is separate from freshness. See the [package guide](packages/cosmos_sync/README.md).

## Server and operational boundary

Start with `bff/config.example.json` and `bff/grants.example.json`. Configure a trusted HTTPS OIDC issuer, API audience/scope, authoritative grants and an existing `/scopeId` Cosmos container with TTL disabled, one write region and Session-or-stronger consistency. Cosmos uses server `DefaultAzureCredential`. Supply a shared random signing key through `COSMOS_SYNC_CURSOR_KEY_BASE64` and TLS paths through `COSMOS_SYNC_TLS_CERT`/`COSMOS_SYNC_TLS_KEY` using approved secret storage. The server serves TLS directly; ingress re-encrypts to it. Grant changes must be distributed atomically to every replica.

```sh
cd bff
go run ./cmd/cosmos-sync-bff -config /path/to/config.json
```

Startup validates an existing container and never provisions one. Mutation/head/event/receipt commits are atomic inside one scope partition. There is no global order, offline transaction, arbitrary server query, automatic merge or guaranteed OS background execution. All managed writes must use this protocol. Retained history has no GC; conservative configured capacity limits reject new writes while preserving accepted receipt replay. [Security](docs/security.md) and [performance](docs/performance.md) describe deployment obligations.

## Release status

No package/image has been published, no merge/deployment performed, and no paid Azure resource created. Planned image: `ghcr.io/anaregdesign/cosmos-sync-bff`; Dart package: `cosmos_sync`. Repo visibility remains private. License, public source/publisher decisions, GHCR namespace/access and an isolated live Azure environment are owner gates in [#14](https://github.com/anaregdesign/cosmos-sync/issues/14), [#15](https://github.com/anaregdesign/cosmos-sync/issues/15) and [#16](https://github.com/anaregdesign/cosmos-sync/issues/16). Existing GitHub authentication lacks `read:packages`; no permission was expanded. A dry run does not reserve or publish a package.
