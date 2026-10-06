# Flutter Cosmos Sync sample

This is a usable Android/iOS/macOS/Web application. Ordinary `flutter run` opens
connection and sign-in settings, then a document workspace. It uses the real
`HttpSyncTransport` and shared UI/controllers. Native targets use app-private
SQLite, AppAuth authorization code + PKCE and OS secure storage. Web uses
IndexedDB/Web Locks and maintained MSAL Browser with memory-only credentials.
It is separate from the deterministic SDK-only
[`flutter_smoke`](../flutter_smoke/README.md) fixture.

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

The sample's deployment targets are Android API 24+, iOS 15+, and macOS 12+.
These are build targets, not a claim that every supported OS version was tested.
No Windows or Linux app target is provided. Web requires a secure context,
IndexedDB and Web Locks; measured browser support is Chromium, not every browser.

For the ordinary Web target, build the pinned local authentication assets first:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm test
npm run build:auth
flutter run -d chrome --web-port=8765
```

Register the exact SPA callback shown in the settings form, for example
`http://localhost:8765/auth-redirect.html` for loopback development or an HTTPS
production origin. This is separate from the native custom-scheme callback.
The BFF must allow that exact page origin. See [Web authentication](../../docs/web-auth.md)
for popup/redirect-bridge deployment and credential/cache lifecycle.

Signing is for local development only. The checked-in Android release build
uses the debug signing key; macOS local builds use ad-hoc signing, and no iOS
development team is configured. These are not app-store distribution artifacts.
The owner's unsigned iOS build choice produces a compilation artifact, not an
installable physical iPhone application.

Apple and Google are the intended end-user login providers. This version uses
native OIDC/PKCE and an API-specific access token, with the dedicated Entra path
used for validation. Default-disabled provider navigation and unpublished opt-in
account-lifecycle UI are implemented; actual provider/platform acceptance is
tracked in the [social-login roadmap](../../docs/social-auth.md)
and [Epic #2](https://github.com/anaregdesign/cosmos-sync/issues/2).
These source paths are not live support claims. The owner cancelled actual Google/Apple
connections for this delivery; keep both capability flags disabled. The selected
External ID broker/API-token boundary keeps raw provider ID tokens away from sync routes;
email matching must never automatically link accounts. Provider registrations,
credentials and signing changes need the owner's concrete approval.

## Connect a real account

The owner must first approve/register a public native OIDC client and BFF API,
configure the BFF's issuer/audience/delegated API scope and authorization mode,
and supply an HTTPS BFF endpoint. See [native auth setup](../../docs/native-auth.md)
and the [dedicated Entra proposal](../../docs/entra-setup.md), plus
[Azure operations](../../docs/azure-operations.md) for the remaining account gates.

Enter the BFF URL, OIDC issuer URL, public client ID, and space-separated scopes
including `openid`, your delegated BFF API scope, and normally `offline_access`.
The default callback is `com.anaregdesign.cosmossync://auth/oauthredirect`. The exact
callback must be registered with the provider. Its scheme is registered in all
three native platform projects; changing it requires a corresponding build
configuration change. The sample has no client-secret or token-input field.

These settings configure the implemented API-token OIDC path. Pasting an Apple
or Google client ID/issuer into the form does not add social login or make its ID
token a BFF credential. Use a reviewed provider/broker integration when the
roadmap implementation and actual acceptance are complete.

On native, `Save and sign in` opens the system browser. The adapter uses the returned access
token for the BFF; it never substitutes an ID token. The BFF's verified `/session`
establishes the principal and personal/shared scope before the cache is opened.
With the BFF's built-in authorization, `Personal` registers a private account
scope without a grants file. To open an existing shared workspace, its fixed
owner first grants your registered account reader/writer using the
[typed SDK management API](../../packages/cosmos_sync/README.md#personal-and-shared-authorization).
Build the sample with the returned non-secret scope ID:

```sh
flutter run -d macos --dart-define=COSMOS_SYNC_SHARED_SCOPE_ID=<bff-issued-scope-id>
```

The sample then shows a fixed `Shared workspace (owner-provided)` selection.
Its verified session must match that ID and current membership; selecting an ID
cannot grant access or select an arbitrary Cosmos partition. Changing the build's
shared selection requires online verification; a prior personal/other-scope cache
cannot reopen offline. `Legacy tenant scope` is the separate grant-file mode,
and is unavailable when a shared workspace is configured. Membership management
has an SDK example; the sample does not provide invitations or an owner admin UI.

After a saved session is restored, use `Connect online` or `Open verified cache
offline`. Offline reopening requires both an existing BFF-verified cache and the
same opaque credential-session binding from OS secure storage. A fresh
interactive sign-in rotates that binding and requires another online BFF session
verification. Restoring/opening offline does not refresh a token or decode JWT
claims. The next online request refreshes an access token as needed.

On Web, ordinary sign-in uses a popup and provider-managed code/PKCE. That path exports
only the API access token; refresh credentials stay inside MSAL memory. Reloading
the page signs out and retains the locked IndexedDB outbox, but cannot restore
credentials or open the cache offline. Sign in again and complete online BFF
verification before reopening that principal's cache. Offline reopening is
available only within the already verified document lifetime.

## Opt-in account lifecycle

A compatible directory-mode BFF advertises verified capabilities before the
application shows registration/link/unlink/recovery actions. Legacy/builtin
deployments do not acquire those capabilities automatically. The retained Azure
image is unchanged, so this source UI is not yet hosted customer acceptance.

Before registration or an identity change, the app confirms pending-data loss,
drains requests and purges its owned workspace caches. Cancelling confirmation
retains the exact pending operation and submits no challenge. Explicit consent
may lose local pending edits; server-owned documents and shared ownership are
not moved or deleted. Actions are disabled offline, while busy or without an
approved fresh-proof adapter.

Native AppAuth and a separate memory-only MSAL instance request the server nonce,
fresh login and essential authentication time. The dedicated proof method returns
an ephemeral API/ID pair; it never replaces the main API/refresh credential,
selects a new main account or writes either proof into secure storage/SQLite/
IndexedDB. Ordinary Web token exports still contain no ID or refresh token.
Native cancellation fences late results logically; dismiss the system browser
as well.

A successful response still requires a fresh matching BFF account/generation/
credential session before reopening data. Submitted-but-ambiguous outcomes and
unverifiable new sessions sign out rather than replaying the proof. Removing the
active credential also signs out. Recovery clears local state and uses normal
online sign-in with a remaining linked credential, never email matching or
replacement registration. The last credential cannot be removed; account
deletion/migration have no self-service endpoint.
See [the directory contract](../../docs/identity-directory.md).

## Edit and synchronize

Create, edit or delete JSON documents in the workspace. A completed local save
means SQLite or IndexedDB durably accepted the operation. `Pending` remains visible until a
server ACK; a successful local save does not claim that Cosmos DB was updated.
`Work offline` stops automatic watching/polling. A request already in progress
may finish. Reconnect to fetch durable server changes and replay due writes. SSE
change hints have polling fallback; app resume also requests synchronization.

Conflicts stay visible in the pending list. `Keep local and retry` explicitly
creates a new operation against the observed server version. `Use server`
discards that operation and reveals the confirmed state; later queued edits to
the document are preserved. Delete conflicts can explicitly retry the deletion.
Rejected operations show their code and can be discarded. Unattempted operations
may also be discarded. Attempted writes with an unknown outcome cannot be
discarded: their exact operation ID must be replayed.

HTTP 507 scope capacity failures retain the exact pending operation and its
backoff deadline. The UI shows the code and retry time. The operator must resolve
capacity; the app does not silently rebase, replace the operation, or loop
immediately. The BFF remains the authority for read/write permissions.

Sign out confirms how many pending edits will be lost. The application blocks
new work, drains in-flight SDK requests, purges all owned workspace caches, and
then removes secure/native or memory/browser credentials. Terminal credential refresh failure also hides
and purges the workspace. Server authorization failures use the SDK's immediate
revocation latch and purge behavior. Revocation cannot be observed while a device
is offline, so offline access remains available until the next verification.

## Storage and platform details

Non-secret connection settings are saved in the app support directory. Cache
filenames hash the BFF endpoint/settings and BFF-verified principal/scope; they
contain no raw token or client-selected partition. SQLite document data is
plaintext in the OS app-private directory. Device/OS security and any backup
policy must match the data sensitivity; this sample is not an encrypted database.
On Web, localStorage holds only public connection settings and a bounded registry
of hashed, application-owned database names. IndexedDB holds documents/outbox and
SDK session/cursor metadata, not access, refresh or ID credentials. The verified
cache index and credential-session binding remain in memory.

Refresh credentials remain in native secure storage; access tokens remain in
memory. iOS uses this-device-only, non-synchronizing Keychain settings. macOS uses
the local legacy Keychain without sharing entitlements/provisioning, explicitly
disables synchronization, and does not claim the iOS this-device-only guarantee.
The adapter verifies secure writes/deletes by reading them back. Android disables
cloud/device-transfer backups. Apple URLCache is disabled before native auth
startup so token responses are not retained by a shared disk/memory URL cache.

Network policy allows HTTPS and explicitly opted-in loopback HTTP development.
It never enables arbitrary plaintext BFF or insecure OIDC connections. An
Android emulator can use a selected `adb reverse tcp:<port> tcp:<port>` mapping to
loopback; `10.0.2.2` is intentionally outside the transport's loopback exception.
No iOS development team is committed. Physical-device installation, signing,
Developer Mode, real account consent, Azure resources and public distribution
require owner-selected access and approvals.

## Recorded verification

On 2026-10-03, Flutter 3.44.6 / Dart 3.12.2 on macOS arm64 passed static analysis
and the app's unit/widget suite. The native integration runner also passed on
macOS against the real Go HTTP BFF and a disposable RSA/JWKS test issuer:

```sh
FLUTTER_BIN=/path/to/flutter python3 tools/flutter_app_smoke.py --device macos
```

Run that command from the repository root. The integration target drives visible
configuration/login actions through a test-only OIDC adapter, actual HTTP and
SQLite. It validates creation/edit/deletion, offline pending writes and app
restart, reconnect ACK, both explicit conflict choices, tombstones, sign-out
purge, and a write/read/delete of its own isolated native secure-storage key.
The signed JWT is fetched from a disposable loopback control endpoint; only its
URL is compiled into the test target. Ordinary `main.dart` selects native AppAuth or Web MSAL and has no test
authentication bypass.

This proves native UI/storage and BFF protocol integration. It does **not** prove
a real provider's system-browser login, live Azure grants/managed identity, or
physical-device deployment. Those owner-dependent checks remain open in
[Issue #20](https://github.com/anaregdesign/cosmos-sync/issues/20), and
[Issue #24](https://github.com/anaregdesign/cosmos-sync/issues/24).

The separate ordinary Web fixture uses the same UI/controllers, actual Go
RSA/JWKS-validated HTTP and real Chromium IndexedDB. It observes a full document
reload, exact outbox retention, failed offline rebind, online BFF rebind, ACK and
logout purge:

```sh
python3 tools/flutter_web_smoke.py --output artifacts/flutter-web-fixture.json
```

Run from the repository root with a fresh ignored receipt path. Its OIDC adapter
is compiled only into the integration target. It proves browser application
lifecycle, not live MSAL login, CIAM customer identity or hosted Azure/Cosmos.

The 2026-10-05 directory-lifecycle checkpoint passed 99 native unit/widget tests,
24 actual Chromium tests and 19 Node/MSAL tests with clean analysis/format.
It covers registration/link/unlink/recovery, explicit pending-loss confirmation
and cancellation, primary-credential preservation, signout/close during proof,
ambiguous outcomes and expected-identity rejection before cache open. Provider
responses remain fixtures; actual CIAM nonce/integer `auth_time`, hosted reader/
Cosmos and final physical Android acceptance remain separate gates.
