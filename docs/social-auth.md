# Apple and Google end-user authentication

Apple and Google are the intended consumer login options for Cosmos Sync.
The Go BFF and Dart SDK remain the data and authorization boundary. This is a
development roadmap, not a claim that the current preview implements either
provider. The existing native OIDC adapter and verified Microsoft Entra API-token
flow remain useful enterprise integration and security evidence; they do not
prove Apple or Google login. See [native authentication](native-auth.md) and
[the Entra live verification runbook](native-auth-live.md).

## Recommended architecture

Use an identity broker for consumer login, then require a credential specifically
accepted by the Cosmos Sync API. Keep authorization and stable data ownership in
the BFF. **Do not configure the existing sync endpoints to accept Apple or Google
ID tokens by removing the API audience/scope checks.** A Google API access token,
an Apple provider access token, or a client-decoded identity claim is also not a
Cosmos Sync credential.

The first integration candidate is **Microsoft Entra External ID in a separate
external tenant**, federating Apple and Google through browser-delegated login.
This preserves the current Authorization Code/PKCE public-client model and a
dedicated BFF access-token audience/scope. Microsoft documents both social
providers, and explicitly limits their use to browser-delegated authentication;
its native authentication feature currently supports local accounts. The
existing workforce validation tenant must not be silently repurposed as the
consumer directory. This is a recommendation based on the current architecture,
not an approved tenant creation or a completed integration.
[External ID authentication methods](https://learn.microsoft.com/en-us/entra/external-id/customers/concept-authentication-methods-customers).
API registration must expose the intended scope and preserve the resource-server
token checks; an external tenant is not a reason to accept a native client ID
token at the BFF.
[Expose a web API](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-configure-app-expose-web-apis).

| Option | API trust boundary | Work and selection gate |
| --- | --- | --- |
| Entra External ID broker, first candidate | Apple/Google login at broker → PKCE public client → API-specific access JWT → BFF identity mapping and current grants | Configure a consumer external tenant and both providers; prove issuer, API scope, subject stability, explicit linking and callback behavior. Keep one exact trusted issuer per initial deployment. |
| Firebase Authentication / Google Cloud Identity Platform broker | Native/web provider login → broker ID token → dedicated BFF identity exchange → Cosmos Sync API session/access token | Good candidate for native provider UI and Flutter integration. Implement a separate exchange, session revocation and signing-key lifecycle; do not pretend the broker's project-audience ID token is an existing API access token. Disable email-driven account merging and test the broker configuration. |
| Direct Apple/Google integration | Server validates provider login/code proof → server-owned account → dedicated Cosmos Sync API session/access token | Requires ownership of provider-specific code exchange, nonce/replay handling, refresh/revocation and signing/session operations. Use only if broker constraints cannot meet the product's requirements. |

Firebase documents ID-token verification against its project ID and
`https://securetoken.google.com/<projectId>` issuer. Its Admin SDK verification
and revocation checks belong at an explicit identity-proof boundary, with only
configured projects accepted. Firebase authentication does not require storing
application data in Firestore; Cosmos remains behind the BFF.
[Firebase token verification](https://firebase.google.com/docs/auth/admin/verify-id-tokens).

Choose the final broker after the design Issue proves the account-linking policy,
desired native versus browser UI, macOS support, operating cost and owner-approved
data handling. An exchange is required for the Firebase/direct options; an
additional custom token issuer is unnecessary for the External ID API-token
option. None of these options grants direct Cosmos access to an app.

## Identity, linking and data ownership

Implement an immutable, server-generated application `accountId`. Map each
verified external identity using the exact `(issuer, subject)` tuple plus its
approved broker/project/client namespace. Provider identifiers obtained through
a broker must come from trusted server verification or an authorized broker
administration API, never client `providerData` or an email lookup. Preserve
provider identity records separately from the broker identity and application
account. Google specifies `sub` as its stable identifier; email can change.
[Google server verification](https://developers.google.com/identity/gsi/web/guides/verify-google-id-token).

Email, display name and Apple private relay addresses are profile/contact data.
They must not create grants, select a partition, or automatically merge accounts.
Apple may return a name only during initial authorization, and reinstalling an
app does not create a new provider identity. Persist optional profile information
without making it a login prerequisite.
[Apple authentication](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple).
Private relay contact and association with identifying information require the
appropriate consent and relay configuration.
[Apple with Firebase](https://firebase.google.com/docs/auth/ios/apple).

Linking requires an explicit action, recent authentication for the existing
account, separate proof of control of the new identity, a short-lived single-use
link transaction, and server-side uniqueness/concurrency checks. Reject a new
identity already owned by another account; account/data merges are a separate,
reviewable operation. Unlink requires recent authentication, session invalidation
and a remaining usable login/recovery method. Do not migrate documents or lose
the account ID when switching providers.

Broker configuration is part of this guarantee. Firebase documents trusted
provider behavior, and Identity Platform offers separate accounts per provider
as well as manual linking. Test matching verified emails across providers before
accepting a configuration; application code alone cannot undo an unsafe implicit
broker merge.
[Firebase federation](https://firebase.google.com/docs/auth/flutter/federated-auth),
[Identity Platform linking](https://docs.cloud.google.com/identity-platform/docs/link-accounts).
The policy must also cover direct broker SDK/self-service link and unlink calls.
A broker UID must not gain access through a newly attached provider that bypassed
the approved recent-authentication/link transaction. Prove this with the broker's
configuration and trusted server-side identity-binding checks, including direct
SDK mutation attacks. A safe BFF button alone does not enforce that boundary.

The legacy BFF mode derives its personal partition from verified issuer, tenant
and subject. The opt-in [built-in authorization mode](authorization.md) now
provides a durable account directory keyed by verified issuer/subject, personal
self-access and fixed-owner shared membership. Cross-provider linking and
legacy-data migration remain **unimplemented**. Migration requires an explicit
mapping of old scope IDs, retained journal and receipt integrity,
permission-version changes, cursor invalidation/resync and a policy for pending
edits. Never use a provider-wide audience or issuer as shared-tenant membership.
The selected server-managed authorization mode still decides every read/write.

## Token and session requirements

These are acceptance requirements for new adapters, not new production endpoints:

- Validate signatures with a provider-specific algorithm allowlist, trusted
  discovery/key endpoints, exact issuer and configured client/API audience,
  expiry and applicable `iat`/`nbf`, token purpose and nonempty subject. Require
  the API scope on Cosmos Sync access JWTs; validate Firebase/Google/Apple ID
  proofs against their project/client audience and authentication evidence,
  without expecting `Cosmos.Sync` in a provider ID token. Pin approved
  clients/projects; do not fetch an arbitrary URL supplied by a token. Test
  cached JWKS rotation, unknown `kid`, outages and bounded retries.
- Bind login to fresh state and nonce; use PKCE for applicable authorization-code
  public-client flows and exact redirects. Apple native nonce hashing and broker
  SDK behavior differ; follow the selected SDK's documented contract. Validate
  the nonce at the responsible server/broker boundary. Google's OIDC flow
  documents state and nonce validation; Apple describes server session binding
  and identity-token verification.
  [Google OIDC](https://developers.google.com/identity/openid-connect/openid-connect),
  [Apple token verification](https://developer.apple.com/documentation/signinwithapple/verifying-a-user).
- For an exchange, use bounded server-issued transactions, verify fresh proof
  and reject reuse of codes/link transactions across replicas. Define how repeated
  bearer identity proofs are detected, including a shared proof-digest replay
  ledger or equivalent reviewed design. Nonce/PKCE protects login transactions;
  it does not make a stolen bearer API/identity token impossible to replay.
  Do not claim proof-of-possession without implementing and testing it.
- Issue only short-lived API credentials with a dedicated audience, stable
  account identity and explicit session purpose. If issuing refresh credentials,
  keep only hashes server-side, rotate atomically, detect reuse and revoke the
  session family. Define expiration, key overlap, maximum revocation delay and
  replica propagation before implementation. Check current grants independently
  of cached token roles on every request and notification revalidation.
- Keep access tokens in RAM and secrets out of SQLite, logs, URLs and Issues.
  Provider SDK persistence must be reviewed per platform. Restore does not prove
  current authorization. Bind cache reopening to the existing BFF-verified
  account/config/credential session; a new interactive login requires online
  verification before opening old data. Learned terminal authentication or grant
  denial must stop work and purge the local cache/outbox. A disconnected client
  cannot learn remote revocation immediately.
- Separate local signout, BFF session revocation, provider logout/disconnection,
  unlink and account deletion. Drain/purge local state before deleting credentials;
  test failures and late callbacks. Firebase ID-token signature verification
  alone does not check revoked sessions. Apple consent/account notifications
  need signature/audience verification and idempotent event handling; disabling
  relay email is a contact change, not a reason to transfer data ownership.
  [Firebase session management](https://firebase.google.com/docs/auth/admin/manage-sessions),
  [Apple account notifications](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts).

## Platform and verification matrix

All entries below are planned Apple/Google acceptance work. Passing current
Entra, signed-fixture, simulator or offline SDK tests does not complete them.

| Platform | Registration/adapter work | Real-provider acceptance |
| --- | --- | --- |
| iOS | Select broker browser PKCE or native Apple/Google SDK flow; review bundle IDs, exact callback, Apple capability/entitlements and signing. | Signed physical-device return, consent/cancel/deny, Apple private relay, refresh/re-auth, app termination/restart, offline reconnect and purge. Unsigned build/simulator evidence remains separate. |
| Android | Google package/certificate fingerprints for each approved build variant; Apple broker/system-browser Services ID return; exact native callback. | Pixel login/callback, browser/account switching, cancellation, reinstall, refresh/revocation and authenticated offline outbox replay. |
| Web | New web login adapter and runnable web sample; exact origins and HTTPS returns, popup/redirect recovery and CSRF protection; review persistence/XSS exposure. | Real browsers with popup denial, restricted third-party storage, reload/back navigation, account switching and offline IndexedDB purge. The current native sample has no web AppAuth adapter. |
| macOS | Confirm selected broker/native SDK support, bundle callbacks and Keychain behavior. Firebase macOS setup calls for Keychain Sharing, unlike the present local legacy-Keychain sample. | Actual provider return, approved signing/capabilities where required, restart/restore, cancel/deny and revoke/purge. Do not infer this from current Entra success. |

Firebase's Flutter guide documents Apple and Google provider flows, native versus
web differences and explicit reauthentication. Its setup guide lists platform
prerequisites, including macOS Keychain Sharing.
[Flutter federation](https://firebase.google.com/docs/auth/flutter/federated-auth),
[Flutter platform setup](https://firebase.google.com/docs/flutter/setup).

Automated CI must cover wrong issuer/audience/client/project, expired/future
tokens, algorithm/key confusion, nonce/state mismatch, code/proof replay, key
rotation, duplicate provider subjects across namespaces, equal-email isolation,
link races/re-auth failure, late callback after logout, refresh reuse, provider
outages and cross-account cursor/cache/outbox isolation. Preserve the existing
Entra path and BFF authorization regressions. Real-provider acceptance must also
cover relay/name omission, consent revocation, account deletion, reinstall/relogin
and separate principals. Additional test-account and signing access needs a
concrete owner approval; single-account evidence cannot prove isolation between
two actual provider accounts.

## Owner settings and operations gate

Before external setup, present the exact broker/project/tenant, app IDs, redirects,
provider scopes, data handling, cost and secrets storage to the owner. Ask for
specific approval to create/update Google OAuth clients and consent/test-user
settings, and Apple App ID/Services ID/Sign in with Apple keys/capabilities.
Current authorization for unsigned Apple builds does not authorize Apple portal
or signing changes. Do not infer these permissions from Azure resource approval.
The owner performs browser sign-in/MFA/consent; never send secrets through chat.
External-tenant consent differs from the current workforce test. Any required
API-only admin consent or client preauthorization needs a new, exact proposal;
do not add Microsoft Graph data access just because a registration walkthrough
contains a default permission.
[Application registration and external-tenant consent](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app?toc=/entra/external-id/toc.json&bc=/entra/external-id/breadcrumb/toc.json).

Apple federation requires an approved developer team, app/Services ID and private
key; External ID's Apple instructions describe the client-secret renewal cycle.
Google federation requires an approved Google project, client and secret.
Store secrets only in the chosen broker/secret manager with limited operators;
document rotation, expiry alerts, rollback, revocation events and account deletion
recovery. Client configuration identifiers can be public; private keys, client
secrets, refresh credentials and account details cannot.
[External ID Apple setup](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-apple-federation-customers),
[External ID Google setup](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-google-federation-customers).

The [publication epic](https://github.com/anaregdesign/cosmos-sync/issues/2) tracks
the dependent work:

1. [#26: Choose the broker and token trust boundary](https://github.com/anaregdesign/cosmos-sync/issues/26).
2. [#27: Implement stable accounts, explicit linking and BFF session/authorization mapping](https://github.com/anaregdesign/cosmos-sync/issues/27), after the design decision.
3. [#28: Implement and validate Flutter provider/platform adapters](https://github.com/anaregdesign/cosmos-sync/issues/28), against that server contract.
4. [#29: Add automated security regression evidence](https://github.com/anaregdesign/cosmos-sync/issues/29), alongside server/client implementation.
5. [#30: Complete owner-approved real-provider, platform and credential operations acceptance](https://github.com/anaregdesign/cosmos-sync/issues/30), after the portable checks and concrete account-setting approvals.

Provider registrations, paid identity services and live provider verification
remain pending their concrete owner settings and approvals.
