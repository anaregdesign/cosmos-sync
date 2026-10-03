# Cosmos Sync

A Go OIDC authentication/authorization BFF for **Azure Cosmos DB for NoSQL**, with a Dart/Flutter SDK for durable offline documents. Experimental v0.2 preview under the MIT license. Firestore inspires the offline experience; this is a separate API with [documented query and guarantee differences](docs/query.md).

Native SQLite and Chromium IndexedDB store confirmed documents and a durable outbox. Awaited local edits survive reopen; server ACKs are separate. The SDK provides local document/query watches, deterministic cached queries, pending/conflict metadata, retry-safe operation identities, explicit conflicts, tombstones and resumable sync. Built-in personal scopes and fixed-owner shared scopes use durable BFF authorization. Authenticated SSE hints supplement polling. Apps receive no Cosmos keys or privileged tokens.

Development is tracked by [epic #2](https://github.com/anaregdesign/cosmos-sync/issues/2). [Verification](docs/verification.md) reports actual results; owner-controlled distribution and live-cloud gates remain explicit.

The product goal is a Firestore-like developer experience for the supported
document subset: deploy the supplied BFF on Azure Container Apps, configure the
identity provider and compatible Cosmos storage, then connect the Dart SDK for authenticated
CRUD, watches, durable offline edits, reconnect and explicit conflicts. Application
developers should not have to implement a synchronization or security gateway.
The [onboarding guide](docs/developer-onboarding.md) distinguishes Terraform
resources, operator configuration and remaining acceptance work. Container Apps
Terraform and its runbook are tracked in [#31](https://github.com/anaregdesign/cosmos-sync/issues/31);
clean-checkout hosted onboarding is tracked in [#32](https://github.com/anaregdesign/cosmos-sync/issues/32).

**Apple and Google are the intended practical end-user login providers.** The
current Flutter adapter implements native OIDC/PKCE with a dedicated Entra API
access-token validation path; Apple/Google login, account linking and provider
acceptance are additional work, not delivered support. The [social-login design
and roadmap](docs/social-auth.md) compares an API-token identity broker with
native provider login followed by a backend session exchange. Raw Apple/Google
ID tokens are not Cosmos Sync API credentials. BFF account and membership policy controls
document access, and matching email addresses must never automatically merge
accounts.

## Layout and verification

- `bff/`: Go service, official Azure SDK, security/atomicity tests and opt-in emulator integration.
- `packages/cosmos_sync/`: native/browser SDK, cache/query/HTTP tests and examples.
- `examples/flutter_app/`: normally runnable native Flutter sample with OIDC login, real BFF transport and document/offline/conflict UI. See its [setup guide](examples/flutter_app/README.md) and [native authentication](docs/native-auth.md).
- `examples/flutter_smoke/`: separate deterministic native platform integration fixture; its test-injected transport does not demonstrate a real provider login or live Azure connection.
- `infra/terraform/azure-container-apps/`: pinned, locally validated hosting template and mock-only plan checks; actual Azure deployment needs an approved plan.
- `docs/`: [product scope](docs/spec/product-completion.md), [protocol](docs/protocol.md), [architecture](docs/architecture.md), [security](docs/security.md), [platforms](docs/platforms.md), [performance](docs/performance.md), [release](docs/release.md).

Use Go 1.26+ and Dart 3.12+; Flutter 3.44.6 is the measured native fixture baseline.

The SDK is a pure Dart package usable from Flutter; it does not contain widgets.
Flutter application code lives in `examples/flutter_app/lib/`. Configure the
selected HTTPS BFF and native public OIDC client in that app. Credentials belong
in the OS browser and native secure store, never source code or a pasted token.
Actual provider/cloud/physical-device acceptance is tracked separately from the
existing local signed-fixture and simulator evidence.

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
python3 tools/authorization_cross_stack_smoke.py
bash infra/terraform/azure-container-apps/verify.sh
bash tools/emulator.sh test
docker build -t cosmos-sync-bff:check bff
```

The local authenticated HTTP fixture needs no Azure account. The emulator runner uses a pinned official image, isolated loopback ports and an ephemeral test database; it does not touch other development stacks. Its Eventual account metadata is deliberately rejected by production policy. Test-only SDK construction exercises storage operations; actual cloud consistency/RU/backup remains a separate gate.

## Dart use

```dart
final transport = HttpSyncTransport(
  baseUri: Uri.parse('https://your-bff.example'),
  tokenProvider: () async => identityProviderAccessToken(),
  scopeMode: SyncScopeMode.user, // own personal scope in built-in mode
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

For new deployments, start with `bff/config.builtin.example.json` and the
[Container Apps runbook](docs/azure-container-apps.md). Configure a trusted HTTPS
OIDC issuer, API audience/scope and an existing `/scopeId` Cosmos container with
TTL disabled, one write region and Session-or-stronger consistency. A verified
API token establishes a durable account and personal scope. The supplied
owner-only membership APIs authorize shared reader/writer access independently
of Entra groups or provider roles; see [authorization](docs/authorization.md).
Use the SDK's typed management API and
[shared-scope example](packages/cosmos_sync/example/shared_scope_example.dart).

Cosmos uses server `DefaultAzureCredential`; Container Apps uses a dedicated
managed identity with container-scoped data permissions. Supply a shared random
cursor key through approved secret storage. Standalone hosting serves TLS with
`COSMOS_SYNC_TLS_CERT`/`COSMOS_SYNC_TLS_KEY`; the explicit Container Apps mode
accepts its trusted HTTPS ingress boundary and Key Vault secret reference.
Existing deployments can retain `config.example.json` and explicit legacy
grants. That mode requires atomic grant distribution to every replica and is
not automatically migrated to built-in ownership.

```sh
cd bff
go run ./cmd/cosmos-sync-bff -config /path/to/config.json
```

Startup validates an existing container and never provisions one. Mutation/head/event/receipt commits are atomic inside one scope partition. There is no global order, offline transaction, arbitrary server query, automatic merge or guaranteed OS background execution. All managed writes must use this protocol. Retained history has no GC; conservative configured capacity limits reject new writes while preserving accepted receipt replay. [Security](docs/security.md) and [performance](docs/performance.md) describe deployment obligations.

## Release status

The Flutter app, durable authorization and hosting preparation were merged in
[PR #25](https://github.com/anaregdesign/cosmos-sync/pull/25); all eight
[main checks](https://github.com/anaregdesign/cosmos-sync/actions/runs/37140346546)
passed at release source `82e937c8659e9ec0263a78e6e3ad2f43e05be20a`.
The MIT [cosmos_sync 0.2.0-dev.1 preview](https://pub.dev/packages/cosmos_sync/versions/0.2.0-dev.1)
is published, with archive/source and clean hosted-consumer verification.
GitHub source is public and private vulnerability reporting is enabled.
The [public BFF image](https://github.com/anaregdesign/cosmos-sync/pkgs/container/cosmos-sync-bff)
uses the same artifact source; pin its index digest
`sha256:a23ab75eb4518597aa26e4833787b9b77a07def717868e080944555594adc1b3`.
Exact registry access/verification evidence is recorded in
[#15](https://github.com/anaregdesign/cosmos-sync/issues/15) and
[#23](https://github.com/anaregdesign/cosmos-sync/issues/23).
The later [verification-tool correction](https://github.com/anaregdesign/cosmos-sync/issues/34)
preserves those published artifacts. [Epic #2](https://github.com/anaregdesign/cosmos-sync/issues/2)
keeps actual Azure, hosted onboarding and consumer-provider gates separate.

Dedicated Entra registration and actual macOS browser PKCE, API-token validation,
secure credential restore, refresh and local sign-out passed. Physical Android
app integration also passed real HTTP/SQLite with fixture authentication. The
approved reusable Azure environment currently contains an empty tagged resource
group; free-tier creation was rejected by the subscription offer and East US
serverless creation failed because of capacity. Cosmos data operations await
approval of an alternative region. Reusable Cosmos/Entra resources will be
retained. Container Apps is the intended hosted target; its Terraform preparation
does not authorize an actual deployment. [Physical-device acceptance](docs/physical-devices.md)
records the owner's unsigned iOS build choice: the build and simulator passed,
while unsigned physical iPhone execution cannot be verified.
