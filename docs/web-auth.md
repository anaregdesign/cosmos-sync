# Web end-user authentication

The ordinary `examples/flutter_app` Web target shares the native application's
UI, auth controller, BFF transport and cache-ownership policy. Its explicit
adapters use pinned `@azure/msal-browser` 5.24.0 for Entra and `oidc-client-ts`
3.5.0 plus `jose` 6.2.12 for generic OIDC, bundled locally with esbuild 0.28.2. Native AppAuth,
secure credential restore and SQLite behavior remain separate and unchanged.
Actual Google/Apple connections are outside this delivery; the current reference
does not advertise unconfigured navigation capabilities. This is not a global
provider-name denylist.

## Actual OIDC compatibility boundary

The BFF/SDK and native OIDC configuration remain provider-neutral, with Entra
External ID as the preferred consumer broker. The Web form now explicitly selects
**Entra / External ID (MSAL)** or **Generic OIDC (Code + PKCE)**. Existing saved
settings retain the Entra default. Its Microsoft/CIAM hosts, UUID tenant/v2.0 and
UUID-client restrictions remain adapter-specific, not a global issuer policy.
The generic adapter accepts an operator-configured HTTPS issuer and same-origin
HTTPS discovery, visible non-UUID public-client identifier and dedicated API
scopes. [#40](https://github.com/anaregdesign/cosmos-sync/issues/40) records its
source and actual standards-fixture acceptance; new source is not an update to
the previously published/retained runtime.

Apple/Google can be upstream methods of the configured Entra broker without a
provider-name API denial. Every deployment still needs the dedicated API JWT
issuer/audience/scope and current server authorization. Neither that generic API
contract nor the Web adapter establishes arbitrary social credential linking
through the separate workforce-only directory reader.

## Public-client setup and build

Configure an exact issuer, browser-capable public client and delegated Cosmos
Sync API scope for the selected adapter. Entra uses its registered SPA contract.
Generic OIDC requires Code/S256, browser CORS at its token/discovery/JWKS endpoints
and an issuer which actually provides a dedicated API JWT; ordinary Google/Apple
ID tokens or opaque/unrelated OAuth access tokens are not that credential. No client
secret, Graph data permission, raw token input or custom BFF token issuer is
needed. The BFF still verifies the API JWT's signature, issuer, audience and
scope, then supplies the principal and current server-managed authorization.
Provider account IDs, navigation hints, emails and client partitions do not
establish data ownership.

Register a separate **SPA** redirect, preserving the existing native redirect:
`https://<app-origin>/<base-path>/auth-redirect.html` for Entra or
`https://<app-origin>/<base-path>/oidc-redirect.html` for generic OIDC. Local
development may use literal loopback HTTP, for example
`http://localhost:8765/oidc-redirect.html`.
Protocol, host, port and path must exactly match the bridge resolved from the
document base URL and selected adapter. Generic discovery must publish that exact
issuer and trusted HTTPS authorization/token/JWKS endpoints. Entra additionally
requires a concrete tenant and its standard discovery path; `common` is rejected.
Neither adapter accepts a different callback origin or arbitrary discovery host.

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

Deploy the locally bundled auth scripts, their legal notices and both redirect
pages with the normal Flutter output. The pages use the selected library's
supported popup response bridge; they must not load the Flutter app or be
served with a `Cross-Origin-Opener-Policy` header that severs its parent channel.
Register the exact page origin in the BFF's `allowedOrigins`, not a wildcard.
The popup must be allowed. Full-page sign-in redirects are not supported by this
memory-only adapters. See [MSAL redirect bridge](https://learn.microsoft.com/en-us/entra/msal/javascript/browser/redirect-bridge)
and [oidc-client-ts](https://github.com/authts/oidc-client-ts).

## Credentials and durable cache

Both adapters retain account/token/transaction state only in memory and export
the API access token, type, expiry and granted API scopes, never a refresh token,
ID token or provider account identifier. Entra renewal uses the same MSAL account
and forces renewal. Generic renewal requires its own memory refresh credential
and the same verified subject; no credential means explicit interactive sign-in,
not an invisible iframe or persistent-store fallback. Automatic renewal, session
monitoring and user-info fetching are disabled.

Generic login uses Code/S256 with a fresh crypto nonce and memory transaction
store. The OIDC library's decoded profile is not sufficient JWT trust: `jose`
independently verifies the ID signature, pinned issuer/client audience, expiry,
integer times, nonce, applicable authorized party and optional access-token hash
using the trusted HTTPS JWKS and supported RS/ES signing family. A new refresh ID
is checked again; omitted/reused original ID retains the already verified subject
binding, not fresh authentication authority. The BFF independently verifies the
different dedicated API JWT and current data permission before any cache opens.
Changing the adapter/issuer/client/scopes/discovery/callback cannot renew another
configuration's credential or establish a cache owner.

State changes, cancellation,
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

Verified directory capabilities and the selected Entra adapter enable a dedicated fresh-proof popup path using
a separate MSAL instance and private memory cache. It requests the server nonce,
`prompt=login`, `max_age=0` and essential `auth_time`, and exports an API/ID pair
only through that ephemeral proof method. It never selects/replaces the main
active account or persists either proof/refresh credential. Cleanup and logical
cancellation fence late responses; fixed failures do not expose provider details.
Ordinary sign-in/renewal still exports no ID token or account identifier.

The generic browser adapter explicitly does **not** support the current
workforce-federation directory fresh-proof profile. The controller and UI expose
that limitation and block proof acquisition rather than refresh-as-reauthentication,
silent builtin fallback or trusting a generic broker's social linking. This is
an adapter capability, not a provider-name blacklist or weaker API JWT policy.

The shared application confirms unsent-data loss, drains/purges before obtaining
proofs and checks account/generation/credential before opening IndexedDB.
Ambiguous submitted results and removal of the active credential require new
online sign-in with a remaining linked identity. A reload does not preserve proof
authority or create recovery by email. Native and SPA callbacks can share one
approved public client/namespace, but that mixed registration must be verified
before deployment. Actual MSAL/customer nonce/authentication-time issuance remains
unverified; local JS/Chromium checks do not establish it.

The BFF uses bearer headers, not ambient auth cookies or token-bearing URLs.
Exact-origin CORS is not authentication. The selected library owns login
state/PKCE, with the generic adapter's additional signed-ID/nonce validation; no
backend cookie-session/CSRF redesign is introduced. Memory-only credentials do
not prevent same-origin XSS from accessing an active session or unencrypted
document storage. Apply the application's reviewed hosting/CSP policy and
data/backup requirements; browser storage can also be evicted or deleted.

## Measured evidence and remaining gates

Node adapter tests exercise the actual pinned MSAL constructor, real generic ID
cryptography and deterministic popup/renewal/error/late-callback behavior. Chromium tests exercise
Dart JS interop, memory auth and actual IndexedDB/Web Locks. The separate
`tools/flutter_web_smoke.py` drives the ordinary UI with a test-only signed
issuer adapter, actual Go HTTP/JWT validation, a separately observed full page
reload, exact pending-operation retention, refused offline rebind, BFF online
rebind, server ACK and logout purge. Ordinary `main.dart` contains no fixture
authentication switch.

The separate standards fixture uses the **production** generic browser bundle,
supported popup callback and normal Dart `WebOidcClient`, without an injected
API credential:

```sh
# From repository root; use a fresh ignored receipt path.
python3 tools/browser_oidc_smoke.py --output artifacts/browser-oidc-fixture.json
```

Its owned non-Entra HTTPS issuer implements real discovery, one-time code/S256,
nonce and signed JWT/JWKS. Actual protocol counters independently confirm those
requests. Twenty browser stages include ID/API trust denial, state/callback
binding, absent refresh/iframe refusal, renewal without a new ID, subject-switch
denial, popup/token cancellation and provider logout. The ordinary Flutter UI
then uses real API-verified IndexedDB/Web Locks across an independently observed
document reload, another subject's isolated cache, exact retained operation,
online BFF rebind/ACK and logout purge. The fresh owned Chromium profile trusts
only that fixture's generated certificate SPKI and permits automated popups;
no global CA/TLS relaxation or production auth bypass is added. Go separately
verifies PKCE failure, code replay and foreign-callback denial.

These checks do not prove live MSAL/customer OIDC, hosted Azure/Cosmos, other
browsers, third-party-cookie restrictions or physical mobile-browser behavior.
Those results must be recorded separately in
[#28](https://github.com/anaregdesign/cosmos-sync/issues/28),
[#29](https://github.com/anaregdesign/cosmos-sync/issues/29) and
[#24](https://github.com/anaregdesign/cosmos-sync/issues/24).
