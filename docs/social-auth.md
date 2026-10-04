# Apple and Google end-user authentication

Apple and Google are the intended consumer login options for Cosmos Sync.
The Go BFF and Dart SDK remain the data and authorization boundary. This is a
development roadmap, not a claim that the current preview implements either
provider. The existing native OIDC adapter and verified Microsoft Entra API-token
flow remain useful enterprise integration and security evidence; they do not
prove Apple or Google login. See [native authentication](native-auth.md) and
[the Entra live verification runbook](native-auth-live.md).

## Recommended architecture

### Current owner-directed delivery scope, 2026-10-04

The owner cancelled actual Google/Apple connections, federation configuration,
credential operations and their manual live-provider acceptance. Issue
[#30](https://github.com/anaregdesign/cosmos-sync/issues/30) is **not planned**,
not passed. Google/Apple project/team access, test logins, keys and provider
rotation are no longer prerequisites for this delivery. The provider-specific
setup and matrix below are future reference, not instructions to perform them.
Keep both capability flags disabled; preserve typed local adapters and
deterministic identity/security regressions.

The owner subsequently moved physical verification to the final Android-only
gate. Continue native/browser and simulator development first. Actual External
ID/common OIDC, hosted Cosmos acceptance and the trusted linking/authorization
contract remain required by their active Issues. The recorded real Entra login
used a workforce tenant; it does not prove CIAM login, upstream-provider control
or broker self-service enforcement. Simulation cannot establish those facts.

Use an identity broker for consumer login, then require a credential specifically
accepted by the Cosmos Sync API. Keep authorization and stable data ownership in
the BFF. **Do not configure the existing sync endpoints to accept Apple or Google
ID tokens by removing the API audience/scope checks.** A Google API access token,
an Apple provider access token, or a client-decoded identity claim is also not a
Cosmos Sync credential.

The owner selected **Microsoft Entra External ID in a separate external tenant**,
federating Apple and Google through browser-delegated login.
This preserves the current Authorization Code/PKCE public-client model and a
dedicated BFF access-token audience/scope. Microsoft documents both social
providers, and explicitly limits their use to browser-delegated authentication;
its native authentication feature currently supports local accounts. The
existing workforce validation tenant must not be silently repurposed as the
consumer directory. With the owner's subsequent Azure/tenant authorization, the
new CIAM directory and linked billing resource were created successfully; its
private readback confirms the selected domain, United States geography and CIAM
tenant type. The dedicated consumer API/native registrations, service principals
and API-only delegated administrator consent are complete. Anonymous discovery
and native issuer/discovery-origin configuration checks passed. Provider settings,
the associated user flow and actual consumer login remain unverified. Actual
Google/Apple project/team setup and credentials are excluded from the current
delivery. The [External ID setup record](external-id-setup.md)
records creation status, the selected registration/callback contract, costs and
remaining settings. This is not an enabled or verified social-login deployment.
[External ID authentication methods](https://learn.microsoft.com/en-us/entra/external-id/customers/concept-authentication-methods-customers).
API registration must expose the intended scope and preserve the resource-server
token checks; an external tenant is not a reason to accept a native client ID
token at the BFF.
[Expose a web API](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-configure-app-expose-web-apis).

| Option | API trust boundary | Work and selection gate |
| --- | --- | --- |
| Entra External ID broker, selected | Reviewed login at broker → PKCE public client → API-specific access JWT → BFF identity mapping and current grants | Prove issuer, API scope, subject stability, explicit linking and callback behavior. Keep one exact trusted issuer per deployment. Actual Google/Apple federation is outside current scope. |
| Firebase Authentication / Google Cloud Identity Platform broker | Native/web provider login → broker ID token → dedicated BFF identity exchange → Cosmos Sync API session/access token | Good candidate for native provider UI and Flutter integration. Implement a separate exchange, session revocation and signing-key lifecycle; do not pretend the broker's project-audience ID token is an existing API access token. Disable email-driven account merging and test the broker configuration. |
| Direct Apple/Google integration | Server validates provider login/code proof → server-owned account → dedicated Cosmos Sync API session/access token | Requires ownership of provider-specific code exchange, nonce/replay handling, refresh/revocation and signing/session operations. Use only if broker constraints cannot meet the product's requirements. |

Firebase documents ID-token verification against its project ID and
`https://securetoken.google.com/<projectId>` issuer. Its Admin SDK verification
and revocation checks belong at an explicit identity-proof boundary, with only
configured projects accepted. Firebase authentication does not require storing
application data in Firestore; Cosmos remains behind the BFF.
[Firebase token verification](https://firebase.google.com/docs/auth/admin/verify-id-tokens).

Proceed with External ID preparation while proving the account-linking policy,
browser UI, macOS support, operating cost and owner-approved data handling. The
other options remain fallbacks if those gates fail. An exchange is required for
the Firebase/direct options; an additional custom token issuer is unnecessary
for the External ID API-token option. None of these options grants direct Cosmos
access to an app.

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

### Selected linking contract (production activation not implemented)

The implementation contract for the future dedicated link/unlink boundary is:

| Rule | Selected bound and behavior |
| --- | --- |
| Challenge | Server-generated 256-bit random value; persist its SHA-256 digest with a 300-second lifetime, never a reusable plaintext credential |
| Binding | Bind account, current BFF session generation, operation, approved issuer/provider/client namespace and exact callback to the transaction; independently bind the new identity proof to that challenge |
| Freshness | At commit, require verified reauthentication within 300 seconds for the existing account and independent fresh control of the new identity; refresh, `iat` and a client-supplied timestamp do not prove reauthentication |
| Commit and replay | Atomically consume the unexpired challenge, enforce unique verified `(issuer, subject, namespace)` ownership, preserve the application account/data owner and append audit metadata; retries cannot assign twice |
| Existing owner | Reject an identity already assigned to another account; email matches never merge accounts or transfer ownership |
| Unlink | Require the same recent authentication, preserve a verified remaining login/recovery method, atomically remove the binding and advance the BFF session generation; invalidate any future BFF refresh family and separately verify broker revocation behavior |

Challenge consumption, identity uniqueness and account mapping need one reviewed
transactional boundary. Cosmos transactional batches cover one logical partition;
they do not make identity rows in different partitions globally atomic. Use one
intentional identity-directory partition or a separately reviewed transactional
store before implementation. Keep its capacity/cost and contention limits
explicit. Never move documents as an incidental part of linking.

Only a dedicated identity-proof endpoint may handle upstream login proof; sync
APIs continue to require API access JWTs. The broker must provide trustworthy
binding and authentication-time evidence, and its direct SDK/self-service linking
must not bypass this transaction. If either cannot be established, linking stays
disabled. The [staged internal identity-directory core](identity-directory.md) now exercises
this transactional model with a bounded, single-record Cosmos adapter and
explicitly labeled internal proof-stamp tests. It is disconnected from production
factories and routes. Trusted upstream/fresh-auth proof, broker self-service
enforcement, production session/cursor/cache wiring, production capacity and
recovery remain activation gates. This chosen contract adds no endpoints, Graph
write grants, active session generations, custom refresh families or broker-wide
linking controls to the published preview.
[Cosmos transaction scope](https://learn.microsoft.com/en-us/azure/cosmos-db/nosql/transactional-batch).

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
self-access and fixed-owner shared membership. Production cross-provider linking and
legacy-data migration remain **unimplemented**. Migration requires an explicit
mapping of old scope IDs, retained journal and receipt integrity,
permission-version changes, cursor invalidation/resync and a policy for pending
edits. Never use a provider-wide audience or issuer as shared-tenant membership.
The selected server-managed authorization mode still decides every read/write.

For the selected External ID path, the current built-in account identifies the
**broker's API-token subject**, not the upstream Apple/Google subject. It cannot
detect an upstream provider being attached to an unchanged broker identity.
The reviewed Microsoft documents establish federation and directory identities,
but do not establish a no-email-auto-link guarantee for this deployment. Treat
equal-email isolation and self-service linking behavior as acceptance gates;
do not claim the BFF's lack of email matching proves the broker's behavior.
Changing the API application or issuer also requires an explicit ownership
migration because its subject namespace can change. See the
[setup identity boundary](external-id-setup.md#account-and-linking-boundary).

## Current token contract

The selected first External ID integration reuses the existing BFF verifier and
native AppAuth or separate [Web MSAL adapter](web-auth.md). Directory creation alone does not prove that an actual
consumer token or callback meets this contract.

| Boundary | Current preview behavior |
| --- | --- |
| Signature | Explicit allowlist `RS256`, `RS384`, `RS512`, `ES256`, `ES384`, `ES512`; no HMAC, unsigned or arbitrary token-supplied key endpoint |
| API identity | Configured issuer, configured API audience present in `aud`, signature and expiry; optional `nbf` must be a valid integer no later than the BFF clock; exact required scope in whitespace-separated `scp`/`scope`; nonempty subject; `token_use` checked only when configured; optional configured client admission requires exact signed `azp` |
| Missing checks | No production `iat`/`auth_time` freshness, local maximum JWT lifetime or per-request upstream session-revocation lookup. The staged core does not supply provider verification or activate these checks on sync routes |
| Discovery | Trusted configured issuer discovery is needed to construct the verifier; the default HTTP timeout is 10 seconds, while an explicitly supplied HTTP client keeps its own timeout |
| JWKS | Pinned `go-oidc` v3.16.0 retains cached keys without a TTL or proactive refresh. Cache verification failure, including an unknown `kid`, triggers one remote fetch with shared in-flight suppression. There is no cross-request fetch cooldown or automatic retry loop |
| Native login | Pinned `flutter_appauth` 12.1.0 delegates state, nonce, S256 PKCE and system-browser callback handling to platform AppAuth; the BFF verifies the separate API JWT and receives no login nonce |
| Native credentials | Access token remains in RAM; refresh credential and the optional logout ID-token hint use platform secure storage. The controller refreshes before the provider expiration with a 30-second margin; restore must rebind through the existing verified BFF/session policy |
| Web login/credentials | Locally bundled MSAL Browser 5.24.0 handles popup code/PKCE through an exact same-origin SPA redirect bridge. Account/refresh credentials stay in MSAL memory; only the API access response reaches Dart. A new document must sign in and verify the BFF online before reopening persisted IndexedDB |

If a required discovery/key fetch or signature/claim check fails, authentication
fails. During a JWKS outage, a token which still verifies with cached keys can
remain accepted until expiry; cached keys are not purged on outage. A removed
remote key is not discovered proactively while cached verification succeeds.
Missing/inactive BFF data grants are checked separately on requests and event
revalidation. None of this promises instantaneous upstream logout or key
revocation. [Current BFF](../bff/security.go),
[pinned verifier](https://github.com/coreos/go-oidc/blob/v3.16.0/oidc/verify.go),
[pinned key cache](https://github.com/coreos/go-oidc/blob/v3.16.0/oidc/jwks.go),
[native adapter](../examples/flutter_app/lib/auth/native_oidc.dart),
[session controller](../examples/flutter_app/lib/auth/auth_session_controller.dart).

The new External ID access-token TTL, refresh lifetime and remote-signout delay
are **unmeasured**. Record safe scalar lifetime/denial observations from actual
consumer tests; a workforce run cannot establish them. There is no configured
maximum credential age. For an already-issued token, its own expiry bounds local
JWT acceptance, but broker refresh can extend access until the broker rejects
it. No finite overall provider-revocation delay has been established. Local
signout drains/purges the app's state and clears credentials; optional provider
logout needs a registered return and is separate from revocation on other
devices. An offline device cannot learn remote revocation immediately.

## Additional adapter and session acceptance

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

## Future provider-specific platform reference

The owner removed the actual Apple/Google acceptance below from this delivery.
Retain the matrix for any future separately authorized provider rollout, not as
a current blocker. Passing Entra, signed-fixture, simulator or offline SDK tests
does not establish these future provider-specific results. Current physical
verification is Android-only and deferred until development is complete.

| Platform | Registration/adapter work | Real-provider acceptance |
| --- | --- | --- |
| iOS | External ID browser PKCE with the registered native callback; Apple broker registration requires its own developer-team approval. Native provider SDK capabilities/signing would be a separate change. | Signed physical-device return, consent/cancel/deny, Apple private relay, refresh/re-auth, app termination/restart, offline reconnect and purge. The owner chose unsigned testing, so build/simulator evidence remains separate from physical-device acceptance. |
| Android | External ID browser PKCE with exact native callback. The Google client for federation is a broker Web application; Android signing fingerprints apply only if a direct native Google SDK is later selected. | Pixel login/callback, browser/account switching, cancellation, reinstall, refresh/revocation and authenticated offline outbox replay. |
| Web | The ordinary sample has a separate memory-only MSAL popup adapter, exact SPA bridge and BFF-verified IndexedDB lifecycle; no Web AppAuth or full-page login redirect. | Signed-fixture UI/reload/rebind/purge evidence does not prove live provider login, popup denial, restricted third-party storage, back navigation or mobile browsers. |
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
Entra path and BFF authorization regressions. A future real-provider rollout must
also cover relay/name omission, consent revocation, account deletion,
reinstall/relogin and separate principals. Additional test-account and signing access needs a
concrete owner approval; single-account evidence cannot prove isolation between
two actual provider accounts.

## Future provider settings and operations gate

No Google/Apple setup or credentials are requested for the current delivery.
If that cancelled scope is later restored, first present the exact
broker/project/tenant, app IDs, redirects,
provider scopes, data handling, cost and secrets storage to the owner. Ask for
specific approval to create/update Google OAuth clients and consent/test-user
settings, and Apple App ID/Services ID/Sign in with Apple keys/capabilities.
Current authorization for unsigned Apple builds does not authorize Apple portal
or signing changes. Do not infer these permissions from Azure resource approval.
The owner performs browser sign-in/MFA/consent; never send secrets through chat.
External-tenant consent differs from the workforce test. The current dedicated
API/native registration contract and API-only admin grant fall within the
owner's Azure/tenant authorization, with existing normal access and verified
readback. Do not add Microsoft Graph data access because a walkthrough contains
a default permission, or silently expand CLI OAuth scopes. The owner completes
any needed browser login/MFA when the specific operation is ready.
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
5. [#30: Actual Google/Apple provider setup and acceptance](https://github.com/anaregdesign/cosmos-sync/issues/30) is cancelled by the owner as not planned; it is no longer a blocking prerequisite. Physical Android acceptance remains the separate final gate in [#20](https://github.com/anaregdesign/cosmos-sync/issues/20).

External ID is selected and its dedicated directory has been created. The
registration contract, current token behavior and bounded future linking design
are recorded above. Actual Google/Apple provider registrations and live
verification are outside current scope; no paid add-on is authorized.
[The setup record](external-id-setup.md) preserves their future reference
requirements. Design completion and provider cancellation do not close the
remaining implementation, common OIDC, cloud or final Android Issues.
