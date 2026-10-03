# Dedicated Microsoft Entra ID setup

This is the reviewable proposal for the native Flutter sample and BFF. It creates
two new, single-tenant app registrations in the owner's selected tenant. It does
not reuse another product's registrations. Tenant IDs, account names, user object
IDs, issued tokens and populated manifests belong in local ignored configuration,
not this document or GitHub Issues. No registrations, consent grants or directory
role changes have been executed by preparing these files.

## Proposed changes for approval

| Object | Proposed configuration |
| --- | --- |
| API app registration | **Cosmos Sync BFF API (validation)**; `signInAudience: AzureADMyOrg`; no interactive redirect or client credentials |
| API identifier | `api://<BFF_API_APP_ID>` after Entra assigns the API application/client ID |
| API token format | `api.requestedAccessTokenVersion: 2` |
| Delegated permission | One enabled scope named **Cosmos.Sync**, consent type **Admins and users** (`type: User`) |
| Scope description | Read and write only Cosmos Sync documents authorized by the BFF for the signed-in user |
| Native app registration | **Cosmos Sync Native (validation)**; `signInAudience: AzureADMyOrg`; native public client, Authorization Code + PKCE |
| Native callback | Exact `com.anaregdesign.cosmossync:/oauthredirect` under **Mobile and desktop applications** |
| Native API permission | Only the new API's delegated `Cosmos.Sync` scope; no Microsoft Graph data permissions or application permissions |
| Enterprise applications | Corresponding API and native service principals in the same selected tenant |
| Ownership | The owner's explicitly selected account(s) on both new registrations |
| Consent | Named test users' own consent if tenant policy permits; otherwise an approved administrator grants only those users `Principal` consent |
| BFF authorization | Separate exact `tid` + verified API access-token `sub` grants for approved writer and reader; all other principals denied |

No client secrets, certificates, app roles, preauthorized clients, implicit token
issuance, Web/SPA redirects, tenant-wide consent, group assignments or global
consent-policy changes are included. Cosmos/Azure RBAC is a separate infrastructure
approval; this delegated permission never exposes Cosmos credentials.

Microsoft documents single-tenant account selection and separate API scopes. The
scope is an admission check; the BFF still enforces tenant/user grants, role,
permission version and partition boundaries.
See [register an app](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)
and [expose an API](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-configure-app-expose-web-apis).

## Registration bodies and identifiers

The non-executable, placeholder-only JSON bodies in [ops/entra](../ops/entra)
make the proposed object changes inspectable:

1. [api-create.example.json](../ops/entra/api-create.example.json) creates the API
   registration with a new scope UUID. Record its returned application `appId`
   and object `id` separately.
2. [api-identifier-update.example.json](../ops/entra/api-identifier-update.example.json)
   sets the new API's identifier after its `appId` exists.
3. [native-create.example.json](../ops/entra/native-create.example.json) creates
   the native registration using the API `appId` and that exact scope UUID.
4. [service-principal-create.example.json](../ops/entra/service-principal-create.example.json)
   describes the corresponding service principal for each application **only if
   it was not already provisioned by the registration path**.
5. [principal-consent.example.json](../ops/entra/principal-consent.example.json)
   describes optional administrator consent for one named user, after separate
   consent approval. Repeat only for explicitly approved test users.

These files have no runner and cannot be submitted unchanged. Do not run a broad
application inventory or grant new CLI/Graph permissions to fill them. Inspect
only the two new objects and owner-selected user IDs after authorized access.
Record the returned object IDs locally so retries inspect the intended objects
rather than create duplicates by display name. Application `appId` is the public
client ID; application `id` is its directory object ID. A service principal has
another object `id`. Consent uses **service principal object IDs**, not app IDs.
See [application schema](https://learn.microsoft.com/en-us/graph/api/resources/application?view=graph-rest-1.0)
and [delegated grant schema](https://learn.microsoft.com/en-us/graph/api/resources/oauth2permissiongrant?view=graph-rest-1.0).

The native body's `publicClient.redirectUris` selects the installed-client
callback. `isFallbackPublicClient` remains false: that property is a fallback
when Entra cannot determine the client type, such as a password flow without a
redirect. It is not the PKCE switch. Do not turn on password/device flows to
repair a callback mismatch. Actual no-secret code exchange is a live acceptance
gate in the selected tenant, not something JSON syntax validation proves.

## Callback and signing constraints

The current adapter is **AppAuth**, not MSAL or a Microsoft broker integration.
Microsoft's redirect guidance explicitly routes AppAuth and Flutter iOS apps to
**Mobile and desktop applications**. Register the private scheme there and
verify the exact callback through the OS browser on each supported platform.
See [redirect platform guidance](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url).

| Platform | Current checked-in identifiers | Registration/testing constraint |
| --- | --- | --- |
| Android | Package `com.anaregdesign.cosmos_sync_example`; callback scheme `com.anaregdesign.cosmossync` | AppAuth receives the exact registered private-scheme callback; install/build must retain the manifest scheme |
| iOS | Bundle ID `com.anaregdesign.cosmosSyncExample`; same callback scheme | URL Types must match; physical installation needs the owner's Apple team and valid provisioning |
| macOS | Bundle ID `com.anaregdesign.cosmosSyncExample`; same callback scheme | URL Types must match; local ad-hoc builds do not prove signed distribution behavior |

The bundled UI fixes the callback to
`com.anaregdesign.cosmossync:/oauthredirect`. A registration change alone cannot
change the native build's URL handler. No wildcard or alternate spelling,
capitalization, trailing slash or `://` variant is proposed. Production application
IDs, signing and callback ownership need a separate release decision.

If adopting **MSAL/broker** later, Microsoft uses
`msauth://<ANDROID_PACKAGE>/<SIGNATURE_HASH>` for Android and
`msauth.<APPLE_BUNDLE_ID>://auth` for Apple configurations. Android's hash derives
from the signing certificate; debug and release/Play signing identities can
require different registrations. URI-encode the hash as required by the SDK.
Those redirects are not interchangeable with this AppAuth callback. The current
Android release build uses a debug key for local development; it is not store
signing evidence. Do not compute or register a production signature hash until
the owner selects the signing certificate. See
[mobile app configuration](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-mobile-app-configuration)
and [MSAL client configuration](https://learn.microsoft.com/en-us/entra/identity-platform/msal-client-application-configuration).

The proposal uses local sign-out and does not add a post-logout callback. Optional
provider logout requires a separately registered and tested return URL; it does
not revoke issued access tokens or BFF grants. Browser cancellation, refresh,
secure storage and offline cache behavior are described in [native-auth.md](native-auth.md).

## Runtime configuration

Resolve the selected tenant's public discovery document once and use its exact
GUID-based issuer. A domain alias in the discovery request can resolve to a
different issuer string; the BFF must pin the published issuer. Do not use
`common`, `organizations` or an unrelated CLI tenant for this single-tenant test.

Flutter connection form:

```text
BFF URL:       https://<OWNER_APPROVED_BFF_HOST>
Issuer:        https://login.microsoftonline.com/<TENANT_ID>/v2.0
Client ID:     <NATIVE_APP_ID>
Redirect URL:  com.anaregdesign.cosmossync:/oauthredirect
Scopes:        openid profile offline_access api://<BFF_API_APP_ID>/Cosmos.Sync
Discovery URL: https://login.microsoftonline.com/<TENANT_ID>/v2.0/.well-known/openid-configuration
```

BFF `oidc` configuration:

```json
{
  "issuer": "https://login.microsoftonline.com/<TENANT_ID>/v2.0",
  "audience": "<BFF_API_APP_ID>",
  "tenantClaim": "tid",
  "requiredScope": "Cosmos.Sync",
  "tokenUse": ""
}
```

The API controls the access-token version: requesting a v2 endpoint alone does
not force a v2 access token. With v2 configured on the resource, `aud` is the
**API application/client GUID**, while the client requests the full scope URI
and the BFF checks the short `scp` value `Cosmos.Sync`. The native application's
ID token and Microsoft Graph tokens cannot satisfy this API audience/scope.
Entra does not supply the generic `token_use` claim expected by some providers,
so this setup leaves that optional check empty and requires API `scp` instead.
See [API token version](https://learn.microsoft.com/en-us/graph/api/resources/apiapplication?view=graph-rest-1.0)
and [access-token claims](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference).

AppAuth performs code exchange with PKCE through the OS browser. The native app
does not receive a secret, and the BFF does not perform an on-behalf-of exchange
for Cosmos. Standard identity/refresh scopes are requested alongside the custom
API permission. Neither implicit-grant checkbox is needed for this code flow.
See [Authorization Code + PKCE](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow).

## Consent and test identities

Choose two distinct existing users in the selected tenant (explicitly approved
guests also require their identity to exist there). **Writer** receives BFF read
and write access to the isolated fixture; **reader** receives read-only access.
Neither test user needs an Entra directory administrator role. The owner's admin
account is not automatically both test identities. Creating/inviting users or
assigning directory roles is outside this proposal.

Scope `type: User` permits user consent only where the existing tenant policy
allows it. If blocked, use the approved administrator's **single-user Principal
grant** for each selected user; do not select "Grant admin consent for the
tenant" as a shortcut. The consent body contains only `Cosmos.Sync` for the new
API. Standard `openid profile offline_access` can have a separate identity
consent record depending on Entra's flow; review any additional consent screen
or grant before proceeding. Do not add Graph `User.Read` or broader permissions
to make identity login work. See
[single-user administrator consent](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/grant-consent-single-user).

Keep the tenant's global consent policy unchanged. A tighter native enterprise
app assignment gate is optional: it would set `appRoleAssignmentRequired` and
assign only selected users. It requires a separate approved assignment change
and administrator consent even if self-consent is otherwise allowed. No group
or assignment gate is silently enabled by the default templates. Consent alone
does not limit all other users who may self-consent under existing policy; BFF
grants are the data-access boundary. See
[tenant consent policy](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/configure-user-consent).

Bootstrap BFF grants from the **signature-verified API access token**, after
issuer, API audience, time and scope validation by an owner-controlled server
process. Confirm the approved user's directory identity locally, then map its
verified `tid` and `sub` into the server grant. Entra `sub` is application-specific:
the user's object `oid`, email/UPN and the native app's ID-token subject are not
substitutes. Never use an unverified JWT decode or wildcard/temporary allow-all
grant to discover a subject. Persist exact approved grants only in local/server
configuration. [Access-token claims](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference)
explain this distinction.

For negative authorization evidence, a third selected **same-tenant, ungranted**
user with API consent can demonstrate the BFF's 403 grant boundary. A wrong-issuer
or wrong-audience JWT demonstrates 401 separately. A single-tenant API cannot
issue its valid access token to an arbitrary outside tenant. The live Azure
manifest currently distinguishes a different-tenant outsider; do not label that
test as evidence of same-tenant grant denial. If only one test user is available,
report the missing multi-account/read-only evidence rather than simulate a second
identity in production.

## Owner inputs and acceptance

Before applying this proposal, record locally the selected tenant GUID/domain,
approved registration names and owners, the two test users' exact directory
object IDs, and whether user or administrator Principal consent will be used.
The operator needs authorized access to that tenant and sufficient existing
application-management/consent permissions. If the current CLI account cannot
access it, the owner signs in interactively; do not switch accounts, open a login
prompt, mint a PAT/client secret or expand OAuth permissions without authorization.

After approval, apply only the new-object changes, inspect the resulting IDs and
configuration, and then perform user-assisted real OS-browser login. Required
evidence is callback return without a secret, API v2 issuer/audience/scope checks,
refresh/restart, cancellation, account switch, offline edit/reconnect, writer vs
reader behavior, ungranted-user denial and learned-revocation cache purge. Test
each supported native platform with owner-approved signing/device access. Local
injected-adapter tests do not replace this evidence. Track outcomes in
[Issue #18](https://github.com/anaregdesign/cosmos-sync/issues/18),
[physical devices #20](https://github.com/anaregdesign/cosmos-sync/issues/20) and
[live Azure #24](https://github.com/anaregdesign/cosmos-sync/issues/24).
