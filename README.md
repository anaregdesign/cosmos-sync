# Cosmos Sync

A Go OIDC authentication/authorization BFF for **Azure Cosmos DB for NoSQL**, with a Dart/Flutter SDK for durable offline documents. Experimental v0.2 preview under the MIT license. Firestore inspires the offline experience; this is a separate API with [documented query and guarantee differences](docs/query.md).

Native SQLite and Chromium IndexedDB store confirmed documents and a durable outbox. Awaited local edits survive reopen; server ACKs are separate. The SDK provides local document/query watches, deterministic cached queries, pending/conflict metadata, retry-safe operation identities, explicit conflicts, tombstones and resumable sync. Built-in personal scopes and fixed-owner shared scopes use durable BFF authorization. Authenticated SSE hints supplement polling. Apps receive no Cosmos keys or privileged tokens.

Development is tracked by [epic #2](https://github.com/anaregdesign/cosmos-sync/issues/2). [Verification](docs/verification.md) reports actual results; owner-controlled distribution and live-cloud gates remain explicit.

The [2026-10-06 delivery plan](.azure/deployment-plan.md) separates completed
directory source/tooling from remaining compatibility, activation and acceptance.
It is a planning document, not approval to publish, deploy or operate a device.

The product goal is a Firestore-like developer experience for the supported
document subset: deploy the supplied BFF on Azure Container Apps, configure the
identity provider and compatible Cosmos storage, then connect the Dart SDK for authenticated
CRUD, watches, durable offline edits, reconnect and explicit conflicts. Application
developers should not have to implement a synchronization or security gateway.
The [onboarding guide](docs/developer-onboarding.md) distinguishes Terraform
resources, operator configuration and remaining acceptance work. Container Apps
Terraform and its runbook are tracked in [#31](https://github.com/anaregdesign/cosmos-sync/issues/31);
clean-checkout hosted onboarding is tracked in [#32](https://github.com/anaregdesign/cosmos-sync/issues/32).

**Authentication remains provider-neutral OIDC.** Entra External ID is the
preferred consumer reference broker, with Apple/Google as possible upstream
providers, not the only permitted generic BFF/native issuer. The public Terraform
is for each consumer's own environment and trust configuration. The
current source implements native OIDC/PKCE and explicit memory-only Entra/MSAL
or generic Code/S256 Web adapters with a dedicated API-access-token path.
[Browser setup](docs/web-auth.md) and [#40](https://github.com/anaregdesign/cosmos-sync/issues/40)
pin the source/standards-fixture evidence; this is not a new runtime publication
or actual provider acceptance. Generic browser sign-in does not advertise the
optional workforce-directory proof capability.
Published opt-in BFF lifecycle support is described below; actual Apple/Google
login and provider acceptance are not delivered support. The [social-login design
and roadmap](docs/social-auth.md) compares an API-token identity broker with
native provider login followed by a backend session exchange. Client-audience ID
tokens and access tokens for unrelated APIs are not Cosmos Sync API credentials,
regardless of provider name. BFF account and membership policy controls
document access, and matching email addresses must never automatically merge
accounts.

On 2026-10-04 the owner removed actual Google/Apple connections, provider
configuration and live-provider acceptance from this delivery. That scope
cancellation is not an Apple/Google denylist or a change to OIDC trust.
Development continues with simulators; physical Android verification is the
final gate.
Actual External ID fresh OIDC, hosted reader/Cosmos and final device acceptance
remain separate unfinished work, not inferred from workforce login or fixtures.

## Layout and verification

- `bff/`: Go service, official Azure SDK, security/atomicity tests and opt-in emulator integration.
- `packages/cosmos_sync/`: native/browser SDK, cache/query/HTTP tests and examples.
- `examples/flutter_app/`: normally runnable native/Web Flutter sample with OIDC login, real BFF transport and document/offline/conflict UI. See its [setup guide](examples/flutter_app/README.md) and [native authentication](docs/native-auth.md).
- `examples/flutter_smoke/`: separate deterministic native platform integration fixture; its test-injected transport does not demonstrate a real provider login or live Azure connection.
- `infra/terraform/azure-container-apps/`: pinned workload template, saved-plan deployment and mock checks; runtime acceptance stays separate from apply.
- `infra/terraform/aca-validation-plan/`: private backend VNet/endpoint/DNS/Vault prerequisites; see the [retained topology and deploy sequence](docs/aca-validation-plan.md).
- `tools/bootstrap_cursor_key.py`: offline-by-default cursor bootstrap and metadata-only existing-key reuse; [private-input example](ops/azure/cursor-bootstrap.example.json).
- `docs/`: [product scope](docs/spec/product-completion.md), [protocol](docs/protocol.md), [architecture](docs/architecture.md), [security](docs/security.md), [platforms](docs/platforms.md), [performance](docs/performance.md), [release](docs/release.md).

Use Go 1.26+ and Dart 3.12+; Flutter 3.44.6 is the measured native fixture baseline.

The SDK is a pure Dart package usable from Flutter; it does not contain widgets.
Flutter application code lives in `examples/flutter_app/lib/`. Configure the selected HTTPS BFF and public native/SPA OIDC client in that app.
Native restore uses OS secure storage; Web credentials remain in memory.
Credentials belong in the supported provider/browser flow, never source code or
a pasted token.
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
bash infra/terraform/aca-validation-plan/verify.sh
python3 -m unittest discover -s tools -p 'test_*.py' -v
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

The published BFF's [directory extension](docs/identity-directory.md) is explicitly
selected with [`config.directory.example.json`](bff/config.directory.example.json).
It wires a secret-free trusted broker reader, explicit fresh-proof registration/
link/unlink, stable random ownership, identity-bound sessions/cursors/caches and
confirmation/recovery UI. Proofs never replace the main credentials; email and
provider navigation never link accounts. Its current trusted Graph reader is
workforce-federation-specific, not universal social linking. The old SDK archive,
original image tags and retained Azure deployment are unchanged. Actual customer nonce/authentication-time,
MI/Graph and production capacity/recovery checks are required before deployment.
The Terraform workload supports explicit directory opt-in while preserving
builtin/legacy defaults. The compatible image is now published; activation still
needs current management-state validation and a separately approved saved plan,
not an unreviewed template apply.

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
is published from that original source, with archive/source and clean pub.dev
consumer verification. Its archive is unchanged; no SDK republication was performed.
GitHub source is public and private vulnerability reporting is enabled.
The current [public BFF image](https://github.com/anaregdesign/cosmos-sync/pkgs/container/cosmos-sync-bff)
is released from `36d2680e5f88d31acfafa4473d0d4996f1de0ff7`, after all nine
[main checks](https://github.com/anaregdesign/cosmos-sync/actions/runs/37433122046)
passed. Pin its immutable index digest
`sha256:adfe83a08dcd8754f85652641a85138e9a90993c1766ce70c86953365b9a6102`.
The [successful release verification](https://github.com/anaregdesign/cosmos-sync/actions/runs/37438116005)
confirmed public manifest access, amd64/arm64 content, MIT/nonroot metadata and
bound SBOM/BuildKit provenance; see [release](docs/release.md).
Exact registry access/verification evidence is recorded in
[#15](https://github.com/anaregdesign/cosmos-sync/issues/15) and
[#23](https://github.com/anaregdesign/cosmos-sync/issues/23).
The earlier [verification-tool correction](https://github.com/anaregdesign/cosmos-sync/issues/34)
preserved the original artifacts. [Epic #2](https://github.com/anaregdesign/cosmos-sync/issues/2)
keeps actual Azure, hosted onboarding and consumer-provider gates separate.
The retained Azure app still runs the original `82e937c` builtin image. The prior
read-only six-resource mirror remains unchanged. The approved distinct private
management state is now adopted and canonically validated: fresh baseline has
six no-ops and the saved directory overlay updates only the app image/runtime.
Actual app update remains unapproved; state preparation is not hosted acceptance.

Dedicated Entra registration is complete. macOS browser PKCE, secure credential
restore, refresh and local sign-out lifecycle stages were observed; independent
API JWT verification passed. The native wrapper's separate exit 1 is preserved
in [verification](docs/verification.md), rather than reported as an overall runner
success. Physical Android
app integration also passed real HTTP/SQLite with fixture authentication. The
retained East US environment contains its failed serverless account record.
The retained West US 2 serverless account, database/container and exact human
container role are created. Governance keeps public access disabled. All ten
private backend prerequisites applied; the cursor key was initialized once and
metadata-only public-tool reuse returned the same version without PUT. The BFF
UAMI and exact container/secret roles are created. ACA recovery returned ARM
`Succeeded` without a static IP or platform resources; the app failed with zero
revisions. The exact reviewed recovery plan subsequently replaced only those
same-name empty app/environment stubs and applied successfully on 2026-10-04,
retaining the key, data, network and IAM resources. Post-apply static IP,
image/identity/secret-reference and role/PE/DNS metadata checks passed; current
platform inventory has one public IP and one LB. This actual Azure checkpoint
still pins the original source `82e937c8659e9ec0263a78e6e3ad2f43e05be20a` image
`sha256:a23ab75eb4518597aa26e4833787b9b77a07def717868e080944555594adc1b3`;
publication of the newer image does not establish its runtime acceptance.
The original pinned image's file-config
CMD conflicted with environment JSON; the reviewed explicit ACA command/no-args
override fixed startup. Actual latest-ready Healthy, one Running container, zero
restarts/listening and eleven runtime checks passed. The saved return to min=0
applied and configuration readback passed. The final 19/19 checkpoint observed
Healthy/Provisioned/ScaledToZero and zero revision/actual replicas, with retained
charges and later scaling still possible. Five external health attempts include one Python CA failure and four macOS-TLS-verified Envoy RBAC 403 responses, with no
SDK execution or data writes. Fresh native lifecycle stages were observed and
independent API JWT verification passed; the wrapper's exit 1 is retained
separately, and that session has expired.
**External HTTPS access and the hosted SDK contract remain blocked**.
The Mac IP ACL does not provide direct Cosmos connectivity.

The environment's Azure Monitor destination, retained capped workspace and
HTTP-only diagnostic setting are configured and verified. The HTTP table/schema
exists, but requested Dedicated reads null and four bounded queries returned
API 200/zero rows: delivery and the 403 cause remain unverified. The
[diagnostic reuse procedure](docs/aca-validation-plan.md#reuse-the-http-diagnostic-configuration)
keeps actual target/correlation data private and does not create resources per retry.

Use the [retained private topology and portable deployment sequence](docs/aca-validation-plan.md)
for the exact settings, narrow IAM, immutable state/bootstrap workflow, saved
workload plan, recovery and network cost estimate. The current owner authorized
necessary minimal Azure/tenant setup and retention; resource apply does not
substitute for runtime acceptance. Separate CIAM API/native registrations and
API-only consent exist, while the consumer OIDC flow remains unverified.
Actual Google/Apple setup and login are outside the current delivery scope;
see [consumer identity setup](docs/external-id-setup.md).
[Physical-device acceptance](docs/physical-devices.md)
records the owner's unsigned iOS build choice: the build and simulator passed,
while unsigned physical iPhone execution cannot be verified.
