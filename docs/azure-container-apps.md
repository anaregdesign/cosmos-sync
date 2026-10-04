# Deploy the BFF to Azure Container Apps

Azure Container Apps (ACA) is the recommended hosted target. The developer goal
is to deploy the supplied BFF, configure a supported identity provider and access
policy, then connect the Dart SDK/sample using the HTTPS endpoint. Developers
should not have to implement their own sync or security BFF for the supported
subset. [The onboarding acceptance](developer-onboarding.md) tracks the complete
journey. Actual Azure work is now staged: the private prerequisites and cursor
bootstrap/reuse passed, and the workload's UAMI plus exact container/secret roles
exist. An environment recovery PUT returned `Succeeded`, but no static IP or
platform resources appeared; the app failed with zero revisions.
**The reviewed replacement of only these empty app/environment stubs is underway;
runtime acceptance is pending**. Hosted managed-identity/network,
readiness, SDK and rollout acceptance remain open. The
[retained topology and portable deployment sequence](aca-validation-plan.md)
records completed stages, exact settings/IAM, costs and current blockers;
[verification](verification.md) is the acceptance record.

The initial preview supports the documented protocol and offline behavior, not
all Firestore APIs or its query/security-rules model. Provider applications,
consent, redirects and Apple/Google credentials do not appear automatically when
the BFF starts; see [native auth](native-auth.md) and the
[Apple/Google integration plan](social-auth.md).

## Provisioned resources and prerequisites

The [Terraform directory](../infra/terraform/azure-container-apps/README.md)
contains the concrete pinned workload module. The separate
[private prerequisites](../infra/terraform/aca-validation-plan/README.md) create
its VNet, backend Private Endpoints/DNS and private Vault. A mock plan is not a
cloud-acceptance receipt; a real plan must match the operator's authorized target.

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

The operator needs control-plane rights for the selected ACA/network resources,
UAMI assignment, the account's Cosmos native role definition/assignment and exact
Key Vault role assignments. Runtime data rights remain at the container/secret.
The current owner authorized necessary minimal settings/resources in the selected
subscription; future operators must use their own authorized target and reviewed
saved plans. Provider auto-registration is disabled. Check `Microsoft.App`,
`Microsoft.Network`, `Microsoft.ManagedIdentity`, `Microsoft.DocumentDB`,
`Microsoft.KeyVault` and `Microsoft.Authorization`; register only what is needed.
The current environment also required the exact Network feature
`AllowBringYourOwnPublicIpAddress`, which now reads Registered. No Microsoft Graph
data permissions are needed for this hosting module. The
[topology IAM table](aca-validation-plan.md#required-settings-and-operator-iam)
separates operator setup from runtime permissions.

For a concrete infrastructure cost/ownership scope, set the optional
`infrastructure_resource_group_name` to a new, unused resource group name. The
module writes only the environment's `properties.infrastructureResourceGroup`;
ACA creates and manages the platform group in the approved environment/subnet
subscription. It does not become a separately managed Terraform resource group.
The default `null` omits the property and keeps Azure's generated naming. Input
is an unqualified 1–90 character name in the safe ASCII subset (letters, digits,
underscores, hyphens, periods and parentheses, without a trailing period), never
an ARM ID. Check availability before the reviewed apply, and include
that platform group and its resources in the owner's cost/retention review.
Do not use an existing application/data/networking group or infer that the
supplied name grants deletion authority. [Managed environment schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.app/2025-07-01/managedenvironments#managedenvironmentproperties),
[resource group naming rules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules#microsoftresources).

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
creating them, and do not put secret values in Terraform variables. The current
validation uses private local state at 0600 in 0700 directories; no remote
backend creation/migration is claimed.
[Azure Blob backend](https://developer.hashicorp.com/terraform/language/backend/azurerm).

The successful retained West US 2 account has governance-enforced public network
access disabled. Its retained Mac IP rule provides no direct route. The private
Cosmos/Vault endpoints, DNS links and separate delegated ACA subnet are now
created; runtime route/secret resolution remains an acceptance gate. This module
does not change the Cosmos firewall. Use the
[retained topology](aca-validation-plan.md) rather than an outbound-IP allowlist;
public restoration and policy exceptions are excluded. Returned ACA outbound
addresses are not a promise of stable IPs.
Do not open Cosmos/Key Vault to the world to get a probe passing.
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
bash infra/terraform/aca-validation-plan/verify.sh
python3 -m unittest discover -s tools -p 'test_bootstrap_cursor_key.py' -v
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

Current local validation on 2026-10-04 passed format, locked provider init,
schema validation, 22 workload mock plans, seven private prerequisite mock plans,
TFLint and the fresh pinned validators. Public cursor-bootstrap tests passed all
30 offline cases, including private raw-state provenance, FIFO/symlink refusal,
metadata-only existing-key reuse, durable prewrite intent and ambiguous outcomes.
The ten-resource prerequisite apply and the initial key/metadata reuse are actual
Azure results. These do not establish hosted health, secret resolution or Cosmos
managed-identity access.

Follow the [portable staged sequence](aca-validation-plan.md#portable-deployment-and-acceptance-sequence):
compatible Cosmos storage, saved prerequisite plan/apply, immutable raw-state
copy, bootstrap config/state SHA, public tool local plan, one authorized key
initialization **or metadata-only existing-key reuse**, then actual version-URI
inputs and the saved workload plan/apply. The
[bootstrap example](../ops/azure/cursor-bootstrap.example.json) contains placeholders;
keep filled copies private. `--execute` requires an existing authority reference
and one designated writer; it never rotates an existing or uncertain key.
The CLI profile stays explicit and its default context is checked unchanged.

Create ignored private `terraform.tfvars` from `terraform.tfvars.example` and
replace every placeholder. Verify that the pinned published image contains the
accepted built-in policy, select its intentional new namespace, then set
`builtin_authorization_image_verified=true`. Otherwise use explicit legacy/deny-all
while preparing a separately reviewed migration. Include the exact operator `/32`,
private delegated subnet, named-secret URI, no log destination and validation
replica cap in the real plan. Use `umask 077` and save/read the plan privately.
Apply only that reviewed plan within the owner's existing authority. Public CI
contains no deployment credentials or apply step.

The disabled log setting now renders `appLogsConfiguration.destination=null`;
the Azure RP rejects the string `"none"`. If a service failure leaves the owned
environment present, read it back and reconcile/import its exact ID into the
same private state before a new saved plan. Check actual static IP, owned
platform-managed LB/IP resources and serving revisions, not just ARM status.
The current feature/provider read Registered, but a recovery PUT produced no
infrastructure and its app failed with zero revisions. The saved recovery plan
therefore replaces only the same-name, proven unused empty app/environment stubs;
four IAM resources are no-ops and persistent key/data/network resources are retained.
The one-off guard exception is confined to the private recovery copy; tracked
module destruction guards remain enabled. Do not blindly repeat PUTs, manually
delete a service association link/subnet/platform group, create an alternate
environment or discard a secret receipt as recovery. See
[service-side recovery](aca-validation-plan.md#service-side-failure-recovery).

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

The workload defaults avoid dedicated profiles, premium ingress, Log Analytics
and automatic data provisioning. The selected private backend requires the
separate retained VNet/endpoint/DNS prerequisites. `log_destination=none` has no
durable centralized container logs; use a separately approved existing Azure
Monitor destination, diagnostic settings, alerts and retention before production.
Measure per-replica memory/CPU, HTTP errors and restarts, protected BFF metrics,
Cosmos RU/throttling/storage, Key Vault access failures and client pending/conflict
rates. Do not log JWTs, authorization headers, grant JSON or document contents.

Zero replicas reduces ACA compute usage, not retained Cosmos storage/throughput,
Key Vault operations or the VNet environment's managed LB/IP and backend
endpoint/DNS fees. The selected network base is approximately **$41.15 per
730-hour month**, before traffic, DNS queries, compute/storage and contract/tax
adjustments; it is an estimate, not an observed bill. See the
[cost breakdown](aca-validation-plan.md#cost-and-retention-choices). Replica caps
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
