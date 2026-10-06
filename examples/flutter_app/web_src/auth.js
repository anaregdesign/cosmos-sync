import { PublicClientApplication } from "@azure/msal-browser";
import { createBrowserAuth } from "./auth_core.js";
import { createGenericOidcClient } from "./generic_oidc.js";

window.cosmosSyncAuth = createBrowserAuth({
  createClient: (config) => new PublicClientApplication(config),
  createGenericClient: createGenericOidcClient,
  baseUri: document.baseURI,
  secureContext: window.isSecureContext,
});
