# Entra registration templates

These are placeholder-only Microsoft Graph **v1.0** request bodies, not an
automation. They contain no credentials or tenant-specific values and cannot be
submitted unchanged. Select the appropriate workforce or consumer contract;
their consent policies differ. Registration readback and runtime evidence are
recorded in the linked setup documents, not inferred from these examples.

## Workforce validation tenant

The files at this directory's root retain the [workforce setup](../../docs/entra-setup.md):
user-consent scope (`type=User`) and optional named-user `Principal` consent.
Obtain authorization for that target, objects, owners, users and consent before
a future write. Do not replace its consent with `AllPrincipals` as a shortcut.

| Body | Intended new-object operation after approval |
| --- | --- |
| `api-create.example.json` | `POST /applications`; replace the new scope UUID placeholder |
| `api-identifier-update.example.json` | `PATCH /applications/<API_APPLICATION_OBJECT_ID>` after recording its application/client ID |
| `native-create.example.json` | `POST /applications`; reference that API application/client ID and scope UUID |
| `service-principal-create.example.json` | `POST /servicePrincipals` for each newly created app, only if its enterprise application is absent |
| `principal-consent.example.json` | Optional `POST /oauth2PermissionGrants` for one explicitly approved user; service principal IDs are directory object IDs |

Application owners are assigned separately to the two new registrations. The
scope UUID is generated once and reused in the native permission definition.
Save all returned app/object/service-principal IDs in an ignored owner-local
location and inspect those exact objects before retrying any operation. A display
name is not a unique identifier. Never submit placeholders, substitute an existing
unrelated product's ID.

## Consumer external tenant

The separate [External ID setup](../../docs/external-id-setup.md) records the
selected CIAM tenant's **completed** two-app/two-service-principal registration
and one API-only administrator grant. Its placeholders in `consumer/` reproduce
that shape for a future owner's approved tenant. They do not rerun or modify the
current deployment. The subsequently approved one-human workforce provider,
password-free customer profile, sign-in-only flow and exact local Web SPA bridge
are applied and read back; selected-customer callback/API-JWT acceptance remains
separate. These initial two-app templates do not reproduce the entire later setup.

| Step | Body | Graph v1.0 operation |
| --- | --- | --- |
| 1 | [consumer/api-create.example.json](consumer/api-create.example.json) | `POST /applications`: `Cosmos Sync Consumer BFF API (validation)`, v2 API, one Admin scope |
| 2 | [consumer/api-identifier-update.example.json](consumer/api-identifier-update.example.json) | `PATCH /applications/<CONSUMER_API_APPLICATION_OBJECT_ID>`: `api://<CONSUMER_API_APP_ID>` |
| 3 | [consumer/service-principal-create.example.json](consumer/service-principal-create.example.json) | `POST /servicePrincipals` with the new API `appId`, if absent |
| 4 | [consumer/native-create.example.json](consumer/native-create.example.json) | `POST /applications`: `Cosmos Sync Consumer Native (validation)`, exact public-client callback and API scope |
| 5 | [consumer/service-principal-create.example.json](consumer/service-principal-create.example.json) | `POST /servicePrincipals` with the new native `appId`, if absent |
| 6 | [consumer/admin-consent.example.json](consumer/admin-consent.example.json) | `POST /oauth2PermissionGrants`: native-SP object ID to API-SP object ID; `AllPrincipals`, null principal, only `Cosmos.Sync` |

Generate one new scope UUID and one owned provisioning marker; reuse them in the
two bodies. Record app `id`, app `appId`, service-principal `id` and consent `id`
separately. Check the selected organization is the intended CIAM tenant and
inspect the exact owned objects before retrying a write; display names alone
cannot prove ownership. A portal path may already provision the service principal.
Never create a duplicate merely because its POST response was lost.

Both apps use `AzureADMyOrg`, no secrets/certificates, app roles, implicit
issuance, default Graph `User.Read`, Graph data/application permissions or client
preauthorization. The native callback is
`com.anaregdesign.cosmossync://auth/oauthredirect`. Both explicit fallback and
device-only flags are false and native-auth APIs are disabled. These settings
are not PKCE enforcement or a general denial of every other OAuth grant;
the adapter uses Authorization Code + S256 PKCE with an OS browser and no secret.
The scope is `type=Admin`; consumer users cannot provide their own API consent.
The selected `AllPrincipals` record grants only this client access to this API
on behalf of users; BFF personal/shared authorization still controls documents.

[consumer/native-config.example.json](consumer/native-config.example.json) gives
the connection-form values. [consumer/bff-oidc.example.json](consumer/bff-oidc.example.json)
is the server `oidc` excerpt, not a complete server configuration. Replace every
placeholder with recorded registration values and observed same-origin discovery
metadata. The native ID differs from the API audience. Choose one issuer per
deployment and keep consumer/workforce data namespaces separate.

The extra workforce federation app is a distinct **confidential upstream
client**, not either product app. Its approved seven-day secret was transferred
only in memory directly to the broker. Required source/product assignment,
Principal-only upstream identity scopes, exact source-object-ID customer
namespace, no signup/local password/OTP and preserved administrative identities
are recorded in the
[current federation boundary](../../docs/external-id-setup.md#approved-one-human-workforce-federation).
Do not add a secret or Graph `User.Read` to these API/native templates.

## Existing authorization and validation

Do not broaden an existing CLI connection's OAuth permissions to execute these
bodies. If application management or the selected exact consent is unavailable
through existing authorization, ask the owner to perform the reviewed steps or authorize
the required connection. Standard identity/refresh consent may be handled by the
interactive OIDC flow; this custom-API grant must not be broadened silently to a
Microsoft Graph data permission.

For future delegated Graph operators, the [create-app API](https://learn.microsoft.com/en-us/graph/api/application-post-applications?view=graph-rest-1.0)
currently lists `AppRegistration.Create`; [app update](https://learn.microsoft.com/en-us/graph/api/application-update?view=graph-rest-1.0)
and [service-principal creation](https://learn.microsoft.com/en-us/graph/api/serviceprincipal-post-serviceprincipals?view=graph-rest-1.0)
list `Application.ReadWrite.All`; [delegated-grant creation](https://learn.microsoft.com/en-us/graph/api/oauth2permissiongrant-post?view=graph-rest-1.0)
lists `DelegatedPermissionGrant.ReadWrite.All`, with supported directory roles.
This describes required existing capabilities, not permission-expansion commands.
Use the approved portal session if the existing client cannot perform an action.
Neither Global Administrator nor a template bypasses OAuth authorization.

JSON parsing validates syntax only. Actual consumer OS-browser callback/code
exchange, API JWT issuer/audience/scope checks, refresh and cache lifecycle remain
required after the exact provider and user flow are configured. No ID token,
Microsoft Graph token or local email fallback substitutes for that evidence.
