# Azure access, live verification and operations

The independent implementation is ready for live verification. The owner selected an isolated subscription, approved a cheapest-first validation environment and asked to retain it for reuse. Guarded setup created its tagged resource group and registered the required `Microsoft.DocumentDB` provider. The selected offer rejected free tier, and East US serverless creation failed due to regional capacity. A later direct ARM readback on 2026-10-03 found the intended account in `Failed` state with no data endpoint, although the account-list command returned zero. No usable Cosmos account, database, container, data role or application data is available. Retain the failed account record and group; an alternative region and target require an updated explicit owner approval. The original empty-group retarget guard must reject this nonempty group rather than bypass its safety check or delete the failed record. Dedicated Entra registrations are tracked separately in [the identity setup](entra-setup.md). The initial isolated Azure CLI 2.88.0 inventory showed one enabled subscription and no existing Cosmos accounts; that earlier inventory does not prove the current group is empty. Neither a default subscription nor any existing application is authorized merely because it is visible. Owner-specific identifiers and credentials stay in ignored private files.

Preparation is tracked in [#19](https://github.com/anaregdesign/cosmos-sync/issues/19); the actual environment and operational evidence remain in [#16](https://github.com/anaregdesign/cosmos-sync/issues/16). The app → OIDC → BFF → Azure → device release chain is [#24](https://github.com/anaregdesign/cosmos-sync/issues/24). The tools below do not claim those live gates have passed.

## The concrete owner request

Provide the following nonsecret selections, and place credentials in a private local file or the chosen secret manager rather than in chat, GitHub Issues or Git:

| Selection | Minimum needed |
| --- | --- |
| Isolated Azure target | Tenant ID, subscription ID, resource group, existing NoSQL account endpoint/name, database and container. If none exists, approve an isolated account/container, location and billing mode. The current owner decision retains this dedicated validation environment for future reuse. |
| Test authorization and budget | Explicit permission for the selected container's test scope, three expected accepted mutations (create/update/tombstone), retained journal and receipts, maximum duration, currency and who monitors/reuses the environment. Record a positive spending ceiling, or `ceilingAmount: null` plus `unboundedCostApproved: true` only when the owner explicitly approves no upper limit. Runtime/request bounds do not enforce monetary billing. |
| Azure data identity | An existing approved developer identity for the local gate, with the narrow container role below. Later select the hosting managed identity separately. No account key, broad subscription Contributor role or new client secret is needed by the local gate. |
| End-user identity | Trusted HTTPS OIDC issuer, exact API audience, delegated access scope, tenant claim and optional `token_use`; a fresh API access JWT in a current-user-owned `0600` file for the owner's selected single account. ID tokens are unsuitable. Distinct-account JWTs are needed only if the owner later chooses full three-principal evidence. |
| Current grants | Exact authorized JWT tenant-claim and signature-verified API `sub` for the selected account. The local harness creates only its own temporary grant file and changes that one principal from writer to reader to inactive. The original three-principal mode remains available without requesting more accounts for the current gate. |
| Hosting decision | Existing TLS-capable host or a separately budgeted host, region/network path, public or private ingress, DNS/certificate ownership, approved image digest/private pull mechanism, shared signing-key manager, metrics access and grants/revocation owner. A new AKS cluster is not a prerequisite. |
| Recovery expectations | Accepted recovery point/time objectives, backup tier, distinct restore target and cost allowance, region/failover topology and a separate deliberate fault/load-test window. |

The [manifest example](../ops/azure/environment.example.json) records selections and references to the owner's actual approvals. Copy it into an ignored private directory, replace every placeholder and retain only approval references; do not invent approval merely to make a script run. Token contents never belong in the manifest. The files contain subject identifiers and private paths, so keep completed manifests out of Git even though the examples are safe to commit.

The BFF trusts one exact issuer. In the optional three-principal mode, use a third distinct ungranted principal in the same selected Entra tenant for `outsider`: its signature-verified API access JWT must receive **403**, demonstrating current-grant denial. A single-tenant Entra API does not need an outside tenant to exercise that check. An explicitly selected foreign-tenant/issuer negative fixture is also permitted, but its 401/403 result demonstrates rejection without claiming the same current-grant evidence. A Microsoft Entra tenant-specific issuer cannot silently accept another tenant's issuer.

## Cheapest retained verification environment

The owner has approved a cheapest-first Azure verification environment and one user account. Before provisioning, select the subscription, permitted region, data-role principal and current public egress IP. Keep the BFF on the local Mac so this gate adds no cloud-hosting charge. Create only the retained validation resource group, one NoSQL account, one database and one `/scopeId` container; use Session consistency, a single write/read region, no zone redundancy, no default TTL, Entra-only data authentication and an egress-IP firewall rule. Network policy can require a costlier approved private route instead; the preparation does not weaken that policy.

If the selected subscription offer has its unused Cosmos free-tier entitlement, choose a free-tier provisioned account and one shared database at 400 RU/s. The account's first 1,000 RU/s and 25 GB are covered, but free tier is limited to one account per subscription and must be chosen at account creation. The observed lack of existing accounts is useful evidence, not a guarantee of billing eligibility. [Free-tier conditions](https://learn.microsoft.com/en-us/azure/cosmos-db/free-tier).

Otherwise choose serverless for the tiny, short contract. It bills consumed RUs without an idle throughput minimum; do not set throughput on its database or container. Serverless is limited to one region and lacks predictable throughput/latency guarantees. Avoid optional zone redundancy, which multiplies serverless RU charges by 1.25. This is a cost inference for the bounded test, not a guaranteed monetary quote. The exact rate still depends on region, currency and subscription offer; use the selected offer's pricing calculator and record the actual billable usage. [Serverless constraints](https://learn.microsoft.com/en-us/azure/cosmos-db/serverless), [official serverless pricing](https://azure.microsoft.com/en-us/pricing/details/cosmos-db/serverless/).

On 2026-10-03 the public Microsoft retail API reported East US serverless at **USD 0.25 per million RU**, among the lowest observed regional list rates, and Japan East at USD 0.285. East US NoSQL data-storage meters were USD 0.25/GB-month. For illustration, 10,000 consumed RU would cost USD 0.0025 in RU charges at the East US rate, plus time-weighted storage, any chargeable egress/tax and offer adjustments. This does not predict this harness's actual RU usage: startup metadata, polling and SDK retries add requests. Select the permitted region and offer before committing to a quote; refresh the rate at provisioning. [East US serverless retail query](https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&%24filter=productName%20eq%20%27Azure%20Cosmos%20DB%20serverless%27%20and%20meterName%20eq%20%271M%20RUs%27%20and%20armRegionName%20eq%20%27eastus%27), [retail API scope and currencies](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices).

Use continuous seven-day backup, whose backup storage has no additional charge; every restore is charged and belongs to a separate gate. Retained data and indexes, chargeable egress and later resources can still cost money. Omit `defaultTtl`/`--ttl` to disable TTL; `-1` enables TTL without a default expiration and still permits item expiry. [Backup billing](https://learn.microsoft.com/en-us/azure/cosmos-db/continuous-backup-restore-introduction), [TTL semantics](https://learn.microsoft.com/en-us/azure/cosmos-db/time-to-live).

Paid manual throughput has a 400-RU/s baseline. The current smallest autoscale maximum is 1,000 RU/s, with an hourly floor of 100 RU/s at the single-write autoscale rate of 1.5 times manual. Consequently manual 400 is not always the cheapest paid provisioned option; hourly peaks and sustained workload determine the comparison. For this three-mutation gate, prefer free tier if eligible, then consumption-based serverless. [Autoscale limits and billing](https://learn.microsoft.com/en-us/azure/cosmos-db/autoscale-faq).

The following are reviewable **owner-approved provisioning commands**; the guarded setup tool below performs the equivalent actions after checking the selected target and ownership. They require explicit subscription/region/egress-IP and resource-name selections. Use a new validation group; never reuse a production group. Choose exactly one account/database variant:

Bootstrap requires permission to create the selected resource group at subscription scope, and account/database/container creation plus native Cosmos role-definition/assignment writes only inside that temporary group/account. If `Microsoft.DocumentDB` is not registered, its provider-registration action is a separate subscription operation for the owner. The verification data identity still needs only account/container metadata reads and the bounded native container role; it never needs subscription Owner or resource-creation permission. An existing approved operator can perform bootstrap and then remove temporary setup access.

```sh
az group create --subscription "$COSMOS_TEST_SUBSCRIPTION_ID" \
  --name "$COSMOS_TEST_RESOURCE_GROUP" --location "$COSMOS_TEST_REGION" --output none

# Serverless fallback: do not supply any throughput argument later.
az cosmosdb create --subscription "$COSMOS_TEST_SUBSCRIPTION_ID" \
  --resource-group "$COSMOS_TEST_RESOURCE_GROUP" --name "$COSMOS_TEST_ACCOUNT" \
  --kind GlobalDocumentDB --capabilities EnableServerless \
  --locations "regionName=$COSMOS_TEST_REGION" failoverPriority=0 isZoneRedundant=false \
  --default-consistency-level Session --enable-multiple-write-locations false \
  --enable-automatic-failover false --disable-local-auth true \
  --minimal-tls-version Tls12 --network-acl-bypass None \
  --public-network-access Enabled --ip-range-filter "$COSMOS_TEST_EGRESS_IPV4" \
  --backup-policy-type Continuous --continuous-tier Continuous7Days --output none

# If free tier is selected instead, use the same reviewed account settings
# but replace --capabilities EnableServerless with --enable-free-tier true.
az cosmosdb sql database create --subscription "$COSMOS_TEST_SUBSCRIPTION_ID" \
  --resource-group "$COSMOS_TEST_RESOURCE_GROUP" --account-name "$COSMOS_TEST_ACCOUNT" \
  --name "$COSMOS_TEST_DATABASE" --output none
# Only for the selected free-tier variant, add --throughput 400 to that database command.

az cosmosdb sql container create --subscription "$COSMOS_TEST_SUBSCRIPTION_ID" \
  --resource-group "$COSMOS_TEST_RESOURCE_GROUP" --account-name "$COSMOS_TEST_ACCOUNT" \
  --database-name "$COSMOS_TEST_DATABASE" --name "$COSMOS_TEST_CONTAINER" \
  --partition-key-path /scopeId --partition-key-version 2 --output none
```

Verify the resulting account capabilities/free-tier status, one region, Session consistency, `/scopeId` and absent `defaultTtl`, then grant only the container-scoped role below. Selected-IP firewall propagation can take up to 15 minutes; inspect failures rather than opening access to all addresses. Do not add the `0.0.0.0` Azure-services bypass. [Firewall behavior](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-configure-firewall).

**Current owner decision: retain the validation resource group, Cosmos account/database/container/data role and dedicated Entra apps for future use.** There is no automatic deletion. The private manifest uses `retentionPolicy: retain-for-reuse` and an empty `teardownApprovalReference`; this blocks the cleanup command even if a superseded delete reference is supplied. If free tier is ineligible, serverless retained data/indexes continue to incur storage charges. Record billing mode and refresh network/TLS/token configuration before reuse. A spending alert does not stop Azure resources, and paid backup restore or regional failure injection remains outside this cheapest gate.

The [guarded environment tool](../tools/azure_verification_environment.py) defaults to an offline plan. Its explicitly authorized create mode checks the isolated CLI subscription/tenant and exact current admin object, then creates or safely reuses only the matching tagged resources, database/container and deterministic narrow role/assignment. It records a private `0600` attempt receipt before mutations, stops on unknown cloud outcomes and does not silently retry a failed free-tier creation as paid serverless. If the offer rejects free tier, review that failure and select the already-approved serverless fallback before resuming the same owned target. Existing wider configuration, unowned groups or unexpected resources are refused. These commands use a completed private manifest and the existing isolated `AZURE_CONFIG_DIR`; no JWT is needed for ARM setup:

```sh
python3 tools/azure_verification_environment.py \
  --manifest ops/azure/environment.single-account.example.json
python3 tools/azure_verification_environment.py \
  --manifest /absolute/private/path/approved-environment.json --create-approved
```

Only a **future explicit owner deletion request** may change the private policy to `delete-after-explicit-owner-request` and fill `teardownApprovalReference`. That guarded cleanup accepts matching successful or partial contract evidence, or its matching private setup-attempt receipt for pre-contract failure. It verifies exact ownership/context, generic ARM IDs and separate databases/containers/native roles/assignments; unexpected children or unavailable inventory stop deletion. It can discard only the newly owned validation group's test data, and it verifies group deletion completion. The current retention decision does not authorize running it:

```sh
python3 tools/azure_verification_environment.py \
  --manifest /absolute/private/path/future-delete-approved-environment.json \
  --teardown-approved
```

## Least privilege and network access

Azure control-plane Reader on the selected account and its database/container metadata is enough for the three CLI inspection commands. It does not authorize item writes. The BFF uses `DefaultAzureCredential` and a separate **Cosmos native data-plane role**, scoped to `/dbs/SELECTED_DATABASE/colls/SELECTED_CONTAINER`. The [custom-role example](../ops/azure/cosmos-data-role.example.json) allows metadata, point reads, create/replace and the SDK query permissions. It grants no item hard deletion, stored-procedure execution, conflict management, keys, throughput changes or resource provisioning. Microsoft's SDK query requirements include `readChangeFeed` even though this BFF queries its own immutable journal and does not use Change Feed as its protocol. [Data-plane security reference](https://learn.microsoft.com/en-us/azure/cosmos-db/reference-data-plane-security).

The role definition's assignable scope and its assignment should both name the chosen container. A pre-existing built-in Data Contributor at that same container is broader and may be used only if explicitly approved. Creating a Cosmos data role/assignment requires an operator with the account's `Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions/write` and `sqlRoleAssignments/write` control-plane actions; the application identity never needs those management permissions. The owner can perform these narrow setup actions rather than elevating the development identity. [RBAC connection and scopes](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-connect-role-based-access-control).

These are **owner setup commands**, not commands the preparation workflow executes. Replace variables and review the role file after environment selection:

```sh
az cosmosdb sql role definition create \
  --subscription "$COSMOS_TEST_SUBSCRIPTION_ID" \
  --resource-group "$COSMOS_TEST_RESOURCE_GROUP" \
  --account-name "$COSMOS_TEST_ACCOUNT" \
  --body @/absolute/private/path/approved-cosmos-data-role.json \
  --query id --output tsv

az cosmosdb sql role assignment create \
  --subscription "$COSMOS_TEST_SUBSCRIPTION_ID" \
  --resource-group "$COSMOS_TEST_RESOURCE_GROUP" \
  --account-name "$COSMOS_TEST_ACCOUNT" \
  --role-definition-id "$COSMOS_TEST_ROLE_ID" \
  --principal-id "$COSMOS_TEST_DATA_PRINCIPAL_OBJECT_ID" \
  --scope "/dbs/$COSMOS_TEST_DATABASE/colls/$COSMOS_TEST_CONTAINER" \
  --output none
```

The selected runner/host needs DNS and HTTPS reachability to the chosen Cosmos endpoint, its SDK-discovered regional endpoints, trusted OIDC discovery/JWKS and Microsoft Entra token endpoint. If the account uses a private endpoint, use the owner's approved private-network runner, VPN or DNS route. The tools never open a firewall or create a public endpoint to circumvent that boundary. Review disabling local/key authentication for a new dedicated account separately; the BFF never uses those keys regardless of the account setting.

## Offline plan, read-only inspection and bounded live contract

Python 3, Go 1.26, OpenSSL and the existing Azure CLI are used by the local harness. This preparation has been checked on macOS; its process/file-permission tools assume a POSIX host. The default commands validate the plan without contacting Azure, reading JWT files, starting servers or writing data:

```sh
python3 tools/live_azure_preflight.py --manifest ops/azure/environment.example.json
python3 tools/live_azure_contract.py --manifest ops/azure/environment.example.json
python3 tools/live_azure_contract.py --manifest ops/azure/environment.single-account.example.json
python3 -m unittest discover -s tools -p test_live_azure_tools.py -v
```

After the owner has selected the isolated target, complete a private manifest and inspect **only** its account/container. This performs three read-only CLI metadata actions, each with an explicit subscription argument. It never changes the global CLI default, prints tokens, lists account keys or reads item data:

```sh
python3 tools/live_azure_preflight.py \
  --manifest /absolute/private/path/approved-environment.json --inspect
```

The inspection rejects a different tenant/subscription/endpoint, multi-write mode, weaker-than-Session consistency, missing write metadata, another partition key or default expiry. It is an early configuration check; the production `NewCosmosStore` still independently validates data-plane account metadata and the actual container at startup. No emulator exception or authentication bypass is enabled.

The current production factory's Azure CLI credential uses the CLI's default context. The live harness therefore **refuses** a default subscription/tenant different from the selected manifest. The owner may choose the existing approved context, or log into a dedicated private `AZURE_CONFIG_DIR` and select the subscription there. Do not change a corporate/default context implicitly:

```sh
# Run only after the owner selects this isolated tenant/subscription.
export AZURE_CONFIG_DIR=/absolute/private/path/cosmos-sync-azure-profile
mkdir -p "$AZURE_CONFIG_DIR"
chmod 700 "$AZURE_CONFIG_DIR"
az login --tenant "$COSMOS_TEST_TENANT_ID" --output none
az account set --subscription "$COSMOS_TEST_SUBSCRIPTION_ID"
```

An explicitly approved execution is:

```sh
python3 tools/live_azure_contract.py \
  --manifest /absolute/private/path/approved-environment.json \
  --execute-approved-write-contract \
  > /absolute/private/path/live-contract-result.json
```

It reads private JWT files only after separate target/write approvals, verifies CLI context and ARM metadata, builds the reviewed production CLI, starts two loopback BFFs with `development=false`, `storage=cosmos` and real `NewCosmosStore`, and uses a one-run TLS certificate as a specific trust anchor. TLS verification is retained. `AZURE_TOKEN_CREDENTIALS=AzureCLICredential` prevents unrelated ambient credential sources being chosen for this local gate. The cloud application identity is a separate hosted gate; local CLI success is not managed-identity proof.

The selected shared test scope must be empty before any test mutation. Use dedicated test principals/tenant claim values with no concurrent writers. The contract checks access JWT rejection, current writer/reader grants, shared versus personal partition identity, forged partition denial, a writer cursor rejected for the same-scope/different-principal reader, one atomic create, exact replay on the other replica, conflicting replay payload, stale-version conflict, fixed-head snapshot resume, contiguous incremental journal, authenticated document-free SSE hints, ordered deletion tombstone and immediate temporary-grant revocation. Three new mutations are expected to commit; retry and intentionally denied/conflicting requests are also made. The complete plan requires 31 protocol requests including both health probes; smaller budgets fail before reading tokens or contacting Azure. The selected request limit can range from 31 to 50. SDK-internal retries, initial metadata and event polling generate additional Cosmos requests and RU; the protocol-request bound is not a Cosmos request/RU accounting limit.

For the currently approved one-account gate, use [the single-account manifest](../ops/azure/environment.single-account.example.json), whose `fixtureMode` is `single-account` and whose only principal is `writer`. It uses the same real production Cosmos factory, TLS/OIDC verification, two local BFFs and three accepted mutations. It then changes this account's temporary grants from writer to read-only with a new permission version, verifies old-session and old-cursor rejection plus current read-only synchronization/write denial, and makes the grant inactive while an authenticated stream is open. The fixed plan is 29 protocol requests including two health probes. This proves one principal's role transitions and personal-versus-tenant scope handling; it does **not** prove distinct real-Entra principals' isolation/cursor binding, simultaneous distinct-user grants or hosted multi-replica managed identity. Those limitations appear in the result, and the original full three-principal mode remains intact for a later explicitly selected gate.

`maxRuntimeSeconds` limits the **live BFF phase**, from first-process startup through final contract assertion, to the chosen 30–180 seconds. Read-only CLI inspection and local TLS/build preparation precede that phase and have separate per-command timeouts (CLI 40 seconds; local command 120 seconds). Cleanup can take additional bounded process-stop time. The successful report measures preparation, live phase and cleanup separately; this setting is not a total wall-clock budget. An absolute watchdog kills only the harness-owned BFF processes and shuts down registered active sockets when the live deadline expires, even if HTTP/SSE keeps making progress. Remaining-time checks before and after headers/body/SSE reads reject responses completed after the deadline. A request already received by Azure can still commit after the local connection disappears; that outcome is recorded as incomplete and must be reconciled through its durable receipt.

Two BFF processes, private temporary keys/config/grants/logs and listeners are cleaned on success or failure. JWTs are never passed in command arguments or URLs, and the report contains only known check names, counts, a target digest, configuration findings and the generated test document ID. Arbitrary response/log data are suppressed. Caller-owned Azure login/JWT files are preserved. Failure, an OS/process error, owner interruption or cleanup failure emits the same redacted partial evidence, including the generated `live-` document ID and whether a write was attempted. Some mutations may already have committed; review that document's scope before deciding whether to retry with a fresh dedicated scope.

**Retained data is intentional.** The final logical document is a tombstone, and its journal/head/receipts remain. The harness never hard-deletes records or the container. An owner-approved teardown of a dedicated test container/account is a separate destructive action. The contract has passed local security/I/O fixtures; actual Azure contract evidence remains pending successful account setup. One-account native Entra login and signature-verified API identity evidence are tracked separately and do not prove Cosmos data operations.

## TLS-capable hosting and replica configuration

Use [the BFF production configuration](../bff/config.example.json) and [runtime environment reference](../ops/azure/runtime.example.env), replacing placeholders through the approved secret manager. Direct TLS remains the default and requires `COSMOS_SYNC_TLS_CERT`/`COSMOS_SYNC_TLS_KEY`. The explicit [Container Apps runtime and Terraform](azure-container-apps.md) instead trusts the managed HTTPS ingress with its guarded HTTP backend mode. Both require a shared random signing key of at least 32 bytes, identical history epoch/limits/retention across replicas and the same selected authorization authority. `/healthz` and `/readyz` report process/startup initialization, not continuous Cosmos availability; HTTP probe exceptions apply only in ACA mode. The protected `/metrics` endpoint requires its separate token; never send it to app clients or public scraping configuration.

| Hosting choice | Compatibility decision to make before deployment |
| --- | --- |
| Owner-selected existing TLS-capable host/VM | Can run the container or binary with a managed identity, a TLS listener and approved secret/config mounts. Verify managed identity and network reachability on that exact host; do not assume a new VM is free or approved. |
| Azure Container Apps (recommended) | The supplied template uses HTTPS-only managed ingress, peer encryption and explicit `COSMOS_SYNC_TLS_MODE=container-apps`; default direct TLS never trusts forwarded headers. Use a dedicated/trusted environment and no bypass TCP port. The code and mock plans have passed; actual deployment/network/MI acceptance remains separate. [Runbook](azure-container-apps.md), [ingress protocols](https://learn.microsoft.com/en-us/azure/container-apps/ingress-overview). |
| Azure App Service | Review the actual backend/proxy protocol and certificate/config mounts before choosing it; a public HTTPS URL alone does not prove TLS reaches this BFF. Managed identity image pull documented for ACR does not establish private GHCR authorization. Registry access is an independent release gate. [Custom-container configuration](https://learn.microsoft.com/en-us/azure/app-service/configure-custom-container). |
| Existing approved AKS cluster (optional) | Workload identity plus approved secret mounts and a TLS-validating backend route can fit, but cluster/admin/DNS/network/budget ownership must be selected. Do not create a cluster just to run this contract. For a new routing design, use a supported Gateway API implementation; managed NGINX app-routing support is currently documented only through November 2026. [Workload identity](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview), [routing migration](https://learn.microsoft.com/en-us/azure/aks/app-routing). |

For a selected managed-identity host, use `AZURE_TOKEN_CREDENTIALS=ManagedIdentityCredential` (or `WorkloadIdentityCredential` for the explicitly configured federated host), with `AZURE_CLIENT_ID` only when choosing a user-assigned identity. Avoid CLI/user credentials in a production container. Grant the exact identity the container-scoped role, then show real data-plane startup/contract evidence before switching traffic. The reference files neither provision that identity nor grant its role.

Every replica must receive the same key/epoch and authorization configuration. Legacy grants are reread on requests and SSE rechecks; atomically replace the file or use a mounted directory whose projection updates propagate. A permanently pinned file can prevent revocation updates. Measure that propagation before claiming effective revocation. New built-in authorization uses Cosmos account/scope/membership records; its implementation and same-partition write fence acceptance are tracked in [#33](https://github.com/anaregdesign/cosmos-sync/issues/33), and legacy partitions are not automatically adopted. Cursor/signing key and direct TLS certificate updates require a coordinated rollout/restart; no in-process key ring or certificate reload exists. Key/epoch changes invalidate old cursors/envelopes and cause resync while preserving retained operation receipts. Do not mix keys/epochs across serving replicas.

## RU, throttling, capacity and retention

Choose throughput mode/region using the [current pricing calculator](https://azure.microsoft.com/en-us/pricing/details/cosmos-db/), include hosting, backup, private networking and diagnostic ingestion, and obtain an amount/duration/teardown approval. The harness's maximum live-phase runtime stops its own BFF processes, not provisioned resource billing or already received service operations. Cost Management budgets notify after accounting/evaluation delays and do not stop consumption or resources. [Budget behavior](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets).

The local gate verifies protocol behavior, not an RU/SLA claim. For the separately approved load window, discover the selected account's supported Azure Monitor metrics, then collect RU, throttled requests, latency and per-partition utilization. Diagnostic ingestion is separately charged. Distinguish BFF `rate_limit`, `concurrency_limit` or `stream_limit` from downstream Cosmos `rate_limited`; check Cosmos metrics/logs for actual service-generated 429 and observe durable retry/Retry-After behavior in the app. Hot logical partitions can throttle even when total capacity appears available, and autoscale does not eliminate throttling. [Cosmos throttling investigation](https://learn.microsoft.com/en-us/azure/cosmos-db/troubleshoot-request-rate-too-large).

```sh
# Read-only discovery, after selecting the target; no diagnostic setting is created.
az monitor metrics list-definitions \
  --resource "$COSMOS_TEST_ACCOUNT_RESOURCE_ID" --output json
```

Define a bounded request/concurrency schedule and stop rule before any load generator or throughput change. Record the configuration, measured request/byte/RU volume, observed 429 provenance, retry delay/attempts and exact test duration. Do not increase throughput automatically after observing 429. Process-local BFF admission/rate limits multiply with replica count and are not a distributed global quota.

The default history bound is 10,000 committed events and 128 MiB conservative estimated retained bytes per scope. At capacity the BFF returns 507; existing accepted receipt replays still work. This is admission protection, not garbage collection. There is no safe journal/receipt pruning, TTL migration or historical compaction yet. Snapshot replay is bounded and can fall back to retained journal; it does not free history. For a small isolated capacity drill, separately approve a low configured bound and test 507 plus receipt replay, then stop writes and record the operator action. Do not remove head/change/receipt records to make a test pass. Increasing the bound is a configuration/cost decision with physical partition/storage checks, not an unlimited workaround.

The protocol retains explicit deletion tombstones and orders only within one logical partition. Cosmos latest-version Change Feed does not include hard deletes or guarantee every intermediate version; all-versions/deletes mode has different retention/availability constraints. Neither mode is the BFF's durable protocol today. Backup retention must not be confused with the BFF's unpruned journal. [Change Feed modes](https://learn.microsoft.com/en-us/azure/cosmos-db/change-feed-modes).

## Backup, failover and restore drills

Use explicit single-write mode and Session or stronger consistency. Multiple read regions can be evaluated while retaining single-write mode, but the pinned Go SDK and this application need measured regional recovery behavior; changing region metadata is not sufficient evidence. In Session mode a signed partition-bound Cosmos session envelope is carried through the BFF so requests landing on another replica can maintain read-your-writes. It is not a privileged Cosmos token. [Session token management](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-manage-consistency).

For an isolated availability drill, record acknowledged operation IDs/cursors, temporarily interrupt the approved BFF-to-Cosmos path or restart one selected BFF, then verify no silent write loss, exact retry, preserved local pending state and resumed reads. Regional failover is a separate owner-approved disruptive action only on the selected multi-region single-write test account. Record actual outage duration, retries and read/write recovery; do not infer regional SLA, global ordering or zero-RPO from emulator or two-local-process success. A single-region account cannot provide continued access during a whole-region outage. [Cosmos reliability](https://learn.microsoft.com/en-us/azure/reliability/reliability-cosmos-db).

Choose a continuous-backup tier matching the approved recovery objective. Restore actions incur charges; backup tier and regional coverage affect recoverability. Firewall/private endpoints and role assignments are not restored automatically. Keep the chosen grants, signing-key backup, configuration and secret-manager recovery process outside the Cosmos backup, under the owner's access controls. Restore to a distinct approved test account for this drill, using its actual latest-restorable timestamp; do not replace the live account. [Continuous backup and restore limitations](https://learn.microsoft.com/en-us/azure/cosmos-db/continuous-backup-restore-introduction).

The following reviewed restore command is **not run automatically**. It creates a billed target account and needs a separate explicit approval, source permissions, selected timestamp/location/target/budget and teardown plan:

```sh
az cosmosdb restore \
  --subscription "$COSMOS_TEST_SUBSCRIPTION_ID" \
  --resource-group "$COSMOS_TEST_RESTORE_RESOURCE_GROUP" \
  --account-name "$COSMOS_TEST_ACCOUNT" \
  --target-database-account-name "$COSMOS_TEST_RESTORE_ACCOUNT" \
  --restore-timestamp "$COSMOS_TEST_RESTORE_TIMESTAMP" \
  --location "$COSMOS_TEST_RESTORE_LOCATION" \
  --databases-to-restore "name=$COSMOS_TEST_DATABASE" "collections=$COSMOS_TEST_CONTAINER" \
  --disable-ttl true --public-network-access Disabled --output none
```

Reapply only reviewed network, identity/RBAC and safe runtime configuration to that distinct target; rerun the production metadata guard before using it. Verify the restored head/document/journal/receipt state corresponds to the selected timestamp, inspect throughput/index status and use an approved new history epoch for a cutover after rollback. SDK resync clears confirmed cache state but retains attempted outbox identities/bases for reconciliation. A receipt lost by a rollback cannot provide exactly-once replay across that rollback; already ACKed writes newer than the restore point may be absent, and stale pending bases may conflict. Reconcile those outcomes explicitly and report measured RPO/RTO. Never claim that a new cursor can restore lost acknowledgements automatically. [Restore procedure](https://learn.microsoft.com/en-us/azure/cosmos-db/restore-account-continuous-backup).

## Evidence required before the live gates close

Attach redacted evidence for the selected target metadata, actual three-mutation contract, chosen host's managed identity/private image pull/TLS/grant propagation, measured RU/429 with the approved cap, capacity outcome, backup/restore and failover results appropriate to the supported topology. Mark every unexecuted or inapplicable topology explicitly. The app/device chain must also prove OIDC token refresh, offline edits, real reconnect, conflict resolution, current grant revocation/cache purge and sign-out on the owner-selected physical devices. A plan, emulator pass or simulator pass does not close those cloud/device acceptance items.
