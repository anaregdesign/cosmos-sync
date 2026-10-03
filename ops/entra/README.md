# Entra review templates

These are placeholder-only proposed Microsoft Graph v1.0 request bodies, not an
automation or evidence of applied changes. Read [the setup proposal](../../docs/entra-setup.md)
and obtain approval for the named objects, selected tenant, owners, users and
consent before any write. They contain no credentials or tenant-specific values.

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
unrelated product's ID or use tenant-wide `AllPrincipals` consent as a shortcut.

Do not broaden an existing CLI connection's OAuth permissions to execute these
bodies. If application management or single-user consent is not available through
existing authorization, ask the owner to perform the reviewed steps or authorize
the required connection. Standard identity/refresh consent may be handled by the
interactive OIDC flow; this custom-API grant must not be broadened silently to a
Microsoft Graph data permission.

JSON parsing validates syntax only. The selected tenant still has to accept the
native callback and complete Authorization Code + PKCE without a secret, and the
BFF must validate the issued API audience/scope before granting document access.
