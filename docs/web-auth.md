# Web end-user authentication

The ordinary `examples/flutter_app` Web target shares the native application's
UI, auth controller, BFF transport and cache-ownership policy. It uses pinned
`@azure/msal-browser` 5.24.0, bundled locally with esbuild 0.28.2. Native AppAuth,
secure credential restore and SQLite behavior remain separate and unchanged.
Actual Google/Apple connections are outside this delivery; the current reference
does not advertise unconfigured navigation capabilities. This is not a global
provider-name denylist.

## Actual OIDC compatibility boundary

The BFF/SDK and native OIDC configuration remain provider-neutral, with Entra
External ID as the preferred consumer broker. This supplied **Web adapter is
Entra-specific**: its parser requires Microsoft/CIAM hosts, a UUID tenant/v2.0
path and UUID client, then constructs an MSAL authority. It is not yet a generic
browser OIDC client. [#40](https://github.com/anaregdesign/cosmos-sync/issues/40)
tracks that source-level gap; removing only the host checks would not implement
a safe generic protocol flow.

Apple/Google can be upstream methods of the configured Entra broker without a
provider-name API denial. Every deployment still needs the dedicated API JWT
issuer/audience/scope and current server authorization. Neither that generic API
contract nor the Web adapter establishes arbitrary social credential linking
through the separate workforce-only directory reader.

## Public-client setup and build

Use the selected API-token Entra/External ID contract. Configure an exact tenant
issuer, public client ID and the delegated Cosmos Sync API scope. No client
secret, Graph data permission, raw token input or custom BFF token issuer is
needed. The BFF still verifies the API JWT's signature, issuer, audience and
scope, then supplies the principal and current server-managed authorization.
Provider account IDs, navigation hints, emails and client partitions do not
establish data ownership.

Register a separate **SPA** redirect, preserving the existing native redirect:
`https://<app-origin>/<base-path>/auth-redirect.html`. Local development may use
literal loopback HTTP, for example `http://localhost:8765/auth-redirect.html`.
Protocol, host, port and path must exactly match the bridge resolved from the
document base URL. The issuer/discovery pair is pinned to a concrete tenant;
`common`, arbitrary discovery hosts and a different callback origin are rejected.

From `examples/flutter_app`:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm test
npm run build:auth
flutter pub get
flutter run -d chrome --web-port=8765
# Production compilation only; this does not deploy or publish.
flutter build web --no-pub --no-web-resources-cdn
```

Deploy both locally bundled auth scripts, their legal notices and
`auth-redirect.html` with the normal Flutter output. The separate redirect page
uses MSAL's supported response bridge; it must not load the Flutter app or be
served with a `Cross-Origin-Opener-Policy` header that severs its parent channel.
Register the exact page origin in the BFF's `allowedOrigins`, not a wildcard.
The popup must be allowed. Full-page sign-in redirects are not supported by this
memory-only adapter. See [MSAL redirect bridge](https://learn.microsoft.com/en-us/entra/msal/javascript/browser/redirect-bridge).

## Credentials and durable cache

MSAL performs authorization code/PKCE and retains its account/token cache only
in memory. The ordinary adapter exports the API access token, type, expiry and granted
scopes, never a refresh token, ID token or provider account identifier. Silent
renewal uses the same MSAL account and forces renewal. State changes, cancellation,
local signout and controller close invalidate late callbacks and clear SDK
memory; initialization, popup, renewal and cleanup waits are bounded. Failures
expose fixed error categories rather than provider URLs, claims or token data.

Public connection preferences and a bounded registry of application-owned,
hashed database names use localStorage. Documents, pending operations and SDK
session/cursor metadata use IndexedDB. API/ID/refresh credentials never enter
either store. A fresh document has no verified offline-cache index or credential
binding. It must interactively sign in and verify `/session` online before
reusing a persisted cache. Reload therefore retains the locked durable outbox
without granting offline access to a newly signed-in identity. Within one
verified document lifetime, ordinary offline work remains available.

Cache selection hashes connection settings and the **BFF-verified**
principal/scope/mode. The registry accepts only the application's own bounded
namespace and hash shape. Registry changes and database ownership use Web Locks;
unsupported storage, a busy other tab, corruption or blocked deletion fail
explicitly. There is no volatile fallback, foreign-database enumeration or
origin-wide deletion. Explicit signout drains in-flight work and purges owned
caches before clearing credentials. Learned terminal auth/session denial also
purges authority and cache. Offline clients cannot discover remote revocation.

## Isolated account-lifecycle proofs

Verified directory capabilities enable a dedicated fresh-proof popup path using
a separate MSAL instance and private memory cache. It requests the server nonce,
`prompt=login`, `max_age=0` and essential `auth_time`, and exports an API/ID pair
only through that ephemeral proof method. It never selects/replaces the main
active account or persists either proof/refresh credential. Cleanup and logical
cancellation fence late responses; fixed failures do not expose provider details.
Ordinary sign-in/renewal still exports no ID token or account identifier.

The shared application confirms unsent-data loss, drains/purges before obtaining
proofs and checks account/generation/credential before opening IndexedDB.
Ambiguous submitted results and removal of the active credential require new
online sign-in with a remaining linked identity. A reload does not preserve proof
authority or create recovery by email. Native and SPA callbacks can share one
approved public client/namespace, but that mixed registration must be verified
before deployment. Actual MSAL/customer nonce/authentication-time issuance remains
unverified; local JS/Chromium checks do not establish it.

The BFF uses bearer headers, not ambient auth cookies or token-bearing URLs.
Exact-origin CORS is not authentication. MSAL owns login state/nonce/PKCE; no
backend cookie-session/CSRF redesign is introduced. Memory-only credentials do
not prevent same-origin XSS from accessing an active session or unencrypted
document storage. Apply the application's reviewed hosting/CSP policy and
data/backup requirements; browser storage can also be evicted or deleted.

## Measured evidence and remaining gates

Node adapter tests exercise the actual pinned MSAL constructor configuration and
deterministic popup/renewal/error/late-callback behavior. Chromium tests exercise
Dart JS interop, memory auth and actual IndexedDB/Web Locks. The separate
`tools/flutter_web_smoke.py` drives the ordinary UI with a test-only signed
issuer adapter, actual Go HTTP/JWT validation, a separately observed full page
reload, exact pending-operation retention, refused offline rebind, BFF online
rebind, server ACK and logout purge. Ordinary `main.dart` contains no fixture
authentication switch.

These checks do not prove live MSAL/customer OIDC, hosted Azure/Cosmos, other
browsers, third-party-cookie restrictions or physical mobile-browser behavior.
Those results must be recorded separately in
[#28](https://github.com/anaregdesign/cosmos-sync/issues/28),
[#29](https://github.com/anaregdesign/cosmos-sync/issues/29) and
[#24](https://github.com/anaregdesign/cosmos-sync/issues/24).
