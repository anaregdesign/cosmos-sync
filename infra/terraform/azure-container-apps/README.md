# Azure Container Apps BFF

Terraform reference for the published Cosmos Sync BFF. Start with the
[deployment runbook](../../../docs/azure-container-apps.md) and
[developer onboarding acceptance](../../../docs/developer-onboarding.md).

This directory creates an ACA environment/app, a dedicated user-assigned identity
(or uses the supplied existing identity), and narrow Cosmos/Key Vault role
assignments. It references an **existing** resource group, Cosmos NoSQL
database/container, Key Vault and secret versions. It never reads Cosmos keys or
Key Vault values, and never creates identity-provider clients/consent, a database,
network, log workspace or secret. New-deployment configuration uses `authorization.mode=builtin`, gated by an
explicit compatible-image/new-namespace verification assertion. Explicit legacy
mode contains empty grants and denies all end users. Neither mode adopts legacy
data or provisions identity-provider accounts automatically.

`oidc.allowed_client_ids` optionally restricts API admission to exact signed
`azp` client IDs in addition to the existing issuer, API audience and scope
checks. It defaults to `[]`; empty/omitted values omit `allowedClientIds` from
runtime JSON so already published strict-decoder images retain compatibility.
Before opting in, pin an updated source-addressed image that implements this
setting. The original public `0.2.0-dev.1` image from commit `82e937c` does not
support this field and rejects it at startup. Use registered native public client
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

From a clean checkout, run the validator with Bash, Python 3 and curl. It downloads
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
