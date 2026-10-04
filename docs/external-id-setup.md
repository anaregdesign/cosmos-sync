# External ID consumer setup and verification

The owner selected Microsoft Entra External ID with browser PKCE and subsequently
authorized necessary dedicated Azure/tenant settings. On 2026-10-04 (Japan time),
the new consumer directory and subscription-linked billing resource reached
`Succeeded`. Its exact domain matched the private plan, its geography is
**United States**, its country code is `US`, and ordinary existing-credential
Graph readback identified its tenant type as `CIAM`. Actual identifiers, domain,
billing resource names and operator account stay in private operator evidence.
Exactly two dedicated consumer app registrations and their two service principals
have also been created and read back. The new native client has administrator
consent for only the new API's `Cosmos.Sync` scope. Anonymous discovery and the
actual Flutter configuration constructor passed; no consumer user flow is
associated and no real consumer or Apple/Google login has passed. The published
`0.2.0-dev.1` artifacts remain unchanged. The workforce validation directory,
registrations and resources are retained separately.

## Current scope, 2026-10-04

The owner cancelled actual Google/Apple connections, configuration, credentials
and live-provider tests. Issue #30 is not planned; the provider stages and
operations below are retained future reference, not pending owner inputs or
current acceptance requirements. Do not create a Google client, Apple key or
social user flow to satisfy this delivery.

The dedicated External ID common OIDC flow remains unverified and distinct from
the successful workforce Entra authentication. Preserve server authorization
and linking/broker-bypass safety. Continue simulator development first; physical
Android verification is the final gate. Cancellation does not authorize a new
customer account, a local email/password/OTP substitute, signing, paid resources
or new consent scopes.

The creation request used `Standard/A0`, following Microsoft's documented API
example, while the successful actual GET returned **`Base/A0`** and MAU billing.
The published `2023-05-17-preview` schema still enumerates Standard/Premium
names; no reviewed official contract establishes that `Base` is a synonym for
Standard or proves its billing allowance. Preserve the returned value and this
discrepancy instead of changing the SKU, recreating the tenant or inferring a
paid upgrade/free exemption. No premium SKU or paid add-on was requested.
[CIAM creation contract](https://learn.microsoft.com/en-us/rest/api/activedirectory/ciam-tenants/create?view=rest-activedirectory-2023-05-17-preview),
[CIAM readback schema](https://learn.microsoft.com/en-us/rest/api/activedirectory/ciam-tenants/get?view=rest-activedirectory-2023-05-17-preview).

## Verified directory and application configuration

The application trust configuration below is applied and verified. The owner's
authorization already covers necessary dedicated consumer tenant/API settings;
there is no outstanding request to approve the same directory or registrations
again. Keep the native app unassociated with a customer user flow until its exact
configured provider and account-isolation policy are reviewed.

| Object | Verified configuration or remaining gate |
| --- | --- |
| External tenant/domain | New dedicated CIAM directory created; exact domain and tenant ID verified against private inputs |
| Tenant location | Created in **United States**, country `US`; immutable and distinct from the billing resource-group region |
| Billing | MAU resource linked to the existing selected subscription in a new dedicated West US2 group; subscription remains in its workforce directory; actual SKU readback `Base/A0` |
| API registration + service principal | Created `Cosmos Sync Consumer BFF API (validation)`; `signInAudience=AzureADMyOrg`, `api.requestedAccessTokenVersion=2`, identifier `api://<CONSUMER_API_APP_ID>`, no redirect, no client secret, no application permissions/app roles |
| API scope | Exactly one enabled delegated scope, `api://<CONSUMER_API_APP_ID>/Cosmos.Sync`, `type=Admin`. Its display text explains access to the caller's authorized Cosmos Sync data; it grants no other user's documents |
| Native registration + service principal | Created `Cosmos Sync Consumer Native (validation)`; `signInAudience=AzureADMyOrg`, native public-client redirect, no secret, no implicit issuance; `isFallbackPublicClient=false`, `isDeviceOnlyAuthSupported=false`, `nativeAuthenticationApisEnabled=none` |
| Native API grant | Verified `AllPrincipals` delegated consent from the new native service principal to the new API service principal, with **only** `Cosmos.Sync` and `principalId=null`; no default Graph `User.Read`, Graph data permissions, application permissions or preauthorized clients |
| Native return | Exact existing callback `com.anaregdesign.cosmossync://auth/oauthredirect`, registered as Mobile and desktop applications; no wildcard. Defer provider logout registration until its exact callback is reviewed |
| Discovery/configuration | Actual tenant-ID-host metadata and matching issuer/discovery origin verified anonymously; current Flutter `OidcConfig` accepts those values. This does not verify code exchange or issued API tokens |
| Consumer login | Common CIAM OIDC/user-flow authentication remains unverified; actual Google/Apple configuration and login are excluded from this delivery |
| Retention | Retain the reusable directory and owned resources; no automated teardown |

The tenant's chosen location cannot be changed later. Tenant creation and Azure
resource management are separate permissions; Global Administrator alone does
not confer subscription RBAC. Creation used existing authorized access, and the
platform gives the creator Global Administrator in the new directory. No
subscription move, extra operator-role grant or paid residency add-on was part
of creation. The owner's current authorization covers necessary dedicated
tenant/API settings; technical review still limits consent to the selected API
and excludes unrelated directory access.
[Tenant creation](https://learn.microsoft.com/en-us/entra/external-id/customers/quickstart-tenant-setup),
[Tenant Creator role](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference#tenant-creator).

### Dedicated management access, 2026-10-04

The owner has explicitly resumed all historical owner-paused work. Existing
CLI Graph access could read registrations and flows but the provider API denied
the missing `IdentityProvider.Read.All`/`IdentityProvider.ReadWrite.All` OAuth
permission. A narrow Azure CLI interactive scope request then returned
`AADSTS65002`, Microsoft's first-party preauthorization restriction. Do not
work around that restriction by changing product permissions or directory roles.

A separate, secret-free single-tenant public **setup operator** registration and
service principal were created and read back. They declare only Graph delegated
`IdentityProvider.ReadWrite.All` and `EventListener.ReadWrite.All`. Administrator
consent is `Principal`, limited to the existing operator, not `AllPrincipals`.
The product API/native registrations and their API-only consent are unchanged;
no new user, directory role, application permission or client secret was created.
Management uses the registered loopback return and standard MSAL code/PKCE flow.

The current operator authentication passed independently verified ID-JWT
signature, exact issuer/client audience, tenant and existing-owner checks.
Microsoft Graph accepted the separate scoped management API credential and
returned the provider inventory. A redundant self-profile probe and subsequent
unbounded Python connection failure were not counted as passes. Bounded IPv4
system-TLS transport resolved the management discovery/call failure without
disabling certificate verification or adding `User.Read`. Tokens/actual IDs stay
private; the reusable public-client registration contains no secret.

This is **administrative Microsoft authentication, not customer CIAM login**.
The existing administrative record uses the `ExternalAzureAD` identity namespace,
distinct from the documented workforce-federated customer namespace. Do not
alter that privileged record or silently create another customer profile to
make a user flow succeed. The one-real-owner/no-new-user limit remains a separate
scope decision; resumed work and unavailable physical iOS do not supply customer
login, hosted data or linking/broker-bypass evidence.

Customer users cannot perform their own API permission consent in external
tenants. An existing authorized administrator must therefore grant only the
API-specific permission above. The walkthrough's default Graph permission is
unnecessary for the product. Browser sign-in/MFA, if required, remains an owner
operation; ordinary registration must not silently add new CLI OAuth scopes or
consent to all permissions found on an unreviewed app.
[External-tenant consent](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app?toc=/entra/external-id/toc.json&bc=/entra/external-id/breadcrumb/toc.json),
[Expose a scoped API](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-configure-app-expose-web-apis).

`AllPrincipals` is administrator consent for this one client's delegated access
to this one API on behalf of signed-in users. It is not a directory-wide Graph
data grant, a provider allowlist or permission to read another user's documents.
The BFF still verifies each API token and enforces personal/shared data policy.
[Delegated grant fields](https://learn.microsoft.com/en-us/graph/api/resources/oauth2permissiongrant?view=graph-rest-1.0).

Microsoft permits custom returns for non-MSAL mobile/desktop clients. Keep
the callback identical in the directory, Android manifest and Apple URL types.
PKCE and the system browser remain mandatory. Registration compatibility and
callback return still require an actual consumer-tenant test.
[Native redirect platform](https://learn.microsoft.com/en-us/entra/identity-platform/how-to-add-redirect-uri),
[Authorization Code/PKCE](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow).

## Reproduce the two-app registration contract

Use the placeholder-only [consumer request bodies](../ops/entra/README.md#consumer-external-tenant)
in a future owner's dedicated CIAM tenant. These examples describe the applied
shape, not an instruction to rerun creation in the current directory. Select and
verify the target tenant and its `CIAM` organization before writes, generate one
new scope UUID and one provisioning marker, and retain returned IDs privately.
Never adopt an application by display name alone. For the current deployment,
inspect the recorded owned objects instead of creating duplicates.

The equivalent Microsoft Graph **v1.0** sequence has six operations:

| Step | Exact object operation | Request body |
| --- | --- | --- |
| 1 | `POST /applications` for the dedicated API; record its application `id` and client `appId` | [API create](../ops/entra/consumer/api-create.example.json) |
| 2 | `PATCH /applications/<CONSUMER_API_APPLICATION_OBJECT_ID>`; set only `identifierUris` to the new API's URI | [API identifier](../ops/entra/consumer/api-identifier-update.example.json) |
| 3 | `POST /servicePrincipals` with the API `appId`; record its service-principal `id` | [Service principal](../ops/entra/consumer/service-principal-create.example.json) |
| 4 | `POST /applications` for the native client, with the API `appId` and exact scope UUID | [Native create](../ops/entra/consumer/native-create.example.json) |
| 5 | `POST /servicePrincipals` with the native `appId`; record its service-principal `id` | [Service principal](../ops/entra/consumer/service-principal-create.example.json) |
| 6 | `POST /oauth2PermissionGrants`; native-SP object ID to API-SP object ID, `AllPrincipals`, only `Cosmos.Sync` | [API-only admin consent](../ops/entra/consumer/admin-consent.example.json) |

Portal registration may already create an enterprise application. Inspect it
first and skip its corresponding service-principal POST if present. In the Entra
admin center, create both single-tenant registrations; expose the API's v2,
admin-only scope; configure only the native Mobile and desktop callback; remove
default Graph permissions; then add the new API permission and grant consent
only after its permission list contains exactly `Cosmos.Sync`. Read back both
registrations, both service principals and the exact consent record afterward.
App `id`, app `appId` and service-principal `id` are different identifiers;
consent uses service-principal object IDs. Preserve an uncertain write's intent
and inspect exact owned objects before retrying it.
[Create application](https://learn.microsoft.com/en-us/graph/api/application-post-applications?view=graph-rest-1.0),
[update application](https://learn.microsoft.com/en-us/graph/api/application-update?view=graph-rest-1.0),
[create service principal](https://learn.microsoft.com/en-us/graph/api/serviceprincipal-post-serviceprincipals?view=graph-rest-1.0),
[create delegated grant](https://learn.microsoft.com/en-us/graph/api/oauth2permissiongrant-post?view=graph-rest-1.0).

For delegated Graph access, each operation also needs an already authorized
operator and a supported directory role. The current create-app documentation
lists `AppRegistration.Create` as least privilege; app update/service-principal
creation list `Application.ReadWrite.All`; the grant operation lists
`DelegatedPermissionGrant.ReadWrite.All`. These are capability requirements,
**not** instructions to add scopes to an existing CLI connection. Global
Administrator does not replace a client's OAuth authorization. Use existing
authorized capabilities or the approved portal session; report the exact missing
operation if neither is available. Create no client secret, application permission,
new directory role or broad Graph data grant to make this sequence work.

The registered public-client redirect identifies this code-flow client;
`isFallbackPublicClient=false` is not a PKCE toggle or a general proof that every
other OAuth grant is impossible. The current adapter must still perform S256
PKCE through the OS browser without a secret.
[Application schema](https://learn.microsoft.com/en-us/graph/api/resources/application?view=graph-rest-1.0),
[client-type fallback](https://learn.microsoft.com/en-us/troubleshoot/entra/entra-id/app-integration/confidential-client-application-authentication-error-aadsts7000218).

## Configure a new BFF/native deployment

The existing workforce validation and new CIAM consumer configuration are
separate single-issuer deployments. Choose one exact issuer/API audience for each
BFF. Adding CIAM must not silently accept workforce tokens, adopt workforce
partitions or migrate their owners. Registration replacement changes API-subject
bindings and needs an explicit ownership migration.

Anonymous metadata readback confirmed the selected consumer directory's exact
tenant-ID-host issuer. Its initial-domain hostname returned metadata advertising
a different origin. Current Flutter `OidcConfig` requires issuer and discovery
URL origins to match. Use the matching **observed** issuer and discovery URL;
do not merely substitute a domain alias or invent a GUID URL without reading it.
The portable pattern below was verified for this directory, not every tenant:

```text
BFF URL:       https://<OWNER_APPROVED_BFF_HOST>
Issuer:        https://<CONSUMER_TENANT_ID>.ciamlogin.com/<CONSUMER_TENANT_ID>/v2.0
Client ID:     <CONSUMER_NATIVE_APP_ID>
Redirect URL:  com.anaregdesign.cosmossync://auth/oauthredirect
Scopes:        openid profile offline_access api://<CONSUMER_API_APP_ID>/Cosmos.Sync
Discovery URL: https://<CONSUMER_TENANT_ID>.ciamlogin.com/<CONSUMER_TENANT_ID>/v2.0/.well-known/openid-configuration
```

Copy [native public configuration](../ops/entra/consumer/native-config.example.json)
into the app connection form and use the [BFF OIDC excerpt](../ops/entra/consumer/bff-oidc.example.json)
for the server's `oidc` object. For the [ACA deployment](azure-container-apps.md),
set Terraform `oidc.issuer`, `oidc.audience` and `oidc.required_scope` to those
verified consumer values. Its `deployment.tenant_id` is the Azure subscription's
resource-management tenant, which can remain the workforce tenant; do not replace
it with the consumer tenant or move the subscription. Keep Cosmos/Key Vault
access on the server's managed identity and retain the reviewed authorization
mode, immutable image digest, cursor secret and intentional data namespace.

Changing server OIDC configuration requires a reviewed deployment/revision and
readback of its effective issuer/audience/scope; the native form alone does not
change the BFF. After a provider and flow are ready, verify an actual signed API
access token against discovery/JWKS, issuer, API client-ID audience, time,
`Cosmos.Sync` scope and subject before checking `/v1/session` and data access.
Clear old native credentials/cache through normal sign-out before changing
provider configuration. Never repair a failure by accepting an ID token,
trusting an unverified JWT decode or disabling TLS/authorization.

The current evidence is registration readback, anonymous metadata and actual
Flutter constructor validation only. No consumer API JWT, callback, refresh,
shared-account isolation or hosted consumer deployment has passed. Do not add
legacy B2C `p=` parameters, `common`/`organizations`, a custom domain or an
unreviewed logout callback as incidental setup.
[OIDC discovery](https://learn.microsoft.com/en-us/entra/identity-platform/v2-protocols-oidc#fetch-the-openid-configuration-document).

## Future provider registration reference

These Google/Apple stages are not planned for the current delivery. If separately
restored by the owner, actual directory IDs now exist in private readback; substitute those verified
values when preparing provider return URLs, show the exact URLs and changes to
the owner, then obtain the required Google/Apple settings and permissions.
A placeholder is not a usable callback, and the native app's return is not the
upstream provider's return. Azure tenant authorization does not grant access to
Google Cloud or the Apple Developer portal.

| Provider | Concrete proposed objects | Owner settings still missing |
| --- | --- | --- |
| Google | Dedicated project display name `Cosmos Sync Identity Validation`, candidate project ID `cosmos-sync-identity-0909a8`; one **Web application** OAuth client `Cosmos Sync External ID (validation)`; external consent audience in Testing; identity-only scopes; no paid APIs, Firebase or service-account keys | Existing project or permission to create this project, owning organization/folder if applicable, private support/developer contact, approved test login and required application/privacy branding |
| Apple | Approved existing primary App ID or new dedicated `com.anaregdesign.cosmossync` App ID with Sign in with Apple; Services ID `com.anaregdesign.cosmossync.externalid.validation`; one dedicated Sign in with Apple key `Cosmos Sync External ID Validation` | Existing enrolled Apple Developer Team, primary App ID/Services ID availability, operator with identifier/key access, explicit permission for capability/key changes and an approved Apple login |

Google federation uses a confidential Web OAuth client at the **broker**. Its
client secret is entered directly into External ID by an approved operator; it
does not belong in Flutter or the BFF. Use the exact tenant-specific `ciamlogin.com`
return selected by setup, such as
`https://<tenant-subdomain>.ciamlogin.com/<external-tenant-id>/federation/oauth2`.
Microsoft also documents other exact return variants; review any additional
variant before registration. Do not add a wildcard or unrelated callback.
Google project/consent publication and verification are separate from package
publication; remain in the approved testing audience initially.
[External ID Google federation](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-google-federation-customers),
[Google OAuth clients](https://support.google.com/cloud/answer/15549257),
[Google app branding](https://support.google.com/cloud/answer/15549049).

Apple web federation needs a Services ID associated with an Apple primary App ID
that has Sign in with Apple enabled. The proposed broker domains are
`<tenant-subdomain>.ciamlogin.com` and `<external-tenant-id>.ciamlogin.com`; the
exact approved HTTPS return is resolved after creation. The operator supplies
the Team ID, Services ID, Key ID and `.p8` key directly to the broker using its
documented configuration. Record the expiry/rotation owner and renew the Apple
client secret within its six-month cycle. This does not authorize development
certificates, provisioning profiles or physical iPhone installation.
[Apple web configuration](https://developer.apple.com/help/account/capabilities/configure-sign-in-with-apple-for-the-web/),
[External ID Apple federation](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-apple-federation-customers).

For a future restored provider rollout, after the first exact provider is
configured, create one reviewed user flow
`CosmosSyncSignUpSignIn` associated only with the new native client. Graph v1.0
uses `POST /identity/authenticationEventsFlows`, then
`POST /identity/authenticationEventsFlows/<FLOW_ID>/conditions/applications/includeApplications`
with the native **client `appId`**, not its object or service-principal ID. At least
one configured identity provider is required; an empty provider list is not a
documented inert-flow setup. Read back all enabled login methods, signup policy
and application associations before adding this client. Microsoft's creation walkthrough
includes email-account methods; `domain_hint=google` or `domain_hint=apple` only
shortens navigation and is not an allowlist. Do not promise a provider-only or
restricted-testing user flow without a negative test of alternate entry routes.
Do not enable local email/password/OTP or create an email test customer to fill a
missing social-provider setup. `isSignUpAllowed=false` is sign-in-only, not an
authentication-off switch; a new real provider account may require approved
normal signup and a new customer directory object. Review that exact first-login
policy before association. Introduce a second social
provider only after the identity-isolation gate below passes. Collect no optional
postal/name/custom signup attributes for this validation.
[Graph flow creation](https://learn.microsoft.com/en-us/graph/api/identitycontainer-post-authenticationeventsflows?view=graph-rest-1.0),
[Graph application association](https://learn.microsoft.com/en-us/graph/api/authenticationconditionsapplications-post-includeapplications?view=graph-rest-1.0),
[User flow creation](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-user-flow-sign-up-sign-in-customers),
[Flow association](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-user-flow-add-application),
[Browser federation and provider hints](https://learn.microsoft.com/en-us/entra/external-id/customers/concept-authentication-methods-customers).

## Account and linking boundary

The API accepts only the broker's access JWT for the dedicated consumer API:
trusted discovery/JWKS and signature, exact actual `iss`, API `aud`, expiry/not
before, nonempty `sub` and `Cosmos.Sync` in `scp`. The native client requests
`openid profile offline_access api://<consumer-api-app-id>/Cosmos.Sync`.
OIDC `profile` requests profile claims; it does not grant Graph `User.Read` or
directory data access. Pin the actual issuer returned by approved
tenant discovery instead of inventing it from a hostname. Keep one exact issuer
per initial deployment and a separate data namespace from workforce validation.

In Microsoft's v2 tokens the API audience is the API application's client ID;
`sub` is an immutable, application-specific identifier. The ID-token subject
or native client ID must not replace the API identity. Verify repeated login,
refresh and each approved platform against the same API subject; replacing the
API registration is an ownership migration, not a configuration-only edit.
[Access-token claims](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference).

Current built-in authorization durably derives an account from verified broker
`(issuer, sub)`, with personal self-access and server-managed shared memberships.
It does not store trusted upstream provider bindings, expose link/unlink, issue
its own refresh credentials, or check an approved `azp` client allowlist. Before
claiming a general consumer deployment, review explicit client allowlisting and
the API's administrator grants. A token's email, `tid`, `idp`, roles or groups
must not create membership or choose a data partition.

No reviewed official document establishes that this proposed broker configuration
never merges identities by email. A BFF which sees the same broker subject cannot
detect a newly attached provider. Do not certify no-email-linking from our hash
function alone. Deterministically test equal email across provider/local methods, different email,
Apple relay/missing profile, changed email and attempted direct self-service
link/unlink. Record whether directory objects and API subjects remain separate.
One real account cannot prove isolation between independent provider principals.

Explicit linking remains unimplemented. The selected future contract uses a
256-bit random challenge, a stored SHA-256 digest and a 300-second transaction
lifetime. At commit it requires independently verified authentication within
300 seconds for the current account and separate, challenge-bound new-identity
proof. Consume the challenge and assign the unique identity atomically, preserve
the existing account/data owner, and reject identities already owned by another
account. See the [complete bounded linking contract](social-auth.md#selected-linking-contract-not-implemented)
for binding fields, transaction-store and unlink requirements. No Graph identity
write grant, custom token-claim service or self-service linking capability was
added during directory/application setup. Do not enable linking until the broker provides
reviewed server-verifiable binding and lifecycle evidence.

Broker session/refresh revocation and BFF data-grant revocation are separate.
The current API does not consult a provider revocation endpoint on every JWT;
an already-issued access token can remain acceptable until expiry. There is no
local maximum JWT lifetime, and the new External ID access/refresh lifetimes and
provider-signout propagation have not been measured. Refresh may continue until
the broker rejects it, so no overall provider-revocation delay is established.
The [current token contract](social-auth.md#current-token-contract) records exact
algorithm/JWKS/native-client behavior. Existing online authorization rechecks,
cache/outbox purge on learned denial and unavoidable offline revocation delay
still apply.

## Operators, credential custody and cost

Use existing authorized operator sessions and have the owner complete browser
password/MFA/consent. Creating the API/native apps uses application-registration
access; federation uses External Identity Provider Administrator access; user
flow management uses the corresponding user-flow role. These are task needs,
not an instruction to grant new directory roles. If existing access is missing,
report the exact action before changing permissions. Grant the API-specific
consent as an authorized external-tenant administrator.
[Application registration prerequisite](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app),
[Federation operator prerequisite](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-google-federation-customers),
[Directory roles](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference).

For an existing Google project, OAuth Config Editor is the narrow documented
configuration role (currently Beta); it can create/read secrets, so treat it as
privileged. Project creation/organization placement needs separate existing
authority. The Apple operator needs the approved team's identifier/key access.
Do not invite operators or assign these roles as part of preparation.
[Google OAuth configuration role](https://docs.cloud.google.com/iam/docs/roles-permissions/oauthconfig),
[Apple team roles](https://developer.apple.com/help/account/access/roles/).

The broker holds active Google/Apple credentials. The owner chooses a private
secret manager for any recovery copy and rotation runbook; no additional vault is
required just to describe this setup. Keep secrets, `.p8` files, access/refresh
tokens, private account addresses and owner identifiers out of the repository,
Issues, screenshots and chat. BFF and native clients receive only public
configuration and their approved API credentials. Record a replacement-key test,
bounded overlap, expiry alerts and rollback before enabling either provider.

Microsoft's public External ID Basic pricing includes the first 50,000 monthly
active users without charge. MAUs are combined across linked workforce/external
tenants for the billing subscription, so this
new tenant does not receive a guaranteed independent allowance. SMS, M2M and
Go-Local are paid add-ons; propose none. Check current subscription usage and
meter terms for the now-linked resource; the observed ARM `Base` label alone does
not establish Basic pricing or an unused allowance. Azure employee status is not
evidence of an identity billing exemption. Retained directories and live signup
can create future usage; this configuration is not a hard spending cap.
[External ID price](https://azure.microsoft.com/en-us/pricing/details/microsoft-entra-external-id/),
[Billing aggregation and add-ons](https://learn.microsoft.com/en-us/entra/external-id/external-identities-pricing).

If an enrolled Apple team is available, use its approved existing membership.
New Apple enrollment costs 99 USD per year before regional variation and requires
the owner to accept Apple's agreement; it is not authorized here. Google project
preparation includes no paid workload/API request. Do not assume that consent
publication, brand/domain verification or developer enrollment is completed.
[Apple enrollment](https://developer.apple.com/programs/enroll/).

## Safe local work and live acceptance

Local fixtures may exercise External ID-shaped API JWTs, wrong/native/provider
audiences, absent scopes, unknown keys, issuer/key rotation failures, equal-email
identity isolation and callback/refresh/cache lifecycle. Prepare a non-secret
configuration template and rerun the existing BFF, Dart and Flutter regressions.
They are useful implementation evidence and do not require an external tenant.
Any required client allowlist, fresh-link proof or provider UI change needs its
own reviewed implementation; do not silently relabel the published preview.

Dedicated registration and discovery are now verified. Next verify one
actual configured-provider login through the current macOS/Android browser adapter, dedicated API
JWT checks, subject stability, cancellation/alternate-account entry, refresh,
offline reopen/reconnect and purge. Record one-account limitations. This common OIDC login remains a separate gate; actual
Google/Apple provider connections are not required or claimed. The owner
deferred physical checks to the final Android gate and
still chose unsigned iOS validation; no signed physical iPhone acceptance is
claimed. Web requires a separate client registration, HTTPS callback and new Web
login adapter before it can be included. Provider federation does not turn the
native sample into a Web app. Cross-provider linking, independent actual users,
provider revoke/delete recovery and operational key rotation are future
provider-specific reference, not current #30 requirements. Server-owned linking
and deterministic lifecycle/security work remain in
[#27](https://github.com/anaregdesign/cosmos-sync/issues/27),
[#28](https://github.com/anaregdesign/cosmos-sync/issues/28) and
[#29](https://github.com/anaregdesign/cosmos-sync/issues/29).

Google project/contact/test-login and Apple team/App ID inputs are no longer
requested. Existing Azure/tenant authority does not remove the current
no-new-user constraint or provide a verified CIAM login method; settle that
boundary before any user-flow change. The owner completes any necessary browser
login/MFA when actionable. No credential or secret belongs in a text response.
Directory/application configuration alone does not close common OIDC, linking,
independent-user or final physical-device acceptance.
