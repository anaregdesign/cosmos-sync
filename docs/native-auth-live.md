# Owner-assisted actual Entra validation

Run the actual macOS AppAuth target after the owner-approved dedicated
registrations in [entra-setup.md](entra-setup.md) have been created and read back.
The operator's ignored `.cache/entra-azure` directory contains 0600
`approved-owner.local.json` and `registration-receipt.local.json`. Their actual
tenant/account/application identifiers are never checked into this repository.

```sh
python3 tools/native_entra_auth.py --owner-assisted
```

Set `FLUTTER_BIN`/`GO_BIN` or `--flutter-bin`/`--go-bin` if those tools are not on
PATH. The runner supports macOS here; this command is manual and never performs
CI sign-in. The owner operates the system browser's credentials/MFA and reviews
the new `Cosmos.Sync` permission. The request also includes standard
`openid profile offline_access`; it includes no Microsoft Graph data permission.
The runner does not create registrations, consent grants, users, directory roles,
Azure resources or BFF grants.

The separate native integration target uses the production AppAuth adapter and
OS secure storage. Its high-entropy, loopback-only control URL supplies public
configuration, then receives **only API access JWTs** into exclusive 0600 files
in a new 0700 ignored directory. Neither tokens nor account identities are printed.
Token GET requests, unknown routes, phases and fields are rejected. Provider and
Flutter diagnostics remain in a private local log.

The target performs interactive code/PKCE sign-in, secure-record restoration in
a new controller, real refresh and local sign-out of an isolated random Keychain
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
