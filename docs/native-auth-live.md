# Owner-assisted actual Entra validation

Run the actual macOS, Android-emulator or physical Android AppAuth target after the owner-approved dedicated
registrations in [entra-setup.md](entra-setup.md) have been created and read back.
The operator's ignored `.cache/entra-azure` directory contains 0600
`approved-owner.local.json` and `registration-receipt.local.json`. Their actual
tenant/account/application identifiers are never checked into this repository.

```sh
python3 tools/native_entra_auth.py --owner-assisted
```

Set `FLUTTER_BIN`/`GO_BIN` or `--flutter-bin`/`--go-bin` if those tools are not on
PATH. macOS remains the default. For Android, select the exact supported physical
device in an ignored 0600 identity file and explicitly authorize installation:

```sh
python3 tools/native_entra_auth.py --owner-assisted --device android \
  --device-id-file .cache/devices/android.txt --authorize-install \
  --output artifacts/native-entra-android.json
```

The evidence destination must be fresh and under ignored `artifacts/`. The runner
uses only a new `adb -s <selected-device> reverse --no-rebind` mapping for its
capability-bound loopback control port. It neither exposes the control server to
the LAN nor forwards cloud endpoints. Cleanup removes only that exact mapping
while it still matches the runner's destination; cleanup failure cannot report
success. No iOS signing, pairing, provisioning or installation is performed.

For simulator-first development, use a fresh supported Android emulator and its
exact ignored 0600 identity file instead:

```sh
python3 tools/native_entra_auth.py --owner-assisted --device android-emulator \
  --device-id-file .cache/devices/emulator.txt --authorize-install \
  --output artifacts/native-entra-emulator.json
```

This mode requires the exact selected Flutter device to be a supported Android
emulator with an `emulator-<port>` identity. It cannot fall back to an attached
physical Android or another emulator. Both Android modes preserve explicit
installation authorization and owned ADB reverse cleanup. A successful emulator
receipt records `physicalDevice=false` and `emulator=true`; it cannot supply the
final physical-device gate. The added selection/evidence regressions are offline
tests, **not a newly executed native OIDC login**.

These commands are manual and never perform
CI sign-in. The owner operates the system browser's credentials/MFA and reviews
the new `Cosmos.Sync` permission. The request also includes standard
`openid profile offline_access`; it includes no Microsoft Graph data permission.
The runner does not create registrations, consent grants, users, directory roles,
Azure resources or BFF grants.

The separate native integration target uses the production AppAuth adapter and
OS secure storage. The default **API-only, protocol-v1** mode uses a high-entropy,
loopback-only control URL to supply public configuration and receive API access JWTs into exclusive 0600 files
in a new 0700 ignored directory. Neither tokens nor account identities are printed.
Token GET requests, unknown routes, phases and fields are rejected. Provider and
Flutter diagnostics remain in a private local log.

The target performs interactive code/PKCE sign-in, secure-record restoration in
a new controller, real refresh and local sign-out of an isolated random OS secure
record. It does not log out another app session or delete reusable registrations
or cloud resources. Controller recreation proves no OS process restart. The
token-capture protocol belongs only to this integration target; ordinary `main`
contains no such path and always uses actual AppAuth.

For each captured JWT, `bff/cmd/verify-entra-principal` verifies the provider's
signature, exact issuer and API audience, v2 format, expiry/nbf/iat, delegated
`Cosmos.Sync` scope, selected tenant and the approved directory account's signed
`oid`. Only then does it derive the API JWT's `sub` and write an exact single-user
BFF grant **proposal**. The subject never comes from an ID token, UPN or unverified
JWT decode. The initial and refreshed tokens must identify the same principal.
Both CLI and runner success reports contain only nonidentifying booleans.

`.cache/entra-live-native/latest.local.json` points to the private run directory.
Each parsed attempt creates a new incomplete `proof.json` and updates that pointer
before target/configuration preflight. Invalid preflight, timeout, interruption
and cleanup failure retain sanitized stage/reason codes and cannot reuse an old
successful receipt. Source commit and dirty-tree status are recorded separately.
It contains `initial.jwt`, `refresh.jwt`, per-phase `identity.local.json`,
`grants.proposed.local.json`, `proof.json`, and a private Flutter log. Share only
the nonidentifying proof after checking the run succeeded. Retain the access JWT
privately only while the approved live BFF/Cosmos contract needs it, then delete
it or remove it on expiry. An API JWT can remain valid after local sign-out;
that is why the files remain private. Refresh credentials and the logout hint
are cleared from the isolated OS secure record by the target's cleanup.

This is one-account provider validation. Multi-principal isolation, read-only
user behavior and same-tenant ungranted-user denial remain separate real-provider
acceptance evidence when the owner chooses to supply more accounts. This command
does not claim that those cases, process restart or a Cosmos connection passed.
The existing injected-adapter security suites continue to cover those boundaries.

## Directory fresh-proof mode

The separate protocol-v2 mode is enabled only by `--directory-manifest`. Start
from [the native directory manifest](../ops/azure/native-directory-proof.example.json)
and supply private absolute paths, explicit target/write approvals and retained
directory-state acknowledgment. Execute from the exact clean candidate commit.
The runtime must select production Cosmos/directory authorization, the exact
CIAM customer/API/public-client trust and native callback, with no legacy grants.
Read-only ARM checks must match the reviewed immutable compatible image,
configuration digest and healthy active single revision. They do not deploy an
image, inspect registry source labels or establish Graph execution by themselves.

Use an existing current-owner 0600 aggregate request ledger for that exact HTTPS
origin. Initialize it only once, offline, with the **measured** previous attempt
count; initialization refuses to overwrite an existing ledger. For the retained
target's last recorded seven attempts, the example is:

```sh
python3 tools/directory_request_ledger.py --initialize-offline \
  --ledger "$(pwd)/.cache/approved-directory/target-request-ledger.local.json" \
  --endpoint https://owner-selected-compatible-bff.example \
  --observed-prior-attempts 7
```

Replace the origin and history with the actual approved target and current
evidence. Never reset the counter to zero or create a second ledger to evade its
40-request aggregate cap. The native proof requires four remaining reservations
before any owner login. The ledger is process-locked and binds the exact origin.

With the owner present and after hosting/identity approval:

```sh
python3 tools/native_entra_auth.py --owner-assisted --manual-start \
  --input-dir .cache/approved-customer \
  --directory-manifest .cache/approved-directory/native-proof.local.json
```

The default target is Mac. An attended emulator or final physical Android run
additionally requires its exact device selection and installation authorization
shown above; connected alone is not authorization. The selected customer receipt
is explicit, not the default historical workforce receipt.

The sequence independently verifies the initial selected API JWT, reads actual
BFF capabilities, obtains one authenticated `register` challenge, and requests
isolated `freshIdentityProof` with that exact target/nonce. API and ID signatures,
distinct audiences, exact signed customer `oid`/`tid`, nonce and integer recent
`auth_time` are checked with the same Go verification used by production.
API/ID `sub` may differ. Fresh API/ID credentials cross only the capability-bound
loopback control and transient verifier stdin; neither becomes a proof file,
argument, asset, log or replacement primary credential. Cancellation fences late
verification before registration. The target compares the primary secure record
before/after proof acquisition, then retains the normal restore/refresh/signout
checks.

The standalone `verify-entra-principal --fresh-proof-stdin` result means
**authentication only**: it verifies the exact *provided* nonce, not server
issuance, Graph, stored challenge consumption or account ownership. The
coordinated control separately establishes server challenge provenance, submits
registration once and verifies the resulting account/session. Existing account
generations remain unchanged by this idempotent ownership resolution; there is
no ownership reset or legacy migration.

The native envelope is four BFF requests, two directory-operation reservations,
one personal-authorization initialization reservation and one fresh pair check,
with zero document mutations. These are logical reservations/acknowledged
responses, not physical CAS attempts, audit-item counts, Graph/issuer HTTP
requests, Cosmos RU or billing. Challenge/proof/audit/ownership state may remain
after failure. An ambiguous submitted write stops without retry or a rollback
claim. Graph, directory and personal data remain separate transactions.

The redacted receipt also binds source, configuration, hosting candidate, endpoint
and aggregate history. `rawFreshProofPersisted=false` does not mean historical
`initial.jwt`/`refresh.jwt` API captures are absent. Their grant proposals remain
unapplied and must not become directory authorization inputs.
This target does not prove ordinary application data UI or hosted Cosmos CRUD.
The separately bounded [directory SDK target](developer-onboarding.md#directory-acceptance-tooling)
consumes the recently completed native receipt and its original API credential;
actual customer/native/SPA/cloud acceptance remains #24, with physical work #20.
