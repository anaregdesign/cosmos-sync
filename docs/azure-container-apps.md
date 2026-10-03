# Deploy the BFF to Azure Container Apps

Azure Container Apps (ACA) is the recommended hosted target. The developer goal
is to deploy the supplied BFF, configure a supported identity provider and access
policy, then connect the Dart SDK/sample using the HTTPS endpoint. Developers
should not have to implement their own sync or security BFF for the supported
subset. [The onboarding acceptance](developer-onboarding.md) tracks the complete
journey. This reference has **not been applied to Azure** and does not establish
hosted managed-identity, network, rollout or multi-replica acceptance.

The initial preview supports the documented protocol and offline behavior, not
all Firestore APIs or its query/security-rules model. Provider applications,
consent, redirects and Apple/Google credentials do not appear automatically when
the BFF starts; see [native auth](native-auth.md) and the
[Apple/Google integration plan](social-auth.md).

## Provisioned resources and prerequisites

The [Terraform directory](../infra/terraform/azure-container-apps/README.md)
contains a concrete, version-pinned reference, not a cloud deployment approval.

| Terraform creates/manages | Operator supplies and retains |
| --- | --- |
| Consumption ACA environment and one app; peer traffic encryption enabled | Existing approved resource group, subscription, tenant and region |
| Dedicated user-assigned managed identity, or the supplied existing identity | Existing Cosmos DB for NoSQL account, database and `/scopeId` container |
| Custom Cosmos native data role and assignment at that exact container | Session consistency, one write region, no expiring TTL, backup policy |
| Key Vault Secrets User assignments at named cursor/optional metrics/registry secrets | Existing RBAC-enabled Key Vault, secret versions and permitted network path |
| HTTPS ingress, startup/readiness/liveness probes, bounded HTTP scaling | Published BFF digest, OIDC API issuer/audience/scope, provider apps and consent |
| No new log workspace, database, network, secret or provider application | Explicit end-user authorization choice/configuration and deployment approval |

The new-deployment reference selects `authorization.mode=builtin`: the selected
contract gives a verified API principal its own personal scope; a shared-scope
creator is its fixed owner and manages reader/writer membership. It needs no
operator-maintained grant file, Entra group lookup or extra authorization service.
The implementation and security acceptance are tracked in
[#33](https://github.com/anaregdesign/cosmos-sync/issues/33). Terraform rejects a
builtin plan until `builtin_authorization_image_verified=true` explicitly asserts
that the selected immutable image passed that acceptance and the new namespace is
intentional. This assertion is not a substitute for release proof or deployment
approval. Explicit `authorization_mode="legacy"` renders empty grants and denies
all end users. Neither mode imports legacy partitions automatically; migration
must be reviewed separately. Never solve onboarding with a wildcard grant, trust
in email/client roles, or an auth bypass.

Only six Cosmos data actions are included: metadata read, item read/create/replace,
query and the SDK-required readChangeFeed permission. They allow the BFF's atomic
document/journal/receipt operations inside one logical partition, with no account
key access, hard deletion, stored procedures, throughput administration or
cross-partition transaction promise. [Cosmos data-plane permissions](https://learn.microsoft.com/en-us/azure/cosmos-db/reference-data-plane-security).

The caller running a future real plan/apply needs separately approved control
plane rights for the selected ACA resources, UAMI assignment, Cosmos native
role definition/assignment, and exact Key Vault role assignments. Provider
auto-registration is disabled. Check `Microsoft.App`, `Microsoft.ManagedIdentity`,
`Microsoft.DocumentDB`, `Microsoft.KeyVault` and `Microsoft.Authorization` first;
registration and broader rights require the owner's decision, not a silent
Terraform fallback. No Microsoft Graph data permissions are needed here.

## Configuration and TLS boundary

The template renders nonsecret JSON into `COSMOS_SYNC_CONFIG_JSON`. It contains
Cosmos/OIDC endpoints, policy references and limits; clients receive none of the
managed identity credentials or cursor key. It explicitly selects
`AZURE_TOKEN_CREDENTIALS=ManagedIdentityCredential`, with `AZURE_CLIENT_ID` for
the selected UAMI. The runtime must support these settings and
`COSMOS_SYNC_TLS_MODE=container-apps` before using this template's image.

ACA terminates external TLS at its edge ingress. `allowInsecure=false` prevents
plain HTTP application traffic; the app uses port 8080 and HTTP between its
process and the platform proxy. Peer encryption protects the platform network
hop inside the environment; it is not a certificate loaded by the Go process.
The explicit runtime mode requires ACA platform markers and HTTPS forwarded
protocol for application requests. The default BFF mode continues to require
direct TLS and ignores forwarded headers. Deploy only this workload or trusted
workloads in its environment; a forged header alone does not establish a trusted
network boundary. [ACA ingress](https://learn.microsoft.com/en-us/azure/container-apps/ingress-overview),
[platform peer encryption](https://learn.microsoft.com/en-us/azure/container-apps/ingress-environment-configuration#peer-to-peer-encryption-in-the-azure-container-apps-environment).

HTTP startup/readiness probes use `/readyz`; liveness uses `/healthz`. These probe
exceptions are restricted to the explicit ACA mode and return no document/token
data. Startup includes BFF configuration/OIDC/Cosmos metadata initialization.
Readiness is not a continuous proof of Cosmos availability, RU capacity or correct
membership policy. SIGTERM receives 15 seconds from ACA; the BFF drains requests
for 10 seconds. An interrupted mutation may have committed: the SDK replays its
durable operation ID instead of issuing a new operation. [Probe behavior](https://learn.microsoft.com/en-us/azure/container-apps/health-probes),
[container lifecycle](https://learn.microsoft.com/en-us/azure/container-apps/containers).

The default is 0.25 vCPU/0.5 GiB, zero-to-two replicas; the low-cost validation
example caps at one. Scale-to-zero adds cold start and polling/streams can keep
replicas active. HTTP scaling uses a threshold of 16; this is a concurrency
trigger, not a budget or a global rate limit. BFF limits are per replica and
aggregate with replica count. For production, select an approved minimum of one
and measure the relevant workload before increasing bounds. [ACA scaling](https://learn.microsoft.com/en-us/azure/container-apps/scale-app).

SSE is an authenticated hint, with 10-second heartbeats, five-second server polling
and a 20-second lifetime below the Go 30-second write timeout. ACA's ordinary
ingress timeout is 240 seconds, but neither proxy timeout nor an open stream
guarantees background delivery. The SDK resumes durable data by cursor on
foreground/reconnect and polling; test stream closure, cold start and offline
reconnection through the actual hosted ingress. Do not add sticky sessions to
compensate for mismatched cursor keys or policy across replicas.

## Secrets, network and state

`key_vault.cursor_secret_uri` is a **versioned** secret containing standard Base64
for at least 32 cryptographically random bytes. All serving replicas must use the
same key and history epoch. The optional metrics token remains server-only;
`/metrics` requires its separate bearer token. Public GHCR pulls need no registry
secret. Optional private GHCR requires an existing owner-approved pull credential
stored in a versioned Key Vault secret; Azure managed identity access to Cosmos
does not authenticate to GitHub Packages. [ACA secret references](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets).

Prefer a dedicated vault per application/environment even though the assignments
stop at named secrets: vault administrators and network policy operate at a wider
boundary. The module supplies secret URIs, not secret values, and never calls Key Vault
GetSecret or Cosmos listKeys from Terraform. ACA resources use AzAPI normal GET
and restricted nonsecret exports rather than AzureRM's `container_app` resource:
the latter calls listSecrets during reads and can place returned values in state.
Review new provider versions before changing that choice. AzureRM 5.8.0 is used
only for identity/role metadata and pinned AzAPI 2.13.0 manages the app/environment.
[AzureRM implementation](https://github.com/hashicorp/terraform-provider-azurerm/blob/v5.8.0/internal/services/containerapps/container_app_resource.go),
[versioned ARM environment schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.app/2025-07-01/managedenvironments).

Use an approved remote Azure Blob state backend with Entra/workload identity,
locking, encryption, limited access, versioning and recovery policy. The sample
`backend.hcl.example` contains only identifiers; adding its backend and migrating
existing local state is a separate reviewed action. `sensitive` flags only hide
terminal output and do not encrypt state. Treat plan/state backups as private;
never upload them to public Issues, CI artifacts or source. Use `umask 077` when
creating them, and do not put secret values in Terraform variables.
[Azure Blob backend](https://developer.hashicorp.com/terraform/language/backend/azurerm).

The approved Cosmos validation network plan permits only the Mac's current
egress IP; account creation is still blocked by regional capacity/selection.
That plan would not permit ACA connections. This module intentionally
does not change that firewall. A later deployment needs an approved egress/private
network design: existing delegated subnet, private endpoints/DNS, or a narrowly
approved stable egress route. Returned ACA outbound addresses are not a promise of
stable IPs. Do not open Cosmos/Key Vault to the world to get a probe passing.
Internal environments require a supplied delegated subnet; `external=true` app
ingress then means reachable at the environment's internal boundary, not public
internet access. [Network boundary](https://learn.microsoft.com/en-us/azure/container-apps/ingress-overview#how-ingress-visibility-interacts-with-the-environment-type).

Browser origins are exact HTTPS entries in `allowed_origins`, enforced by the BFF.
Native clients can leave the list empty. Provider redirect URLs belong to the
registered native/web app, not the API endpoint. The module does not enable ACA
Easy Auth; signature/audience/scope verification and current authorization remain
inside the BFF.

## Validate, deploy and upgrade

From a clean checkout with Bash, Python 3 and curl, run the pinned validator:

```sh
bash infra/terraform/azure-container-apps/verify.sh
```

It downloads Terraform 1.15.8 and TFLint 0.64.0 from their official releases,
verifies embedded SHA256 hashes, and uses an owned disposable tool directory.
Neither tool is installed globally. Checks need no Azure authentication and make
no Azure API requests or resources. Initial `init` downloads the pinned providers.
The lock file records official checksums for macOS/Linux ARM and AMD64. When these
exact tool versions are already on PATH, the equivalent checks are:

```sh
cd infra/terraform/azure-container-apps
terraform fmt -check -recursive
terraform init -backend=false -input=false -lockfile=readonly
terraform validate
terraform test
tflint
```

Terraform mock tests cover safe default/private/internal plans and rejection of
mutable image tags, unversioned/wrong-vault secrets, mismatched Cosmos endpoints,
wildcard browser origins, unsafe replica bounds and missing private subnet.
They prove template behavior, not ARM service acceptance or hosted security.

Local verification on 2026-10-03 passed format checks, signed/locked provider
initialization, schema validation, all 15 mock plan tests and TFLint. The complete
pinned validator also passed using a fresh temporary tool/provider directory;
an independent review confirmed its resource/security boundaries and fixed
secret-host and ambient-configuration regressions. No real Azure plan/apply or
hosted acceptance was performed.

After separately approving the exact new resources, billing target, identity,
roles and network changes, the operator can create an ignored private
`terraform.tfvars` from `terraform.tfvars.example`. Replace every placeholder,
including the image digest. Verify the selected image contains the accepted
builtin authorization implementation, intentionally select its new namespace,
then set `builtin_authorization_image_verified=true`; otherwise choose explicit
legacy/deny-all while preparing a migration. Configure the selected authorization
mode before applying.
Authenticate through the approved Azure context, initialize the approved backend,
then run a real **read-only** `terraform plan -out=reviewed.tfplan`. Review its
resource list, named-secret scopes and absence of broader/firewall/data changes.
Only the owner-approved saved plan is eligible for `terraform apply reviewed.tfplan`.
No deployment credentials or apply step belong in the current public CI.

After apply, record the stable `endpoint`, app/revision IDs and identity metadata.
Test HTTPS-only ingress, startup/probes, actual managed-identity data access,
unauthorized requests, the sample's authenticated CRUD/watch/offline/reconnect,
idempotent replay, stale-version conflicts and cache purge after revocation.
Repeat the accepted contract with two replicas and across a restart, proving
shared cursor key/policy and real network behavior. A local two-BFF test cannot
replace these hosted gates; track [#31](https://github.com/anaregdesign/cosmos-sync/issues/31)
and [#32](https://github.com/anaregdesign/cosmos-sync/issues/32).

Upgrades pin a newly verified image digest and keep protocol, key, epoch and
authorization settings compatible. Single-revision mode waits for the replacement
to become ready; it does not make all policy/key changes atomic. A secret reference
change alone does not automatically restart an existing revision. For cursor
rotation, deliberately create/restart every serving revision in a coordinated
maintenance window so old/new keys never serve together; changing the epoch/key
forces resync but retained operation receipts still protect replay. Keep the prior
compatible digest and configuration for rollback, and never roll back a revocation
or data migration merely to recover an image.

## Cost, retention and production hardening

The defaults avoid dedicated workload profiles, premium ingress, Log Analytics,
new networks and automatic data provisioning. `log_destination=none` has no
durable centralized container logs; use a separately approved existing Azure
Monitor destination, diagnostic settings, alerts and retention before production.
Measure per-replica memory/CPU, HTTP errors and restarts, protected BFF metrics,
Cosmos RU/throttling/storage, Key Vault access failures and client pending/conflict
rates. Do not log JWTs, authorization headers, grant JSON or document contents.

Zero replicas reduces ACA compute usage, not retained Cosmos storage/throughput,
Key Vault operations, network egress or separately selected services. Replica caps
are not spend caps; polling, snapshots and retry traffic consume Cosmos RU.
Review current regional prices, owner-defined budget alerts and cost attribution
before apply. [ACA billing](https://learn.microsoft.com/en-us/azure/container-apps/billing).

The Cosmos backup/retention policy remains under its existing owner. Journal and
receipt retention has a bounded capacity and no automatic garbage collection;
the BFF returns capacity errors rather than silently discarding replay evidence.
Production needs tested backup/restore, account lifecycle/migration, policy
revocation, JWKS/key rotation, threat/load tests and an approved private network
design. No regional failover, restore or load SLA is established by this template.

Keep reusable validation Cosmos, Entra and hosting resources unless the owner
explicitly requests retirement. All Terraform-managed resources have
`prevent_destroy`; existing Cosmos/database/container and the resource group stay
outside this state. Decommissioning requires a separate reviewed change, data
backup/export and dependency checks before removing guards. Never run a broad
resource-group deletion to clean up this deployment.
