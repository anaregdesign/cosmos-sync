# Azure Container Apps BFF

Terraform reference for the published Cosmos Sync BFF. Start with the
[deployment runbook](../../../docs/azure-container-apps.md) and
[developer onboarding acceptance](../../../docs/developer-onboarding.md).

The module is for consumers deploying into **their own** Azure environment with
their own private state and configured OIDC trust. Entra External ID is the
preferred consumer reference broker, with Apple/Google as possible upstream
providers, not an exclusive issuer for generic builtin/legacy authentication.
`deployment.tenant_id` identifies the Azure management/UAMI tenant; the OIDC
issuer may belong to a separate customer tenant. API JWT validation and
server-managed authorization remain mandatory, without a provider-name blacklist.
The supplied Web MSAL adapter is Entra-specific; generic browser work is
[#40](https://github.com/anaregdesign/cosmos-sync/issues/40).

This directory creates an ACA environment/app, a dedicated user-assigned identity
(or uses the supplied existing identity), and narrow Cosmos/Key Vault role
assignments. It references an **existing** resource group, Cosmos NoSQL
database/container, Key Vault and secret versions. It never reads Cosmos keys or
Key Vault values, and never creates identity-provider clients/consent, a database,
network, log workspace or secret. New-deployment configuration uses `authorization.mode=builtin`, gated by an
explicit compatible-image/new-namespace verification assertion. Explicit legacy
mode contains empty grants and denies all end users. Neither mode adopts legacy
data or provisions identity-provider accounts automatically.

The directory lifecycle extension published from exact source `36d2680` is an
explicit opt-in:
`authorization_mode="directory"` requires the typed `directory` input and
`directory_image_verification`. The overlay in `directory.tfvars.example` is
deliberately unverified and must not be used unchanged. The module checks exact
CIAM/tid trust, distinct API/public-client GUIDs, one admitted client, bounded
callbacks/domain/source tenants and namespace. It derives
`managedIdentityClientId` from the BFF's actual assigned UAMI, not another
client-supplied setting. The reader application must have a different client ID.
See [the server-only directory contract](../../../docs/identity-directory.md).
These additional CIAM/GUID/profile restrictions belong only to that optional
directory adapter. Its production reader currently supports reviewed workforce
federation, not arbitrary social profiles; do not apply those restrictions to
generic OIDC or loosen profile verification to claim broader linking support.

The verification record must name the **same immutable image** as `image`, a
full source commit and `verified=true` after reviewing its source/build evidence.
Known published builtin/legacy-only artifacts are rejected even if asserted
verified. This does not inspect a registry, publish a candidate or authorize an
apply. No Graph grant, federated credential, user or legacy ownership migration
is implicitly created here. Builtin/legacy omit `authorization.directory` and
retain their previous generated configuration.

The [verified public release](../../../docs/release.md) now supplies a compatible
immutable directory image. It has not changed the retained Azure app. A
validation-only local state mirror may reconstruct only explicitly approved
existing resources when original private state is not available in an isolated
worktree. Imports are control-plane reads with local bindings, not authorization
to apply, migrate/replace original state, or create a second authoritative state.
Keep mirror directories/state/saved plans private; review baseline drift first.
Actual activation still needs Azure validation, separate concrete apply approval
and an explicit state-authority/handback decision. For the retained reference,
the owner has since approved a distinct local management-state adoption and fresh
validation on the original-artifacts-unavailable assumption. It is not started;
the old mirror remains reference-only and no apply is approved. Other consumers
must use their own state/authority decisions, not this private mirror.

Before activation, preserve the existing state/cursor key, pin the compatible
candidate and verify the retained UAMI/FIC, target-only Graph `User.Read.All`,
exact native/SPA callbacks and private Cosmos path. Review a saved plan showing
only the intended workload configuration, no replacements/roles/network or
replica expansion. Complete Azure validation before a separately authorized
apply. Do not send directory settings to the retained old image. A rollback
must restore its matching configuration/image together; it neither undoes
directory commits nor adopts directory-owned documents in builtin/legacy mode.
Stop after a partial/unknown acceptance outcome and preserve its receipt.

ACA launches `command = ["/cosmos-sync-bff"]` with no `args`, taking configuration
from `COSMOS_SYNC_CONFIG_JSON`. This replaces the published image's default
file-config command and avoids combining `-config` with environment JSON; the BFF
rejects that combination. Keep this explicit command when adapting the template.
See [ACA command settings](https://learn.microsoft.com/en-us/azure/container-apps/containers#configuration)
and [the CRI command rules](https://github.com/containerd/containerd/blob/main/internal/cri/opts/spec_opts.go#L53-L74).

Ingress enum casing and probe ordering match observed ARM readback. This avoids
an otherwise unchanged app update during an environment-only logging change;
probe settings and security behavior are unchanged. The real saved plan and
portable checks are distinguished in [verification](../../../docs/verification.md).

`oidc.allowed_client_ids` optionally restricts API admission to exact signed
`azp` client IDs in addition to the existing issuer, API audience and scope
checks. It defaults to `[]`; empty/omitted values omit `allowedClientIds` from
runtime JSON so already published strict-decoder images retain compatibility.
Before opting in, pin an updated source-addressed image that implements this
setting. The [verified images from `76c1f46` and `36d2680`](../../../docs/release.md)
implement it; directory mode requires the latter's lifecycle contract.
The original public `0.2.0-dev.1` image from commit `82e937c` does not support
this field and rejects it at startup. Use registered native public client
IDs, with at most 32 distinct visible ASCII
values of 1–256 bytes, and configure every replica consistently. This restriction
does not prove the native app binary or upstream Google/Apple authentication;
see [the BFF admission boundary](../../../bff/README.md).

Set optional `infrastructure_resource_group_name` to a new, unused unqualified
resource group name when the owner needs a deterministic ACA infrastructure cost
scope. The platform creates/manages that group in the approved environment/subnet
subscription; this module does not create an extra `resourceGroups` resource.
The default `null` omits the ARM setting and preserves Azure's generated name.
The input accepts the documented safe ASCII naming subset (1–90 characters,
letters/digits/`_`/`-`/`.`/parentheses, no trailing period), never a resource ID.
Do not pass the existing application, data or networking resource group, and
verify that the proposed name is unused before an approved apply.

From a clean checkout, run the validator with Bash, Python 3, curl and Go 1.26+.
It checks the actual mocked directory JSON with the Go factory's pure trust
validation and strict configuration schema, without OIDC/Graph/Azure requests.
It downloads
Terraform 1.15.8 and TFLint 0.64.0 into an owned temporary directory, verifies
embedded official-release SHA256 hashes and removes only that temporary directory
on exit. It supports macOS/Linux ARM64 and AMD64 and performs no Azure operations:

```sh
bash infra/terraform/azure-container-apps/verify.sh
```

If these exact tool versions are already installed, the equivalent commands are:

```sh
terraform fmt -check -recursive
terraform init -backend=false -input=false -lockfile=readonly
terraform validate
terraform test
tflint --chdir=.
```

`terraform test` uses mocked providers and **plan** commands exclusively. Do not
replace its providers with real providers or its commands with `apply`.

Copy `terraform.tfvars.example` into an ignored private variables file and
replace every placeholder, including the all-zero image digest, after choosing
the target and publication. Do not put tokens, passwords, private keys or end-user
grants in Terraform variables, source, state or plan artifacts. Production should
use a separately approved remote state backend; `backend.hcl.example` contains
only backend identifiers. Provider versions are pinned and the committed lock
file includes official release checksums. Review provider/API upgrades in a PR.

All managed resources have `prevent_destroy` guards. A routine Terraform apply
cannot delete/recreate them; decommissioning requires a separate reviewed change
and owner approval. Existing data and its resource group stay outside this state.
