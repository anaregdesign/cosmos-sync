# Release preparation

No package has been published. The GitHub repository remains private. No public license has been selected; first release requires the owner's legal/license decision. The package's LICENSE is an explicit pending/UNLICENSED placeholder and must be replaced with the approved license before release, regardless of whether pub tooling accepts it. The package name was unregistered at `https://pub.dev/api/packages/cosmos_sync` (HTTP 404 on 2026-10-03); that does not reserve it.

## GitHub Packages / GHCR

Target: `ghcr.io/anaregdesign/cosmos-sync-bff`. On 2026-10-03, the existing signed-in administrator's [organization Packages UI](https://github.com/orgs/anaregdesign/packages) listed 11 packages with Type All and Visibility All; searching `cosmos-sync-bff` returned zero matches. No existing name collision was observed, and no token or OAuth permission was added. The CLI still lacks `read:packages` and its listing returned HTTP 403. Recheck immediately before publication: this observation does not reserve the name or verify future image access. If it becomes occupied by an unrelated package, use `cosmos-sync-gateway` (image) and retain the repo/Dart names, or consistently use repo `cosmos-offline`, Dart `cosmos_offline`, image `cosmos-offline-bff` after checking availability.

CI builds an image without pushing. `publish-ghcr.yml` is manual and also requires repo variable `GHCR_PUBLISH_ENABLED=true`, main branch and an explicit confirmation input. The variable is not set. Before enabling, review CI, inspect package conflicts/inherited access, approve first publication and retain private visibility. Publishing uses the ephemeral `GITHUB_TOKEN` with job-only `packages:write`, not a new user token. Do not assume a required-reviewer environment gate is supported by the organization's plan. Add one only after verifying plan support. Container releases use immutable source SHA tags; deployment is a separate decision.

## pub.dev

First publication is public and effectively permanent. Approve license, source visibility/disclosure, package owner/publisher, API/version and support commitments first. Recheck naming, run package analyze/tests and `dart pub publish --dry-run`, then perform an explicitly approved first manual publish. For later automation, configure pub.dev's authorized GitHub repository, workflow/tag pattern and subdirectory. A disabled OIDC workflow template is in `.github/release-templates`; it has not been installed as an active publication workflow. Version tags must match `pubspec.yaml` and the configured pub.dev pattern. No long-lived pub credential should be committed.

## Azure and operations

Choose tenant/identity provider and audience, server grant source and revocation process, hosting location, Cosmos account/database/container and RU/backup budget. Provisioning is deferred. Use managed identity/data-plane RBAC, a preexisting NoSQL container partitioned by `/scopeId`, no default TTL for this retained-journal prototype and one write region. Share cursor/session signing keys between replicas through an approved secret manager. Load-test partition size, hot-user throughput, history growth, retry rates and restore/recovery before production. Official emulator storage/security integration now has a reproducible local/CI gate; its Eventual metadata is rejected by production policy. Live Azure replica/RU/backup/deployment verification remains issue #16 until an isolated environment is explicitly selected and authorized.

Sources and current platform constraints: [research](research.md).

## Remaining tracked owner gates

- [#14](https://github.com/anaregdesign/cosmos-sync/issues/14): license, source visibility, pub.dev owner/publisher and initial-public-release approval.
- [#15](https://github.com/anaregdesign/cosmos-sync/issues/15): GHCR access/protection and authorized first distribution; namespace lookup passed, but private image pull/access requires an approved publication to verify.
- [#16](https://github.com/anaregdesign/cosmos-sync/issues/16): isolated Azure environment, budget/hosting, live operations and deployment approval. Existing corporate subscriptions are not assumed authorized for this work.

Code/issue/PR work can finish independently. These gates remain open, and no autonomous merge or publication occurs.
