# Release and distribution

The [cosmos_sync 0.2.0-dev.1 SDK](https://pub.dev/packages/cosmos_sync/versions/0.2.0-dev.1)
was published from `82e937c8659e9ec0263a78e6e3ad2f43e05be20a` after all eight
[main checks](https://github.com/anaregdesign/cosmos-sync/actions/runs/37140346546)
passed. Its actual archive and clean hosted Dart/Flutter/Chromium consumers were
verified. The BFF image from that same source is public at the index digest below;
full read-only registry evidence is tracked in
[#15](https://github.com/anaregdesign/cosmos-sync/issues/15).

The BFF was subsequently published from
`76c1f46876b3dfd13f4bd7d4dd144cdf74efa5c0` after all eight
[main checks](https://github.com/anaregdesign/cosmos-sync/actions/runs/37175675742)
passed. Its [successful public release and verification](https://github.com/anaregdesign/cosmos-sync/actions/runs/37176169762)
records the immutable index:

```text
ghcr.io/anaregdesign/cosmos-sync-bff@sha256:2651a4bca6df6f751b7f5e46d317ea9f6e4ca83081374badae142d57cdfc812a
```

This source implements optional signed native-client admission. Both platforms,
public anonymous manifest access, authenticated pulls, source/version/MIT/nonroot
metadata and subject-bound BuildKit provenance/SPDX SBOM were verified. Its
source-SHA tag distinguishes it from the first BFF image while retaining version
`0.2.0-dev.1`. The SDK library and existing pub.dev archive are unchanged. Cloud
runtime and consumer-provider acceptance remain separate gates in
[verification](verification.md).

On 2026-10-03 the owner explicitly approved
**MIT**, copyright 2026 anaregdesign, **public GitHub source and public GHCR**, and
the initial prerelease **0.2.0-dev.1**. The chosen pub.dev Google account is kept
private in the owner's local authentication flow; no personal email is recorded here.
Repository, BFF and SDK include identical approved MIT licenses. GitHub source is
public and private vulnerability reporting is enabled. Selected personal-owner
identity was verified through normal existing credential refresh without adding
an OAuth grant. The prerelease has measured Android/iOS emulator, macOS and
Chromium coverage and no production SLA. A verified publisher/domain has not been
selected; that does not prevent the approved first personal-account publication.

## Prepare the exact candidate

1. Record the resolved owner decisions on [#14](https://github.com/anaregdesign/cosmos-sync/issues/14)
   without publishing the personal account identity. Preserve matching MIT notices
   in the repository, BFF and SDK. The container includes its project license, the
   Go license and downloaded dependency LICENSE/NOTICE files under `/licenses`.
2. Run `python3 tools/package_docs.py` after any protocol/query/security/authorization edit. The
   archive includes those documents under `packages/cosmos_sync/doc`; optional source
   links can remain private without blocking package usage or safety documentation.
3. Merge the reviewed candidate and require the **latest completed successful main
   push CI** for its exact SHA, including every configured job. PR success alone is
   insufficient. Run `dart pub publish --dry-run` with no warnings and inspect the list.
4. Record owner approval on the issue, then configure these non-secret repository
   variables for the exact candidate: `RELEASE_APPROVED_SHA`,
   `RELEASE_APPROVED_VERSION`, and `RELEASE_LICENSE_SPDX` (an approved SPDX identifier).
   This workflow does not choose a license or infer approval from a variable alone.

`python3 tools/release_verify.py preflight` reports candidate metadata and pending
license files without publishing. The `--target ghcr|pub --sha <40-hex> --version <version>`
mode additionally rejects dirty/mismatched sources, pending/mismatched MIT licenses, missing approval
variables, stale main commits, missing/skipped/failed CI jobs and incomplete latest CI.
Successful checks provide the exact run URL. New main commits require new review and
new SHA approval. Distribution uses a digest; a source-SHA tag is still a mutable registry tag.

## GHCR: publish, then verify access

Target: `ghcr.io/anaregdesign/cosmos-sync-bff`. On 2026-10-03 the existing signed-in
organization administrator's [Packages UI](https://github.com/orgs/anaregdesign/packages)
showed Type All / Visibility All and zero `cosmos-sync-bff` matches. The CLI lacks
`read:packages`; no OAuth expansion or new token was requested. Recheck the namespace
before publication. This observation does not reserve a name. An unrelated collision
would require the owner to approve the alternate image name `cosmos-sync-gateway`.

The manual `publish-ghcr.yml` runs only on main with `GHCR_PUBLISH_ENABLED=true`
and confirmation `publish-approved-container`. It requires explicit SHA/version
inputs plus the matching approval variables above. Set `GHCR_RELEASE_VISIBILITY`
to the owner's approved **final** visibility. Authentication uses the job's temporary
`GITHUB_TOKEN` with `packages:write`; no user token or registry secret is required.

The preflight treats a missing first package as **private**. For an approved public first distribution,
the workflow retains the owner-approved final value `public`, discovers the current
package state (a missing initial package means `private`), verifies that private
stage and reports `verified_private_stage_public_transition_pending`. It records
the digest before verification and retains it even if a later access check fails.
Then explicitly change only this package to public in GitHub's package settings and
run `verify-ghcr.yml` with visibility `public`. Existing public packages verify
public directly. The workflow never changes package visibility or treats a private
stage as completed public distribution.

For the first `0.2.0-dev.1` release, push run
[37140837379](https://github.com/anaregdesign/cosmos-sync/actions/runs/37140837379)
created index digest
`sha256:a23ab75eb4518597aa26e4833787b9b77a07def717868e080944555594adc1b3`.
Post-push inspection found the package already public, so the expected-private
stage check failed after publication. Reuse that digest and verify its actual
public visibility; this failure requires no image rebuild or upload.

Verification also pulls each platform by its child manifest digest from the
reviewed index. Pulling amd64 and arm64 into a classic daemon image store under
the same index-digest reference can fail with `cannot overwrite digest` even
after all layers download. Distinct child references avoid that local collision.
Evidence retains the original index digest, each selected platform manifest and
its bound source metadata/provenance/SBOM. Docker context or image-store settings
do not need to change.
Repository access inheritance and Actions access must also be inspected; public
source alone does not make a GHCR package public. [Official GHCR access rules](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)

After approval and a green main run, dispatch the workflow with the reviewed values:

```sh
gh workflow run publish-ghcr.yml --ref main \
  -f source_sha=<approved-40-hex-sha> -f version=0.2.0-dev.1 \
  -f confirm=publish-approved-container
```

The workflow cross-compiles Linux amd64/arm64 with pinned base images, pushes the
SHA tag, then verifies authenticated digest pulls of both variants, nonroot/entrypoint
and source/version labels, registry-attached BuildKit provenance and SPDX SBOM,
linked repository, package visibility and anonymous read/denial. The JSON evidence
and digest are retained as an Actions artifact and run summary. Verification failure
after push does not undo publication; record the partial result and fix access checks.

To recheck access after an approved visibility change using the repository's
temporary read-only token, dispatch `verify-ghcr.yml`. This makes no package or
visibility writes and avoids expanding the current CLI token's scopes:

```sh
gh workflow run verify-ghcr.yml --ref main \
  -f digest=sha256:<index-digest> -f source_sha=<source-sha> \
  -f version=0.2.0-dev.1 -f visibility=public
```

An already authorized package/API reader can also run the verifier locally;
private registry pulls additionally need an existing authorized registry login:

```sh
python3 tools/release_verify.py ghcr --digest sha256:<index-digest> \
  --sha <source-sha> --version 0.2.0-dev.1 --visibility public \
  --output /tmp/cosmos-sync-ghcr-release.json
```

Private images require an authorized existing registry credential or a repository
Actions job with package access. If neither exists, request access from the owner;
do not expand a user token silently. Keep deployments pinned to the recorded index
digest. Publication is independent of deployment.

BuildKit's registry-attached attestations are **not signed GitHub attestations**.
They can be inspected with `docker buildx imagetools inspect` but do not establish a
cryptographic GitHub identity. Signed GitHub attestations for a private repository
require Enterprise Cloud; source publication or verified plan eligibility is required
before adding that feature. [BuildKit attestations](https://docs.docker.com/build/metadata/attestations/),
[GitHub availability](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)

## pub.dev: first manual publication and ownership

The initial `0.2.0-dev.1` upload is complete; do not upload that immutable version
again. Its archive SHA256 is
`5fe3f46ec981815c90e9dd68cdaac58519a7af8667e99672b499d92a0a8d404a`
(87,507 bytes), matched against the clean release source. The commands below
describe guarded release procedure; a later version needs its own reviewed
source/version approval. To reverify this archive, use a clean checkout of its
original `82e937c8` source rather than labeling it with a later tools/docs commit.

The public package API returned HTTP 404 for `cosmos_sync` again on 2026-10-03;
the name is not reserved. Recheck immediately before the first upload. First
publication is effectively permanent. [Publication policy and requirements](https://dart.dev/tools/pub/publishing)

The **first version must be published manually** using the owner's selected Google
account. The owner completes the browser authorization themselves. Do not send
credentials through chat, copy refresh-token files or place them in GitHub secrets.
Set `PUB_PUBLICATION_APPROVED=true` only after explicit approval, then run:

Before uploading, run official `dart pub login` with its stdout/stderr captured
only in a private local file and compare the returned Google email against the
owner's privately selected account. Record only `identityMatchesOwner: true` in
public evidence. Normal existing credential refresh is sufficient; if the CLI
requests new authorization, stop and hand the browser step to the owner. Do not
print the account email, raw CLI output or OAuth authorization URL in CI/Issues.

```sh
python3 tools/release_verify.py preflight --target pub \
  --sha <approved-40-hex-sha> --version 0.2.0-dev.1
cd packages/cosmos_sync
dart pub publish --dry-run
dart pub publish
```

Only the final command uploads. It presents the archive and any required sign-in.
The first uploader becomes the initial package owner. A new package cannot be
uploaded directly to a verified publisher; after first upload the owner transfers
it from the package Admin tab to their chosen verified publisher. Publisher creation
requires a controlled domain and, if needed, Google Search Console domain verification.
Do not guess a publisher ID or email address. [Verified publishers](https://dart.dev/tools/pub/verified-publishers)

After upload, from the unchanged approved source run:

```sh
python3 tools/release_verify.py pub --version 0.2.0-dev.1 \
  --sha <approved-40-hex-sha> \
  --output /tmp/cosmos-sync-pub-release.json
```

The verifier requires a clean checkout matching the explicit reviewed source SHA
before any registry reads. Historical releases can be verified from their original
commit even after main advances. It downloads the public version archive, verifies the registry SHA256 when supplied,
and compares all library files, essential package docs and every archive file with
the reviewed source. It rejects extra library files, development assets, links and unsafe paths.
Record the package/version URL, ownership-verification result and archive hash on
[#23](https://github.com/anaregdesign/cosmos-sync/issues/23). Also resolve the SDK
from pub.dev into an isolated temporary pub cache in the same verification command.
It checks the exact hosted version and installed library bytes, runs the public
Dart example with native SQLite offline/reopen/ACK/tombstone behavior, and creates
a clean Flutter consumer. That consumer analyzes the public imports, runs native
SQLite and Chromium IndexedDB offline/reopen/tombstone tests, and builds release web.
Install Dart, Flutter and Chrome/Chromium first; set `DART`, `FLUTTER` or
`CHROME_EXECUTABLE` when their executable paths differ from tool defaults. These
local storage tests use a synthetic session/demo transport; they do not prove
live Azure or production OIDC acceptance. Path dependencies and dry-run results
cannot satisfy installed-registry verification.

## Later OIDC publication

`.github/release-templates/publish-pub.yml.disabled` remains inactive. After first
publication and ownership verification, configure the package Admin tab for repository
`anaregdesign/cosmos-sync` and tag pattern `cosmos_sync-v{{version}}`; only then install
the template and set `PUB_PUBLISH_ENABLED=true`. The tag must point to the reviewed
current main commit and match `pubspec.yaml` exactly. Pub.dev accepts GitHub OIDC
publication only from **tag-push** events, not workflow_dispatch or branch pushes.
The template uses the pinned official Dart reusable publisher, with short-lived OIDC
and no stored pub credentials. [Official automation constraints](https://dart.dev/tools/pub/automated-publishing)

Protect release tags and use a required GitHub environment reviewer when the plan
supports it. Do not assume private-repository environment protection eligibility.
If enabled, configure the identical environment name on pub.dev and in the reusable
publisher input after checking its supported inputs. Approval variables provide an
explicit candidate binding; they are not a substitute for controlling who may edit
workflows, variables or release tags.

## Security and live operations

Before public release, establish a private vulnerability reporting route. A public
GitHub repository can enable private vulnerability reporting; verify the Security
tab's reporting flow afterward. If source stays private, the owner must designate
a private support/security contact for SDK consumers. Do not publish an invented
email. Keep personal account details out of public Issues and logs. Keep deployment,
incident response, physical-device and live Azure acceptance
separate from registry upload. [Security boundaries](security.md) remain mandatory.

Azure work needs an explicitly selected isolated subscription/resource group,
identity provider/audience, authorized accounts, Cosmos NoSQL account/container and
RU/backup/hosting budget. Use managed identity/data-plane RBAC, `/scopeId`, one write
region, acceptable production consistency and no automatic TTL/GC. Cursor/session
signing keys must be shared through the approved secret manager. Test live replicas,
revocation, RU limits, restore and target devices before production; emulator results
do not prove cloud cost, availability or backup behavior.

Tracked gates: [#14](https://github.com/anaregdesign/cosmos-sync/issues/14) owner/license,
[#15](https://github.com/anaregdesign/cosmos-sync/issues/15) GHCR distribution,
[#23](https://github.com/anaregdesign/cosmos-sync/issues/23) pub.dev,
[#16](https://github.com/anaregdesign/cosmos-sync/issues/16) live Azure.
