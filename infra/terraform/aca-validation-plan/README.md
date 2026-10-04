# Private West US 2 ACA validation candidate

This is local preparation within the owner's authorization to use necessary
minimal Azure resources/settings in the selected subscription. Real saved plans
still require operator review against the exact private target and boundary. See [the private-backend proposal](../../../docs/aca-validation-plan.md).

`prerequisites` creates an isolated VNet, separate delegated ACA and nondelegated
Private Endpoint subnets, a private Standard RBAC Key Vault, two backend Private
Endpoints and their DNS zones/VNet links. Cosmos is referenced by exact existing
ARM ID and is neither recreated nor imported. Its public access and IP ACL stay
unchanged; no ordinary service endpoints or public firewall exception are added.
Private Endpoint connection approval is part of the proposed owner-reviewed plan.
No credentials/secret values/data-plane writer role are managed by Terraform.

The cursor key is initialized within that subscription authorization, via a direct
ARM write to the exact named secret using existing operator control-plane rights.
Its value stays out of Terraform, argv, environment, diagnostics and chat. The
actual returned version URI, target metadata, Mac ingress IP and names are private
inputs to the existing [`azure-container-apps`](../azure-container-apps/README.md)
module. Never fake or omit the secret version to finish a plan early.

The workload stage creates a dedicated UAMI, exact container Cosmos role and
assignment, exact cursor-secret reader assignment, Consumption environment/app
and the platform-managed infrastructure. Pin the existing published digest;
builtin uses an intentional new namespace; CPU/memory are 0.25/0.5 GiB, replicas
0–1 and HTTPS ingress only from the currently approved Mac `/32`. Set the
optional `infrastructure_resource_group_name` to the exact new group in the
private review proposal. The group is created/managed by Azure, never manually
modified. Actual provider registration/capacity/governance and managed network
charges still need read-only preflight and owner review.

With Terraform 1.15.8, these checks are local and mocked, without Azure login/API
calls. Initial `init` downloads the pinned official provider with committed lock
checksums:

```sh
terraform -chdir=infra/terraform/aca-validation-plan/prerequisites fmt -check -recursive
terraform -chdir=infra/terraform/aca-validation-plan/prerequisites init -backend=false -input=false -lockfile=readonly
terraform -chdir=infra/terraform/aca-validation-plan/prerequisites validate
terraform -chdir=infra/terraform/aca-validation-plan/prerequisites test
```

Mock plans prove network/resource references and deny settings, not real ARM
acceptance, DNS routes, identity privileges or secret resolution. Private variable
files, plans and state are ignored and must remain access-restricted. Real saved
plans are reviewed separately before apply. All persistent resources have
destruction guards; never run broad `destroy` or remove the validation group.
