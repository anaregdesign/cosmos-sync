import { PublicClientApplication } from "@azure/msal-browser";
import { createBrowserAuth } from "./auth_core.js";

window.cosmosSyncAuth = createBrowserAuth({
  createClient: (config) => new PublicClientApplication(config),
  baseUri: document.baseURI,
  secureContext: window.isSecureContext,
});
