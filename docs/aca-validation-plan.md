# Retained private ACA validation topology and deployment runbook

This records the selected minimal West US 2 configuration and its staged
execution, as of 2026-10-04 JST. The Cosmos account/database/container and its
human container role are created. All ten private-network/Key Vault prerequisite
resources applied successfully. The cursor key was initialized once; the public
bootstrap tool subsequently reused the same version's metadata with no PUT.
The dedicated BFF UAMI and exact container/secret permissions are also created.

**The deployed BFF passed actual startup/readiness after the command fix on
2026-10-04; external HTTPS access and the hosted SDK contract remain blocked.**
The reviewed empty-stub replacement apply completed at 02:49:28 UTC, preserving
the four IAM resources. Static IP, exact image/UAMI, versioned Vault reference,
role assignments and Private Endpoint/DNS metadata passed. The pinned image's
default file-config CMD conflicted with the environment JSON; the reviewed ACA
command override was applied at 03:43 UTC. At 03:44:58 UTC the latest-ready
revision was Healthy with one Running container, zero restarts and the BFF
listening; the eleven-check runtime gate passed. This is actual startup evidence,
not authenticated document read/write acceptance. The saved apply restoring
temporary min=1 to selected min=0 passed; actual min=0/max=1 readback at 04:00:01
UTC preserved the exact command/image/runtime/sole Allow `/32`. At 04:41:33 UTC
the final 19/19 ARM checkpoint also observed Healthy/Provisioned/ScaledToZero,
revision replica count zero and an empty actual replica list. This is a point-in-time
observation; later ingress/polling can scale the app again and retained fees remain.

TLS-verified requests from the current Mac IPv4 still return Envoy RBAC 403.
The address matches the sole ingress Allow `/32`; the cause is under diagnosis.
Five external health attempts have been made, with no SDK execution or
application-data writes. The environment's Azure Monitor destination, retained
workspace and HTTP-only diagnostic configuration are created and verified.
The HTTP table exists, but requested `Dedicated` read back as null and four
bounded correlated queries returned zero rows. Log delivery and the edge-denial
cause remain unverified. See
[verification](verification.md) for the latest acceptance record.

The owner authorized necessary minimal Azure resources/settings in the selected
subscription and retained reusable resources. Actual names, IDs, private state,
operator IP and owner identity stay outside this public document. The earlier
failed East US account record is retained and is never selected as the compatible
data target.

The successful West US 2 account is governance-enforced
`publicNetworkAccess=Disabled`. Its retained Mac `/32` ACL is metadata, not a
private route. No public restoration, policy exception or firewall bypass is used.
[Cosmos public-access precedence](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-configure-private-endpoints)

## Selected resource and permission boundary

`PREFIX`, `VAULT`, `DATABASE` and `CONTAINER` are operator-selected placeholders.
Only the successful compatible account and dedicated retained group are used.

| Resource | Selected boundary and current stage |
| --- | --- |
| Cosmos DB for NoSQL | Existing successful single-write serverless account, Session consistency, local authentication disabled; database and `/scopeId` container created, TTL disabled; human data role only at this container |
| VNet | Created in West US 2: `PREFIX-vnet`, `10.227.40.0/24`; no peering, VPN, NAT or service endpoints |
| ACA subnet | Created: `aca`, `10.227.40.0/27`, delegated to `Microsoft.App/environments` |
| Private Endpoint subnet | Created: `private-endpoints`, `10.227.40.32/27`, separate and nondelegated |
| Dedicated Key Vault | Created: `VAULT`, Standard/RBAC, public disabled, default Deny/bypass None, no IP/subnet exceptions, purge protection and 90-day soft deletion; deployment/disk/template retrieval disabled |
| Cosmos Private Endpoint | Created for the exact account, `Sql` subresource, dedicated NIC and private DNS zone group |
| Vault Private Endpoint | Created for this vault, `vault` subresource, dedicated NIC and private DNS zone group |
| Private DNS | Created: `privatelink.documents.azure.com` and `privatelink.vaultcore.azure.net`, linked to this VNet, automatic registration disabled |
| Cursor secret | Initialized once outside Terraform: `cosmos-sync-cursor`, 32 random bytes in standard Base64; actual version URI retained, metadata-only reuse passed |
| BFF UAMI | Created: `PREFIX-bff`; actual startup/readiness passed, authenticated item CRUD remains unverified |
| Cosmos native role/assignment | Created: only `ACCOUNT/dbs/DATABASE/colls/CONTAINER`; metadata read, item read/create/replace, query and readChangeFeed |
| Vault secret assignment | Created: Key Vault Secrets User only at `VAULT/secrets/cosmos-sync-cursor`, assigned to the BFF UAMI |
| ACA environment/app | ARM Succeeded; actual startup passed eleven runtime checks. Final 19/19 checkpoint: min=0/max=1, latest-ready equals latest, Healthy/Provisioned/ScaledToZero, revision and actual replica list both zero. External health still Envoy RBAC 403. Public access Enabled/internal false; .25 vCPU/.5 GiB, operator `/32`, peer encryption |
| Platform infrastructure | Exact managed-group name supplied through `infrastructure_resource_group_name`; current readback finds one public IP and one LB. Static IP metadata passed; the earlier failed environment had zero platform resources |
| HTTP diagnostics | Environment destination `azure-monitor`; retained PerGB2018 workspace, 30-day retention, 0.023 GB/day cap, local auth disabled, authenticated public ingestion/query endpoints; exactly HTTP logs enabled, other categories/AllMetrics disabled. Table exists; delivery and Dedicated/null mismatch unresolved |

The prerequisite module manages ten resources: VNet, two subnets, vault, two
Private Endpoints, two DNS zones and two VNet links. NICs, DNS zone groups/records
and service-side connections accompany them. The workload module manages six:
UAMI, Cosmos native role/assignment, secret reader assignment, environment and
app. It does not create a database/container, provider app, log workspace, NAT,
VPN, private ACA ingress or subscription-wide runtime role.
The later diagnostic setup adds one workspace and one environment diagnostic
setting outside that workload module; its environment destination uses the same
reviewed Terraform state.

```mermaid
flowchart LR
  Native["Flutter native app / Dart SDK"] -->|"browser PKCE; API access JWT"| Workforce["Workforce Entra: validated native login"]
  Native -. "consumer login pending" .-> CIAM["Separate CIAM API/native apps + API-only consent"]
  Native -. "verified TLS; current health RBAC 403" .-> Edge["ACA ARM Succeeded; ingress denial under diagnosis"]
  subgraph VNet["Dedicated retained VNet: 10.227.40.0/24"]
    BFF["BFF startup Healthy; .25 vCPU / .5 GiB; target 0–1 replicas"]
    DNS["Linked private DNS zones"]
    CosmosPE["Sql Private Endpoint: separate PE subnet"]
    VaultPE["vault Private Endpoint: separate PE subnet"]
    BFF -. "UAMI; container role" .-> CosmosPE
    BFF -. "UAMI; versioned secret reference" .-> VaultPE
    DNS --> CosmosPE
    DNS --> VaultPE
  end
  Edge -.-> BFF
  Edge -. "HTTP only; delivery unverified" .-> Logs["Retained authenticated Log Analytics workspace"]
  CosmosPE --> Cosmos["Cosmos NoSQL: public disabled; /scopeId"]
  VaultPE --> Vault["Private RBAC Key Vault: retained cursor version"]
```

Dashed paths have not passed the authenticated external SDK contract; actual BFF
startup/readiness has passed. The native client
needs no direct Cosmos/Vault route or VPN. The BFF validates the JWT signature,
issuer, API audience and delegated scope, then enforces built-in personal/shared
ownership and membership. End users receive neither Cosmos keys nor privileged
cloud tokens. Data writes stop at one logical partition's atomic boundary.
[Cosmos permissions](https://learn.microsoft.com/en-us/azure/cosmos-db/reference-data-plane-security), [Vault secret-reader role](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/security#key-vault-secrets-user)

## Required settings and operator IAM

| Principal or setting | Required boundary |
| --- | --- |
| Deployment operator | Read/write the selected VNet/subnets/PEs/DNS/vault/ACA/UAMI resources; Cosmos `sqlRoleDefinitions`/`sqlRoleAssignments` management only for the selected account; `Microsoft.Authorization/roleAssignments/write` for exact runtime secret assignments; UAMI assign permission |
| Secret initializer | Existing ARM vault read and `Microsoft.KeyVault/vaults/secrets/read`/`write` on this named key; no new vault data-plane writer or executor |
| Runtime UAMI | The six documented Cosmos data actions only at the exact container; Key Vault Secrets User only at the named cursor secret; no Graph permission or Cosmos listKeys |
| Provider registration | Only needed subscription namespaces: Microsoft.App, Network, ManagedIdentity, DocumentDB, KeyVault and Authorization; Terraform auto-registration disabled |
| HTTP diagnostics operator | Selected workspace read/write and query rights, environment diagnostic-settings read/write; needed Insights/OperationalInsights providers. Existing operator identity, no workspace shared key or new runtime IAM |
| Native public client | Registered exact callback `com.anaregdesign.cosmossync://auth/oauthredirect`, browser code + S256 PKCE; no client secret or provider-ID-token substitution |
| BFF identity contract | Exact API issuer/audience/scope and intentional built-in namespace; native client ID is not the API audience; empty native CORS origins are intentional |
| Storage | Existing `/scopeId` container, TTL disabled, one write region, Session-or-stronger consistency, reviewed backup/retention |

The current hosted validation selects the already tested workforce API JWT. A
separate CIAM directory now has its own API/native registrations, corresponding
service principals and API-only `Cosmos.Sync` administrator grant. Its user flow,
Google/Apple providers and actual consumer login remain pending; that configuration
is not silently substituted into the workforce BFF. See
[consumer identity setup](external-id-setup.md) and [native auth](native-auth.md).

Role definition/assignment APIs are control-plane operations; granting the UAMI
data rights does not grant the operator or app subscription-wide Azure rights.
Registration uses the needed provider's `/register/action`, and feature enrollment
uses Microsoft.Features permissions. These are operator setup rights, not runtime
roles. [Provider registration](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-providers-and-types), [Feature enrollment](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/preview-features)

## Traffic and cursor-key bootstrap

The actual retained Azure startup checkpoint still uses the original public
immutable image, with no registry secret or rebuild:

```text
ghcr.io/anaregdesign/cosmos-sync-bff@sha256:a23ab75eb4518597aa26e4833787b9b77a07def717868e080944555594adc1b3
```

Its version is `0.2.0-dev.1`, source `82e937c8659e9ec0263a78e6e3ad2f43e05be20a`.
The workload explicitly sets `command=["/cosmos-sync-bff"]` and omits `args` so
`COSMOS_SYNC_CONFIG_JSON` is the configuration source. This pinned image's default
CMD passes `-config /run/config/config.json`; inheriting that file argument
conflicts with environment-only configuration. Preserve the override in the real
plan and verify actual revision command/args before accepting startup.
[ACA container command/arguments](https://learn.microsoft.com/en-us/azure/container-apps/containers#configuration)

For a new deployment or reviewed upgrade, the current verified public BFF release
is from `76c1f46876b3dfd13f4bd7d4dd144cdf74efa5c0`:

```text
ghcr.io/anaregdesign/cosmos-sync-bff@sha256:2651a4bca6df6f751b7f5e46d317ea9f6e4ca83081374badae142d57cdfc812a
```

All eight [main CI checks](https://github.com/anaregdesign/cosmos-sync/actions/runs/37175675742)
and its [public release verification](https://github.com/anaregdesign/cosmos-sync/actions/runs/37176169762)
passed, including public manifest access, both architectures, MIT/nonroot and
bound SBOM/BuildKit provenance. This publication did not update the retained
cloud image or prove the new image's hosted SDK contract. The SDK archive remains
at its original source and was not republished.

This newer BFF supports optional `oidc.allowed_client_ids`, an exact allowlist of
signed `azp` client IDs in addition to issuer/API-audience/scope checks. Use the
registered native public client ID when selecting that restriction; the native
ID is still not the API audience, and it does not grant shared document membership.
The original checkpoint image does not support this opt-in setting. See
[release](release.md) and [the workload inputs](../infra/terraform/azure-container-apps/README.md).

Select an intentional built-in namespace and the same key/history epoch on every
serving revision. This environment uses no metrics or private-pull secret. Source
updates at `40e5294` passed all eight CI checks in
[PR #37](https://github.com/anaregdesign/cosmos-sync/pull/37), merged at 03:59:51
UTC on 2026-10-04 as `76c1f46876b3dfd13f4bd7d4dd144cdf74efa5c0`.
Merge-commit CI and the new BFF publication passed separately from the original
cloud runtime checkpoint.

Private-only Vault prevents a direct Mac data-plane SetSecret. The reviewed
initializer uses the existing operator's ARM control-plane identity to write
exactly `vaults/VAULT/secrets/cosmos-sync-cursor`, API `2024-11-01`. The key stays
in RAM; there is no Terraform secret resource, deployment secure-parameter
history, CLI secret argument/environment variable, new writer role or new runner.
Only the real versioned URI and digests are recorded privately. The published
[bootstrap tool](../tools/bootstrap_cursor_key.py) preserves this boundary.
[Vault ARM network boundary](https://learn.microsoft.com/en-us/azure/key-vault/general/network-security#restrictions-and-limitations), [ARM secret schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.keyvault/2024-11-01/vaults/secrets)

`--reuse-existing` performs only vault/secret metadata GETs and records the existing
version URI; it never retrieves a secret value or rotates. Actual reuse returned
the initialized version with no PUT. Metadata cannot prove key format, runtime
permissions or reachability: verify those through the BFF. ARM PUT is
create-or-update, so new initialization requires one designated external writer.
A fixed per-vault ledger/lock and durable prewrite record block local duplicate
attempts; ambiguous outcomes stop for operator inspection. Do not remove a
receipt, switch clones or generate another key to resolve an unknown outcome.

## Portable deployment and acceptance sequence

Use a POSIX host with Bash, Python 3.10+ (`fcntl` is required), curl, the pinned
Terraform/TFLint tools and an existing private Azure CLI profile. Keep deployment
source, tfvars, plans, state, credentials and receipts out of Git/public CI:

```sh
umask 077
COSMOS_DEPLOY_PRIVATE_DIR="$PWD/.cache/azure-deploy"
mkdir -p "$COSMOS_DEPLOY_PRIVATE_DIR"
chmod 700 "$PWD/.cache" "$COSMOS_DEPLOY_PRIVATE_DIR"
bash infra/terraform/aca-validation-plan/verify.sh
bash infra/terraform/azure-container-apps/verify.sh
python3 -m unittest discover -s tools -p 'test_bootstrap_cursor_key.py' -v
```

1. Select the compatible Cosmos account and owner-approved target/resources. Check
   account/container metadata, policy, backup, exact IAM, provider/feature status,
   resource names and published digest. Do not select the retained failed account.
2. Copy the prerequisite module into the private deployment directory; use private
   0600 tfvars with its six explicit target/name inputs. Initialize locked providers,
   save/review the real plan and apply only that saved plan. Preserve its state.
   Read back both private endpoints, DNS links/records and Vault private/RBAC/tags.
   This step is complete for the current validation resources.
3. After the reviewed prerequisite apply, make a separate immutable 0600 copy of
   its **raw** `terraform.tfstate` in a 0700 directory. Do not pass a saved plan,
   `terraform show` JSON or a live-changing state. Copy
   [cursor-bootstrap.example.json](../ops/azure/cursor-bootstrap.example.json)
   to a private 0600 file, replace placeholders with the exact vault/tenant/location,
   and bind `terraformState.sha256` to those exact copied bytes. Keep
   `resourceAddress=azurerm_key_vault.cursor` and the documented provenance value.
   The operator establishes the approved-apply provenance; the tool proves the
   bytes/target/security envelope match it.
4. Run the local bootstrap plan, then choose existing metadata reuse or the one
   explicitly authorized initialization below. Never pass a key/token through argv.
   The existing CLI profile remains selected explicitly; the tool neither logs in
   nor changes the CLI default context. CLI retains its normal private auth cache.
5. Copy the workload module and fill its private tfvars from reviewed prerequisite
   outputs: exact delegated subnet, vault ID/URL and **actual versioned** cursor URI;
   compatible account/DB/container, UAMI choice, API issuer/audience/scope, pinned
   digest, new namespace assertion, operator `/32`, replicas 0–1 and explicit new
   platform-managed group name. Preserve the explicit BFF command/no-args override
   for environment JSON. Review a real saved workload plan, then apply it.
6. After the app/revision is ready, record HTTPS endpoint and actual image/identity
   metadata. Run health/readiness, unauthorized/no-token/invalid JWT denial and
   the approved SDK smoke. Observe private DNS, Vault secret resolution and UAMI
   Cosmos access; resource mocks cannot establish them.
7. Pin any upgrade to a verified new digest; preserve compatible protocol/key/epoch/
   policy, save/review the change and validate the replacement revision before
   rollout. Coordinate rotation separately; never mix cursor keys or roll back
   revocation to recover an image. Retain the prior compatible configuration.

For a **fresh** private operator workspace, copy the modules once. Never overwrite
an existing deployment directory/state to retry or upgrade:

```sh
cp -R infra/terraform/aca-validation-plan/prerequisites "$COSMOS_DEPLOY_PRIVATE_DIR/prerequisites"
cp -R infra/terraform/azure-container-apps "$COSMOS_DEPLOY_PRIVATE_DIR/workload"
# Create and review 0600 prerequisite.tfvars.json and workload.tfvars here.
# Export only the existing private CLI profile path, never credentials:
export AZURE_CONFIG_DIR=/private/existing-azure-profile
export AZURE_LOGGING_ENABLE_LOG_FILE=no
terraform -chdir="$COSMOS_DEPLOY_PRIVATE_DIR/prerequisites" init -backend=false -input=false -lockfile=readonly
terraform -chdir="$COSMOS_DEPLOY_PRIVATE_DIR/prerequisites" plan \
  -var-file="$COSMOS_DEPLOY_PRIVATE_DIR/prerequisite.tfvars.json" \
  -out="$COSMOS_DEPLOY_PRIVATE_DIR/prerequisite.tfplan"
# Only after reviewing this exact plan within existing owner authority:
terraform -chdir="$COSMOS_DEPLOY_PRIVATE_DIR/prerequisites" apply "$COSMOS_DEPLOY_PRIVATE_DIR/prerequisite.tfplan"
cp "$COSMOS_DEPLOY_PRIVATE_DIR/prerequisites/terraform.tfstate" "$COSMOS_DEPLOY_PRIVATE_DIR/prerequisite-state.json"
chmod 600 "$COSMOS_DEPLOY_PRIVATE_DIR/prerequisite-state.json"
python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' \
  "$COSMOS_DEPLOY_PRIVATE_DIR/prerequisite-state.json"
```

Record that nonsecret hash in the private bootstrap config, alongside the exact
reviewed vault/tenant/location. The immutable copy remains separate from the
state Terraform will refresh. Keep both files and the approved plan private.
Bootstrap examples below use nonsecret private paths; replace them with your
reviewed files:

```sh
python3 tools/bootstrap_cursor_key.py --plan \
  --config /private/deploy/cursor-config.json --state /private/deploy/prerequisite-state.json
python3 tools/bootstrap_cursor_key.py --reuse-existing \
  --config /private/deploy/cursor-config.json --state /private/deploy/prerequisite-state.json \
  --azure-config-dir /private/existing-azure-profile
# New key only when confirmed absent, already authorized and no other writer:
python3 tools/bootstrap_cursor_key.py --execute --sole-writer \
  --approval-reference owner-approved-exact-bootstrap \
  --config /private/deploy/cursor-config.json --state /private/deploy/prerequisite-state.json \
  --azure-config-dir /private/existing-azure-profile
```

After bootstrap/reuse, read its private metadata receipt and fill
`key_vault.cursor_secret_uri` with the **same actual version**. The receipt holds
no key/token value. Complete and review workload inputs before these commands:

```sh
terraform -chdir="$COSMOS_DEPLOY_PRIVATE_DIR/workload" init -backend=false -input=false -lockfile=readonly
terraform -chdir="$COSMOS_DEPLOY_PRIVATE_DIR/workload" plan \
  -var-file="$COSMOS_DEPLOY_PRIVATE_DIR/workload.tfvars" \
  -out="$COSMOS_DEPLOY_PRIVATE_DIR/workload.tfplan"
# Only the reviewed saved plan, never an automatically recomputed apply:
terraform -chdir="$COSMOS_DEPLOY_PRIVATE_DIR/workload" apply "$COSMOS_DEPLOY_PRIVATE_DIR/workload.tfplan"
terraform -chdir="$COSMOS_DEPLOY_PRIVATE_DIR/workload" output endpoint
```

Record real `/healthz` and `/readyz` responses through the authorized HTTPS ingress
and denial for unauthenticated application routes. Then run the approved hosted
SDK gate with its reviewed private manifest and existing native credential session.
A populated Terraform endpoint output alone is not proof of those responses.

The cursor-bootstrap tool defaults offline; `--plan` makes no CLI/network/key/write calls. Private
inputs must be regular current-owner files at 0600 inside 0700 directories. FIFO,
symlink, duplicate JSON fields, target/state drift and unverified secret URIs are
rejected. TLS always validates its trust chain and never follows redirects.
Receipts stay under the checkout's `.cache/cursor-bootstrap/` at 0600; preserve
them with the reviewed state. State/plan encryption and locking in a selected
remote backend remain a separately reviewed operational setup.

For the hosted SDK gate use the bounded
[verifier](../tools/hosted_azure_live.py) and
[example manifest](../ops/azure/hosted-validation.example.json). Copy it to a
private 0600 file in a 0700 directory. Replace the deliberately invalid endpoint
with the verified Terraform HTTPS output, supply the exact private owner/registration
receipt and fresh API-JWT file paths, and reference actual target/write approvals.
Never put token contents in the manifest. The default invocation validates offline:

```sh
python3 tools/hosted_azure_live.py --manifest /absolute/private/hosted-validation.json
# After actual runtime and four HTTPS probe checks:
python3 tools/hosted_azure_live.py --manifest /absolute/private/hosted-validation.json \
  --dart-bin /absolute/path/to/dart --execute-approved
```

The selected single-account run allows at most 40 BFF requests, three accepted
application mutations and 120 seconds. Its example reserves four health/readiness/
denial probes and uses a 90-second/36-call SDK phase, leaving 20 seconds for probes
and ten for setup.
The current retained attempt already spent five probe attempts. Before resuming,
recalculate the manifest against that preserved ledger: 35 calls remain, so
reserving four new health/readiness/denial checks leaves at most 31 SDK calls.
The earlier offline-only 70-second/33-call candidate must be updated; do not
reset the request allowance by restarting a harness. The native JWT has expired
and must be refreshed through the approved owner-assisted flow. Separated
infrastructure/diagnostic phases are not one 120-second wall-clock execution.
Account/policy metadata and SDK internal retries/RU are distinct from those
application-mutation/request bounds. No hosted app/data run has occurred yet.
Separate-user membership, two serving replicas, restart/failover and social-provider
acceptance remain separate gates; they are not implied by this small run.

## Service-side failure recovery

The first environment request rejected the literal log destination `"none"`.
The template now renders JSON `null` for disabled logs, matching the inspected
Azure CLI 2.88.0 behavior; no Log Analytics workspace is created. A subsequent
creation retained an environment in Failed state because this subscription lacked
`Microsoft.Network/AllowBringYourOwnPublicIpAddress`. That exact feature and the
Network provider now read Registered. Import/reconciliation of the same owned
environment then returned ARM `Succeeded`, but its static IP was absent and its
owned platform group contained zero resources. The app ended in
`ContainerAppOperationError` after approximately 21 minutes with zero revisions.
Activity Logs contain only the original six IP-creation attempts rejected for
the missing feature; no later LB/IP retry appeared during that reconciliation.
ARM `Succeeded` alone therefore did not establish a usable environment.

The completed recovery applied a separately saved and reviewed plan replacing only
the **same-name, proven empty and unused** app/environment stubs. Three independent
reviews checked the two replacements and four IAM no-ops. A one-off private copy
permits only these two guarded replacements; the tracked module's destruction
guards remain enabled. Both empty stubs were replaced, and the exact saved apply
completed successfully at 02:49:28 UTC on 2026-10-04. Cosmos/database/container, Vault, key/version, Private Endpoints, DNS,
VNet/subnets, UAMI and all four IAM resources are retained. No alternate
environment, policy exception or BFF application-data write is introduced.

Post-recovery metadata checks find the expected static IP, one public IP and one
LB in the exact owned platform group, plus the exact image/UAMI/versioned Vault
reference and scoped roles. Initial activation then remained unready. The
actual startup fault was the image's file-config CMD conflicting with
`COSMOS_SYNC_CONFIG_JSON`. The reviewed change explicitly set ACA
`command=["/cosmos-sync-bff"]`, omitted `args`, and applied at 03:43 UTC without
changing the image or persistent data/key/network/IAM resources. At 03:44:58 UTC
the latest-ready revision was Healthy with one Running container, restart count
zero and the BFF listening. All eleven runtime-gate checks passed. The saved apply
restoring temporary min=1 to selected min=0 passed. Actual readback at 04:00:01
UTC confirmed min=0/max=1 with the exact command/image/runtime/sole `/32` preserved,
latest-ready equal to latest and Healthy/Provisioned. One replica was still
present during cooldown at that checkpoint. The later 04:41:33 UTC check passed
19/19: app/environment Succeeded, latest-ready equal to latest,
Healthy/Provisioned/ScaledToZero, revision replicas zero and actual replica list
empty. Command/image/runtime/min=0/max=1/sole `/32` remained unchanged.

External endpoint/data acceptance is separate: five Mac health attempts include one Python CA failure and four macOS-TLS-verified Envoy RBAC 403 responses, with no SDK/data writes. Environment
readback shows `publicNetworkAccess=Enabled` and `internal=false`, ruling out the
disabled-public-environment hypothesis. Diagnose the ingress evidence without
assuming the cause or widening the allowed `/32`. Two independent IP services matched the actual
Mac address to that sole Allow rule. The first Python probe could not establish
TLS because its local default CA file/directory were absent; use a correctly
trusted TLS client rather than disabling verification or attributing this client
trust failure to the service.

The separate diagnostic setup completed: an environment-only saved update to
`azure-monitor` succeeded in 2 minutes 8 seconds, with five workload no-ops.
The app's min=0/max=1, command/image and sole `/32` were retained. The new retained
workspace reads Succeeded/PerGB2018, retention 30 days, cap 0.023 GB/day, local
auth disabled and ingestion/query public access Enabled for authenticated normal
operator access. Exactly `ContainerAppHTTPLogs` is enabled; six other categories
and AllMetrics are disabled, with no extra exports. Independent configuration
review passed 17/17 checks. No app/network/runtime-IAM change was introduced.

The request selected `logAnalyticsDestinationType="Dedicated"`, but actual ARM
readback returns null. This difference is **unresolved**, not a benign
normalization or evidence that Dedicated was honored. ARM lists
`ContainerAppHTTPLogs` as Analytics/Succeeded with the required columns;
`AzureDiagnostics` was absent from the table catalog. Schema creation does not
prove request-log delivery. Three bounded exact-app/environment/correlation
queries completed in 74.793 seconds with HTTP 200 and zero rows. One additional
seven-second query retained exact request correlation/authority/GET/path/user-agent
and allowed blank or exact routing fields; it also returned 200/zero rows.
The total is four queries. The latest verified-TLS health probe at 04:23:52 UTC
still returned Envoy RBAC 403. The fresh Mac address matched the sole `/32` through
two independent services. No further probe/query or SDK/data run is represented
as performed. See [HTTP diagnostics reuse](#reuse-the-http-diagnostic-configuration).

For another subscription, inspect the needed providers and the exact service
error. If that feature is required, enroll only it within the operator's authority,
wait for registration and re-register the Network provider to propagate it. Read
back static IP, platform-managed LB/IP resources and app revisions as well as ARM
status before proceeding. First reconcile/import only the exact owned resource
into its existing private state. Do not blindly repeat PUTs. An empty-stub
replacement requires verified ownership, no running revisions/data, a separately
reviewed saved plan limited to those resources and existing operator authority;
it is not a general destruction exception. Never manually delete the service
association link, delegated subnet, network or platform group. Never delete the
validation group or repeat key initialization to repair environment provisioning.
[Feature registration propagation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/preview-features)

## Reuse the HTTP diagnostic configuration

Use the existing retained workspace/diagnostic setting after checking its exact
ownership, target and configuration; do not create another pair to retry a
zero-row query. A future deployment uses its own reviewed target and existing
authorized operator profile. Keep filled request/response files private at 0600
in a 0700 directory; use `umask 077` and `AZURE_LOGGING_ENABLE_LOG_FILE=no`.
No workspace shared key or secret value is required.

First set `log_destination="azure-monitor"` in the private workload tfvars. Save
and review the Terraform plan against the successful deployment state. For an
otherwise unchanged six-resource deployment it must contain one environment
update and five no-ops; apply that exact saved plan and read back the destination,
app command/image/min=0/max=1/sole `/32` and runtime identities. Do not issue an
out-of-band environment update that leaves Terraform state/configuration stale.
[ACA destination requirement](https://learn.microsoft.com/en-us/azure/container-apps/log-options)

For a new, checked-absent workspace, a private `workspace.json` body can use:

```json
{
  "location": "westus2",
  "tags": {"project": "cosmos-sync", "purpose": "validation", "deployment": "<OWNER_MARKER>"},
  "properties": {
    "sku": {"name": "PerGB2018"},
    "retentionInDays": 30,
    "workspaceCapping": {"dailyQuotaGb": 0.023},
    "features": {"disableLocalAuth": true},
    "publicNetworkAccessForIngestion": "Enabled",
    "publicNetworkAccessForQuery": "Enabled"
  }
}
```

Public ingestion/query endpoints still require authentication; this adds no
private workspace network or runtime data role. Existing workspace names must
match the reviewed ownership/receipt; unknown/foreign resources and an ambiguous
GET result are not authorization to PUT. Read back actual SKU, retention, cap,
local-auth/network flags and Succeeded state after creation.
[Workspace schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.operationalinsights/2025-07-01/workspaces)

Discover the exact environment's diagnostic categories before choosing them.
The current environment exposes these seven; the private `http-diagnostic.json`
selects only HTTP, no console/system/session logs, metrics or other exports:

```json
{
  "properties": {
    "workspaceId": "<EXACT_WORKSPACE_ARM_ID>",
    "logAnalyticsDestinationType": "Dedicated",
    "logs": [
      {"category": "ContainerAppHTTPLogs", "enabled": true},
      {"category": "ContainerAppConsoleLogs", "enabled": false},
      {"category": "ContainerAppSystemLogs", "enabled": false},
      {"category": "AppEnvSpringAppConsoleLogs", "enabled": false},
      {"category": "AppEnvSessionConsoleLogs", "enabled": false},
      {"category": "AppEnvSessionPoolEventLogs", "enabled": false},
      {"category": "AppEnvSessionLifeCycleLogs", "enabled": false}
    ],
    "metrics": [{"category": "AllMetrics", "enabled": false}]
  }
}
```

After filling nonsecret targets privately, use the existing CLI session without
changing its default context. The following is a future operator example, not
an instruction to replay the retained deployment:

```sh
COSMOS_LOG_SUBSCRIPTION='<SELECTED_SUBSCRIPTION_ID>'
COSMOS_LOG_WORKSPACE_ID='/subscriptions/<ID>/resourceGroups/<GROUP>/providers/Microsoft.OperationalInsights/workspaces/<WORKSPACE>'
COSMOS_LOG_ENVIRONMENT_ID='/subscriptions/<ID>/resourceGroups/<GROUP>/providers/Microsoft.App/managedEnvironments/<ENVIRONMENT>'
COSMOS_LOG_DIAGNOSTIC_ID="$COSMOS_LOG_ENVIRONMENT_ID/providers/Microsoft.Insights/diagnosticSettings/<SETTING>"
export AZURE_LOGGING_ENABLE_LOG_FILE=no
# First GET the exact workspace/setting; reuse only verified owned matches.
# PUT creation only after a definite not-found result and review of both bodies.
az rest --subscription "$COSMOS_LOG_SUBSCRIPTION" --method put \
  --url "https://management.azure.com$COSMOS_LOG_WORKSPACE_ID?api-version=2025-07-01" \
  --body @/private/deploy/workspace.json --only-show-errors --output none
az rest --subscription "$COSMOS_LOG_SUBSCRIPTION" --method get \
  --url "https://management.azure.com$COSMOS_LOG_ENVIRONMENT_ID/providers/Microsoft.Insights/diagnosticSettingsCategories?api-version=2021-05-01-preview" \
  --only-show-errors > /private/deploy/categories.json
# Only the reviewed, discovered categories and checked-absent owned setting:
az rest --subscription "$COSMOS_LOG_SUBSCRIPTION" --method put \
  --url "https://management.azure.com$COSMOS_LOG_DIAGNOSTIC_ID?api-version=2021-05-01-preview" \
  --body @/private/deploy/http-diagnostic.json --only-show-errors --output none
az rest --subscription "$COSMOS_LOG_SUBSCRIPTION" --method get \
  --url "https://management.azure.com$COSMOS_LOG_DIAGNOSTIC_ID?api-version=2021-05-01-preview" \
  --only-show-errors > /private/deploy/diagnostic-readback.json
```

Compare requested and actual workspace ID, category enablement, metrics/exports
and destination type; preserve the request and metadata-only receipt. Current
`Dedicated` → null is unresolved even though the HTTP table/schema exists.
Do not repeat a PUT to hide this difference or claim the requested table mode was
honored. List actual workspace tables/columns before selecting a bounded query.
[Diagnostic schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/diagnosticsettings)

For a separately planned synthetic no-token health request, retain its UTC time,
nonsecret `x-request-id`, exact authority/path/user-agent and response status.
Never put a token/API key in its URL. A narrowly bounded follow-up query can use
the actual HTTP table and schema, for example:

```kusto
ContainerAppHTTPLogs
| where TimeGenerated between (datetime(<UTC_START>) .. datetime(<UTC_END>))
| where RequestId == "<REQUEST_ID>" and Authority == "<EXACT_HOST>"
| where Method == "GET" and Path == "/healthz" and UserAgent == "<EXACT_PROBE_UA>"
| where _ResourceId =~ "<EXACT_ENVIRONMENT_ARM_ID>"
| where ContainerAppName == "<EXACT_APP>" and EnvironmentName == "<EXACT_ENVIRONMENT>"
| project TimeGenerated, StatusCode, ResponseCodeDetails, ResponseFlags
| take 5
```

Allow blank routing fields only as an explicitly recorded alternative while
keeping exact request correlation/authority/method/path/user-agent and the time
window. Bound query count and duration; the current run stopped after four
HTTP-200/zero-row queries and five total health attempts. API 200, table schema
and an empty result do not prove ingestion or resolve the 403 cause. Preserve
redacted evidence rather than scan other apps or expand logging categories.
HTTP metadata can include paths and client IPs; keep raw rows private and publish
only safe status/counts. [HTTP schema/privacy](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/containerapphttplogs)

## Cost and retention choices


These are USD ordinary PAYG estimates from current official Retail Prices API
meters, checked 2026-10-04 JST, before tax/exchange/employee-contract adjustments.
Shared subscription free grants and any infrastructure fee exemptions are not
assumed available.

| Network fixed component | Hourly/monthly estimate |
| --- | --- |
| Planning envelope: up to two Standard static IPv4 plus Standard LB | $0.035/hour; about $25.55/730 hours |
| Two backend Private Endpoints | $0.02/hour combined; about $14.60/730 hours |
| Two Private DNS zones | About $1.00/month combined, plus queries |
| **Two-IP planning network base** | **About $41.15/730-hour month**, before data/queries/extra platform rules |

Actual platform inventory currently contains **one public IP and one LB**. The
$41.15 figure retains the original up-to-two-IP planning envelope; it is not an
observed invoice or a claim that two public IPs were created. Confirm actual
billable meters, durations, platform rules and contract adjustments separately.
The later HTTP diagnostic workspace is additional to this network-only envelope:
PerGB2018 ingestion and any separately chargeable retention/query/export activity
must use actual regional/contract meters. The 0.023-GB/day cap corresponds to a
nominal 0.69 GB in 30 days, not a guaranteed billing ceiling. Caps may overshoot
and excess ingestion remains billable. No free grant or working delivery is
assumed. [Log Analytics cap limits](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/daily-cap)

LB processing is $0.005/GB; endpoint processing starts at $0.01/GB; actual
platform rule counts must be checked for additional LB rules. Private Endpoint
partial hours are charged as full hours; DNS zones are calculated by days, so a
120-second smoke test still has initial network charges. These fixed components
remain when replicas are zero. Dedicated profiles, ACA-environment private
ingress endpoints and planned maintenance are omitted; their extra management
fees are outside this estimate and are not silently enabled. [ACA managed resources](https://learn.microsoft.com/en-us/azure/container-apps/custom-virtual-networks#managed-resources), [Private Link prices](https://azure.microsoft.com/en-us/pricing/details/private-link/), [DNS prices](https://azure.microsoft.com/en-us/pricing/details/dns/), [Official pricing API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)

West US 2 ACA active prices are $0.000034/vCPU-second and
$0.000004/GiB-second, plus $0.40/million requests beyond its shared monthly grant.
One 0.25-vCPU/0.5-GiB replica continuously active costs about $0.0378/hour before
grants; 120 seconds plus the reference's 300-second cooldown is about $0.00441 in
active CPU/memory alone. Cold start/setup, other requests, network persistence,
Cosmos RU/storage/backup/egress and Key Vault operations are additional. Cosmos
serverless is $0.25/million RU; Key Vault Standard is $0.03/10,000 operations.
Replicas and BFF request limits are not billing caps. [ACA prices](https://azure.microsoft.com/en-us/pricing/details/container-apps/), [Key Vault prices](https://azure.microsoft.com/en-us/pricing/details/key-vault/), [Cosmos prices](https://azure.microsoft.com/en-us/pricing/details/cosmos-db/)

Retain-for-reuse is the current default: the reusable resources stay. A temporary
hosted verification followed by explicit retirement of only the new ACA app,
environment and managed LB/IP removes that component but leaves approximately
$15.60/month for retained endpoint/DNS connectivity. Scaling/stopping the app
does not remove the managed LB/IP fixed charges (up to $25.55 in this planning
envelope). Such retirement needs a separate
review and owner authorization; it never authorizes removing Cosmos, Entra,
cursor key, data or the validation group. No teardown permission is inferred.
The diagnostic workspace/setting is retained for the same validation environment;
reuse the exact owned destination rather than creating a workspace per retry.

Ordinary service endpoints would be cheaper in a subscription permitting selected
public-network access, but cannot pass the governance-enforced disabled setting
here. NAT would add recurring cost and would not overcome that policy. Mac VPN,
peering, an existing private operator path and private ACA ingress are outside
this selected configuration. The initial hosted smoke avoids new Mac private networking.

## Execution status and evidence

The prerequisite apply and cursor initialization/reuse are actual Azure results;
the runtime identity/role resources and empty-stub replacement workload apply
completed successfully. Static IP, image/UAMI/versioned Vault reference and
role/PE/DNS metadata passed. The command fix produced actual latest-ready Healthy,
one Running container, zero restarts/listening and an eleven-check runtime-gate
PASS. External Envoy RBAC 403 still blocks the hosted SDK; five health attempts
and no SDK/application-data writes are recorded. Min=0/max=1 restoration and actual
configuration readback passed. At 04:41:33 UTC the final 19/19 ARM checkpoint
observed Healthy/Provisioned/ScaledToZero and zero revision/actual replicas.
The Azure Monitor destination, workspace and HTTP-only diagnostic configuration
are actual confirmed changes. The HTTP table/schema exists, while Dedicated/null
readback and log delivery remain unresolved after four successful zero-row
queries. Configuration/table success does not close external access or SDK gates.
The earlier validated local suite passed 22
workload-module mock plans, seven prerequisite mock plans, both pinned validators
and 127 Python tool tests (84 existing, 13 hosted-gate, 30 bootstrap tests). These
checks establish source/guard behavior, not hosted health or data access.
The latest public module normalization passed 31 mock plans, format, validation
and TFLint; it canonicalizes service-returned probe fields/HTTP/Ignore values to
avoid repeated equivalent PUTs. That source proof is separate from log delivery.

Fresh workforce Mac AppAuth callback, Keychain restore and refresh stages were
observed; the wrapper's exit 1 is retained separately in verification.
Both fresh API JWTs passed signature, issuer, audience, delegated scope, tenant
and approved-owner validation. That session expired at 03:56:23 UTC; the retained
proof is historical, and a later hosted SDK run needs a coordinated fresh session.
This is distinct from the new CIAM registrations and from hosted
Cosmos/ACA acceptance. Preserve that separation in Issues and
[verification](verification.md). Credentials never need to be pasted into chat.
