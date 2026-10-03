# Native Flutter Cosmos Sync sample

This is a usable Android/iOS/macOS application. Ordinary `flutter run` opens
connection and sign-in settings, then a document workspace. It uses the real
`HttpSyncTransport`, app-private SQLite, native AppAuth authorization code + PKCE,
and OS secure storage. It is separate from the deterministic SDK-only
[`flutter_smoke`](../flutter_smoke/README.md) fixture.

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

The sample's deployment targets are Android API 24+, iOS 15+, and macOS 12+.
These are build targets, not a claim that every supported OS version was tested.
No Flutter web, Windows or Linux app target is provided; the SDK's separate
browser tests do not validate this native authentication application.

Signing is for local development only. The checked-in Android release build
uses the debug signing key; macOS local builds use ad-hoc signing, and no iOS
development team is configured. These are not app-store distribution artifacts.
The owner's unsigned iOS build choice produces a compilation artifact, not an
installable physical iPhone application.

## Connect a real account

The owner must first approve/register a public native OIDC client and BFF API,
configure the BFF's issuer/audience/delegated API scope and server-side grants,
and supply an HTTPS BFF endpoint. See [native auth setup](../../docs/native-auth.md)
and the [dedicated Entra proposal](../../docs/entra-setup.md), plus
[Azure operations](../../docs/azure-operations.md) for the remaining account gates.

Enter the BFF URL, OIDC issuer URL, public client ID, and space-separated scopes
including `openid`, your delegated BFF API scope, and normally `offline_access`.
The default callback is `com.anaregdesign.cosmossync://auth/oauthredirect`. The exact
callback must be registered with the provider. Its scheme is registered in all
three native platform projects; changing it requires a corresponding build
configuration change. The sample has no client-secret or token-input field.

`Save and sign in` opens the system browser. The adapter uses the returned access
token for the BFF; it never substitutes an ID token. The BFF's verified `/session`
establishes the principal and personal/shared scope before the cache is opened.
Selecting shared tenant scope requests only the server-authorized tenant mode,
not an arbitrary partition or tenant identifier.

After a saved session is restored, use `Connect online` or `Open verified cache
offline`. Offline reopening requires both an existing BFF-verified cache and the
same opaque credential-session binding from OS secure storage. A fresh
interactive sign-in rotates that binding and requires another online BFF session
verification. Restoring/opening offline does not refresh a token or decode JWT
claims. The next online request refreshes an access token as needed.

## Edit and synchronize

Create, edit or delete JSON documents in the workspace. A completed local save
means SQLite durably accepted the operation. `Pending` remains visible until a
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
new work, drains in-flight SDK requests, purges all workspace cache files, and
then removes secure credentials. Terminal credential refresh failure also hides
and purges the workspace. Server authorization failures use the SDK's immediate
revocation latch and purge behavior. Revocation cannot be observed while a device
is offline, so offline access remains available until the next verification.

## Storage and platform details

Non-secret connection settings are saved in the app support directory. Cache
filenames hash the BFF endpoint/settings and BFF-verified principal/scope; they
contain no raw token or client-selected partition. SQLite document data is
plaintext in the OS app-private directory. Device/OS security and any backup
policy must match the data sensitivity; this sample is not an encrypted database.

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
URL is compiled into the test target. Ordinary `main.dart` always uses native
AppAuth and has no test authentication bypass.

This proves native UI/storage and BFF protocol integration. It does **not** prove
a real provider's system-browser login, live Azure grants/managed identity, or
physical-device deployment. Those owner-dependent checks remain open in
[Issue #18](https://github.com/anaregdesign/cosmos-sync/issues/18),
[Issue #20](https://github.com/anaregdesign/cosmos-sync/issues/20), and
[Issue #24](https://github.com/anaregdesign/cosmos-sync/issues/24).
