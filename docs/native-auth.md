# Native end-user authentication

The runnable sample is `examples/flutter_app`. Its native login adapter uses
`flutter_appauth` 12.1.0 on Android, iOS and macOS. AppAuth performs Authorization
Code with PKCE and validates its browser callback/state/nonce; Android uses an
external browser/Custom Tab and Apple platforms use the native web authentication
session. The sample sends no client secret and never uses an embedded WebView.
The plugin does not provide web, Linux or Windows login in this sample.
See [AppAuth Android](https://github.com/openid/AppAuth-Android),
[AppAuth iOS/macOS](https://github.com/openid/AppAuth-iOS) and the
[Flutter adapter](https://pub.dev/packages/flutter_appauth).

## Register a public client and the API

The owner must choose the OIDC provider/tenant, configure native **public-client**
redirects and grant the test user access. These actions require the owner's
provider access; the repository does not create registrations or consent on
their behalf. No access, refresh or ID token should be pasted into an Issue.

For Microsoft Entra ID, prepare a tenant-specific API registration and a separate
native public-client registration. Expose a delegated API scope such as
`api://<API-application-id>/Cosmos.Sync`, authorize the native client to request
it, and choose the intended consent policy. Request `openid offline_access` and
that API scope. Configure the BFF's issuer and audience to match the API access
token's actual tenant/version and `aud`; the native client ID is not the API
audience. A Microsoft Graph access token is not a BFF credential. See Microsoft's
[Authorization Code/PKCE flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow)
and [scope documentation](https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc).
The [dedicated Entra setup](entra-setup.md) provides the reviewed two-app,
single-tenant proposal, exact callback, v2 API audience and per-user consent bodies.

Provide the following non-secret values in the app's connection form:

| Value | Meaning |
| --- | --- |
| BFF URL | Owner-approved HTTPS deployment endpoint |
| Issuer | Exact tenant-specific OIDC issuer |
| Client ID | Registered native public-client ID |
| Redirect URL | Exact registered native redirect; default `com.anaregdesign.cosmossync:/oauthredirect` |
| Scopes | `openid`, optional identity scopes, `offline_access`, and the BFF's delegated API scope |
| Optional discovery URL | HTTPS discovery document on the issuer's origin; otherwise derived from issuer |
| Optional logout redirect | Exact registered native post-logout URL, such as `com.anaregdesign.cosmossync:/logout` |

The redirect **scheme** must match the build's Android manifest placeholder and
Apple `CFBundleURLTypes`. Changing it in the form alone cannot register an OS
callback. The checked-in callback is a demonstration default; confirm the native
provider registration accepts it before login. Production products should choose
their own application identifiers and review claimed HTTPS app/universal links
if the provider supports them. The current adapter accepts private native schemes.
Provider consent does not grant Cosmos document access: BFF server grants remain
the separate tenant/user/role authority described in [security.md](security.md).

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

Run `flutter test test/auth` for offline unit/security regressions. They cover
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
