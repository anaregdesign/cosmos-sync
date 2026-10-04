# Native end-user authentication

Apple and Google are the intended practical end-user login providers. This page
describes the implemented native OIDC API-access-token adapter and its opt-in
External ID provider navigation; the dedicated workforce Entra validation does
not establish an actual Apple/Google login. The
[social-login design](social-auth.md) covers their additional trust boundary,
identity linking, platform requirements and acceptance work.

The owner removed actual Google/Apple provider setup and live connections from
this delivery on 2026-10-04. Their buttons remain disabled; typed local adapter
and security tests stay in scope. Development now uses simulators, with physical
Android verification last. Actual CIAM/common OIDC and linking safety remain
separate from the successful workforce Entra login.

The runnable sample is `examples/flutter_app`. Its native login adapter uses
`flutter_appauth` 12.1.0 on Android, iOS and macOS. AppAuth performs Authorization
Code with PKCE and validates its browser callback/state/nonce; Android uses an
external browser/Custom Tab and Apple platforms use the native web authentication
session. The sample sends no client secret and never uses an embedded WebView.
The plugin does not provide Web, Linux or Windows login. The ordinary app now
selects a separate [MSAL Browser adapter](web-auth.md) for its Web target;
native callbacks and secure restore are not reused in the browser.
See [AppAuth Android](https://github.com/openid/AppAuth-Android),
[AppAuth iOS/macOS](https://github.com/openid/AppAuth-iOS) and the
[Flutter adapter](https://pub.dev/packages/flutter_appauth).

## Apple and Google broker navigation

The sample supports typed Google/Apple navigation through the same AppAuth
Authorization Code with PKCE flow. Microsoft documents
[`domain_hint=google` and `domain_hint=apple`](https://learn.microsoft.com/en-us/entra/external-id/customers/concept-authentication-methods-customers#issuer-acceleration)
for External ID issuer acceleration. The adapter sends that single additional
parameter only on the interactive authorization request. Refresh, logout and
Cosmos Sync requests receive no provider preference, extra scopes or provider
credentials. This hint directs browser navigation; it is not verified provider
identity, a link request or a data permission.

Provider buttons are hidden by default. After enabling each provider on the
native client's associated External ID user flow and verifying real login,
operators can supply this **public build configuration** in a local
`broker-capabilities.json` file:

```json
{
  "COSMOS_SYNC_ENTRA_BROKER_CAPABILITIES": "{\"version\":1,\"issuer\":\"https://YOUR-TENANT-ID.ciamlogin.com/YOUR-TENANT-ID/v2.0\",\"clientId\":\"YOUR-NATIVE-PUBLIC-CLIENT-ID\",\"providers\":[\"google\",\"apple\"]}"
}
```

```sh
cd examples/flutter_app
flutter run --dart-define-from-file=/absolute/path/broker-capabilities.json
```

Advertise only the providers actually enabled and verified for that application.
The JSON parser accepts version 1 and only the issuer/client/provider fields;
unknown providers, duplicate or empty lists, embedded credentials and invalid
HTTPS origins are rejected with fixed errors. The current capability validator
supports `*.ciamlogin.com` issuers with a tenant path; branded custom domains
need a separately reviewed extension. The issuer and native client ID must match
the form exactly before Google/Apple buttons appear. Changing either field hides
them. A caller requesting an unavailable provider fails before browser launch or
credential replacement. Saved connection preferences cannot enable provider
buttons; only the current operator-supplied build configuration does.

The generic **Save and sign in** button remains available and sends no hint.
All sign-in buttons share the existing busy/cancellation lifecycle. A late
callback after cancellation cannot activate credentials or reopen a cache.
The preference is excluded from stored credential/cache bindings: every new
interactive login still generates a new credential session and requires a
BFF-verified owner before cache access. Buttons do not enforce which identity
provider the broker ultimately used. There is no direct Google/Apple SDK, custom
token exchange, account linking or provider-ID-token admission in this adapter.
The current consumer deployment has not yet configured or verified either
provider, so its capability flags must remain disabled.

## Future Apple and Google deployment reference

The first integration candidate is a consumer identity broker that federates
Apple/Google login and issues an access token for the Cosmos Sync API. Microsoft
[Entra External ID](https://learn.microsoft.com/en-us/entra/external-id/customers/concept-authentication-methods-customers)
supports these providers through browser-delegated authentication; it requires
an external consumer tenant and reviewed configuration, separate from the
current workforce-tenant validation. If native provider UI is required,
Firebase Authentication/Identity Platform plus a dedicated backend identity
proof exchange is the alternative under review. This recommendation is a design
proposal, not an enabled provider deployment. The selected dedicated CIAM tenant,
two consumer app registrations and their service principals now exist, with
API-only administrator consent and compatible public discovery/configuration
readback. Actual Google/Apple configuration is not planned for this delivery.
User-flow association and actual common CIAM login remain unverified; see
[the reproducible External ID setup](external-id-setup.md).

An Apple/Google or broker **ID token** proves authentication to its intended
relying party; it must not replace the API access token expected by existing
sync routes. The selected design must validate its issuer/audience, signature
and rotating keys, nonce/challenge/replay policy and flow-specific PKCE/state,
then establish a separate API credential/session and current BFF permissions.
A broker-issued dedicated API access JWT supplies that credential directly,
without an additional custom BFF token issuer. Firebase/direct ID proofs require
the separate backend exchange.
Provider identities use verified `(issuer, sub)`; application account and data
ownership IDs must remain stable across explicit link/unlink with recent
reauthentication. Email, including Apple private-relay addresses, is an attribute
and must never automatically merge accounts. Broker defaults need verification:
the [Firebase Flutter guide](https://firebase.google.com/docs/auth/flutter/federated-auth)
documents trusted-provider automatic account changes, while
[Identity Platform account linking](https://docs.cloud.google.com/identity-platform/docs/link-accounts)
describes multiple-account configuration and explicit linking.
Broker SDK/self-service linking must not bypass a recent-authenticated BFF link
transaction or gain data access through an unchanged broker user ID; trusted
server-side identity bindings and adversarial direct-SDK tests are required.

The English Issues distinguish local implementation and automated tests from
real provider/platform acceptance:

- Trust boundary and broker decision: [#26](https://github.com/anaregdesign/cosmos-sync/issues/26).
- Stable accounts, linking, API sessions and cache policy: [#27](https://github.com/anaregdesign/cosmos-sync/issues/27).
- Flutter provider adapters and platform matrix: [#28](https://github.com/anaregdesign/cosmos-sync/issues/28).
- Automated attack/lifecycle regressions: [#29](https://github.com/anaregdesign/cosmos-sync/issues/29).
- Actual Google/Apple provider setup and acceptance: [#30](https://github.com/anaregdesign/cosmos-sync/issues/30), cancelled by the owner as not planned and no longer a prerequisite.
- Final physical Android acceptance: [#20](https://github.com/anaregdesign/cosmos-sync/issues/20), deferred until simulator development is complete.

Apple Developer/Google Cloud/broker registrations, signing or server credentials,
new consent/scopes and paid resources require concrete owner approval before
changes. The owner has already authorized the selected dedicated consumer
tenant's necessary settings, and its native-to-API `AllPrincipals` consent for
only `Cosmos.Sync` is verified. It adds no Graph data permissions or client
preauthorization. Workforce consent/configuration remains separate. No Google/Apple
owning account or credential input is requested for this delivery. Current one-account
verification and unsigned iOS choices remain in
force. The ordinary Flutter app now has a separate MSAL/IndexedDB Web target
and actual signed-fixture Chromium lifecycle evidence, not live customer OIDC.
Cancellation/denial, reinstall/relogin, account
switch/linking, refresh/revocation and offline-cache isolation need automated
coverage. Any claimed actual common-provider/platform result requires separate
recorded evidence; Google/Apple live evidence is outside current scope.

## Register a public client and the API

For a new deployment, the owner chooses the OIDC provider/tenant, configures
native **public-client** redirects and grants the intended API permission using
authorized provider access. These settings are not created automatically by the
app or BFF. No access, refresh or ID token should be pasted into an Issue.

The existing workforce validation completed actual one-account macOS AppAuth
PKCE, secure restore and provider refresh. The separate consumer CIAM setup has
completed two apps/two service principals and API-only consent; only anonymous
discovery and the actual Flutter constructor have passed there. It has no
associated customer user flow or verified consumer login. Each BFF deployment
pins one exact issuer and API audience; selecting the consumer configuration does
not add workforce token acceptance or migrate workforce cache/data ownership.

For Microsoft Entra ID, prepare a tenant-specific API registration and a separate
native public-client registration. Expose a delegated API scope such as
`api://<API-application-id>/Cosmos.Sync`, authorize the native client to request
it, and choose the intended consent policy. Request `openid offline_access` and
that API scope. Configure the BFF's issuer and audience to match the API access
token's actual tenant/version and `aud`; the native client ID is not the API
audience. A Microsoft Graph access token is not a BFF credential. See Microsoft's
[Authorization Code/PKCE flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow)
and [scope documentation](https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc).
The [workforce Entra setup](entra-setup.md) records its two-app, single-tenant
contract and per-user consent bodies. The [consumer External ID setup](external-id-setup.md)
records the separately applied admin-only scope, API-specific `AllPrincipals`
consent, six reproducible Graph operations and deployment settings.

Provide the following non-secret values in the app's connection form:

| Value | Meaning |
| --- | --- |
| BFF URL | Owner-approved HTTPS deployment endpoint |
| Issuer | Exact tenant-specific OIDC issuer |
| Client ID | Registered native public-client ID |
| Redirect URL | Exact registered native redirect; default `com.anaregdesign.cosmossync://auth/oauthredirect` |
| Scopes | `openid`, optional identity scopes, `offline_access`, and the BFF's delegated API scope |
| Optional discovery URL | HTTPS discovery document on the issuer's origin; otherwise derived from issuer |
| Optional logout redirect | Exact registered native post-logout URL, such as `com.anaregdesign.cosmossync:/logout` |

For the selected consumer tenant, use the issuer and discovery URL from the
verified **tenant-ID-host** metadata response. Its domain-alias discovery returned
an issuer on a different origin; the current Flutter constructor rejects that
combination. Matching origins and constructor success prove configuration
compatibility only, not authentication or API-token admission. Consumer examples
are in [ops/entra/consumer](../ops/entra/README.md#consumer-external-tenant).

The redirect **scheme** must match the build's Android manifest placeholder and
Apple `CFBundleURLTypes`. Changing it in the form alone cannot register an OS
callback. The checked-in callback is a demonstration default; confirm the native
provider registration accepts it before login. Production products should choose
their own application identifiers and review claimed HTTPS app/universal links
if the provider supports them. The current adapter accepts private native schemes.
Provider consent does not grant another account's data. In built-in mode, a
correctly verified API access token establishes the caller's personal scope;
shared access additionally requires owner-managed membership. Legacy mode
retains explicit server grants. These data permissions are enforced independently
of provider roles, as described in [authorization](authorization.md).

## Credential and cache lifecycle

`AuthSessionController.accessToken()` returns only an explicit Bearer access token
with more than 30 seconds remaining and the requested API scopes when the provider
reports granted scopes. No JWT is decoded to infer cache ownership or permissions;
the BFF verifies the JWT and establishes the application's session identity.
An ID token is only an optional provider logout hint.

Access tokens live in RAM. A single secure record contains a refresh token, an
optional ID token, exact public configuration and a random `credentialSessionId`.
The ID changes on every successful interactive login. The app binds a previously
**BFF-verified** cache owner to that opaque ID; a new interactive login must obtain
a new BFF session before opening any previous cache. Restoring the secure record
does not contact the network or claim current authorization. It permits explicit
offline access only to the existing verified binding. Remote revocation cannot be
learned while disconnected; learned BFF denial and terminal refresh denial require
the app to stop work and purge the cache.

The secure adapter uses `flutter_secure_storage` 11.2.0. iOS requests unlocked,
device-bound Keychain items. The local-only macOS sample uses the legacy Keychain
(`usesDataProtectionKeychain: false`) to avoid sharing/provisioning requirements;
do not infer iOS device-bound guarantees for that macOS legacy mode. Apple iCloud
synchronization is disabled. Android uses the plugin's Keystore-backed default encryption. OS keystore behavior
and device compromise remain outside this sample's guarantees. Secure writes and
deletions are read back; this detects silent plugin failures but does not promise
cross-process transactions or hardware-level persistence after abrupt power loss.
No credentials enter SQLite, ordinary preferences, Issues or diagnostics. See
[secure storage](https://pub.dev/packages/flutter_secure_storage) and
[Keychain accessibility](https://pub.dev/documentation/flutter_secure_storage/latest/flutter_secure_storage/KeychainAccessibility.html).

Refresh requests are single-flight, including synchronous state-notification
listeners that request another token. Sign-in publishes its active flight before
notifying listeners, and credential restore is limited to configured signed-out
startup with no active authentication or restore operation. Terminal deletion
retains its active flight until cleanup completes, so notification listeners
cannot reload the credential being removed. Rotated refresh credentials are saved before
the new access token is returned; an omitted refresh token retains the previous
one. An outage preserves the offline binding. Structured `invalid_grant`,
`interaction_required`, `login_required` or `consent_required` errors remove it
immediately, notify the application and delete stored credentials. An explicit
response scope list omitting the requested API scope is also terminal
(`api_scope_denied`); it does not retain the offline cache binding like an outage.
Native/provider
exception descriptions are never displayed or logged because they can contain
tokens and account details. Fixed application error codes explain the next action.

The app must block editing, await `CosmosSyncClient.signOut()` to stop/drain/purge,
close its SDK client, and then await `AuthSessionController.signOut()` to delete
credentials. A deletion failure is reported and must be retried. Optional provider
end-session happens after local deletion; browser logout is provider-dependent and
does not revoke already issued tokens or BFF grants. Cancelling an interactive
login invalidates late callbacks and drains/deletes a concurrent secure write;
the user dismisses the native browser because this plugin has no portable dismissal
API. Disposing the controller clears RAM and prevents late activation while
preserving the stored credential for an ordinary app restart.

## Native build and live verification

The app's platform files configure the default callback, iOS Keychain
entitlements, network client access, and Android backup exclusions. No macOS
Keychain Sharing entitlement is needed for its local legacy mode. Apple native
startup disables shared `URLCache` token-response caching. Review the platform
files if changing application IDs, redirect schemes or signing teams.

Run `flutter test test/auth test/ui_test.dart test/app_lifecycle_test.dart` for
offline unit/security regressions. They additionally cover typed provider
request parameters, exact capability binding, hidden/default buttons,
unavailable-provider rejection, cancellation/late callbacks and BFF-established
cache ownership during a Google/Apple navigation switch. These use simulated
provider and BFF responses. Actual Google/Apple registration/login is cancelled
in #30, not proven; native/browser development remains in #28 and final physical
Android acceptance in #20. Existing regressions cover
refresh concurrency/rotation and synchronous listener reentry, missing access
tokens, cancellation during a secure
write, late authorization/refresh completion after logout, config/account binding,
provider logout failure and explicit secure-storage failure. These tests use
injected OAuth and secure-store adapters; they are not evidence of a real provider
login or hardware Keychain callback.

Before release the owner must supply the registration/consent/BFF configuration,
sign in through the OS browser, and allow authorized physical devices to be
connected. Verify first login, cancellation, callback return, API audience/scope,
refresh and process restart, offline edit/reconnect, account switch, server grant
revocation and local purge on each supported platform. Track this evidence in
[Issue #18](https://github.com/anaregdesign/cosmos-sync/issues/18), with physical
device evidence in [#20](https://github.com/anaregdesign/cosmos-sync/issues/20)
and live Azure integration in [#24](https://github.com/anaregdesign/cosmos-sync/issues/24).
