const identityScopes = new Set([
  "openid", "profile", "email", "offline_access", "address", "phone",
]);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const invalid = () => ({ errorCode: "invalid_configuration" });

export function browserConfiguration(encoded, baseUri, secureContext) {
  if (!secureContext || typeof encoded !== "string" || encoded.length > 65536) {
    throw invalid();
  }
  const config = JSON.parse(encoded);
  const adapter = config.browserAdapter ?? "entra";
  if (!["entra", "oidc"].includes(adapter)) throw invalid();
  const redirect = new URL(
    adapter === "entra" ? "auth-redirect.html" : "oidc-redirect.html", baseUri,
  ).href;
  const issuer = new URL(config.issuer);
  const discovery = new URL(config.discoveryUrl);
  if (issuer.protocol !== "https:" || issuer.username || issuer.password ||
      issuer.search || issuer.hash ||
      discovery.protocol !== "https:" || discovery.origin !== issuer.origin ||
      discovery.username || discovery.password || discovery.search || discovery.hash ||
      typeof config.clientId !== "string" || !/^[!-~]{1,256}$/.test(config.clientId) ||
      config.redirectUrl !== redirect ||
      (config.postLogoutRedirectUrl != null &&
        config.postLogoutRedirectUrl !== redirect) ||
      !Array.isArray(config.scopes) || !config.scopes.includes("openid") ||
      new Set(config.scopes).size !== config.scopes.length ||
      config.scopes.some((scope) =>
        typeof scope !== "string" || !scope || scope.length > 2048 || /\s/.test(scope))) {
    throw invalid();
  }
  const scopes = config.scopes.filter((scope) => !identityScopes.has(scope));
  if (!scopes.length) throw invalid();
  const key = JSON.stringify([
    adapter, config.issuer, config.clientId, redirect,
    config.discoveryUrl, config.scopes,
  ]);
  if (adapter === "oidc") {
    if (config.provider != null) throw invalid();
    return {
      adapter, key, scopes, redirect,
      options: {
        issuer: config.issuer,
        clientId: config.clientId,
        discoveryUrl: config.discoveryUrl,
        redirectUri: redirect,
        postLogoutRedirectUri: config.postLogoutRedirectUrl ?? redirect,
        scopes: [...config.scopes],
        apiScopes: [...scopes],
      },
    };
  }
  const tenant = issuer.pathname.split("/")[1];
  if (issuer.port ||
      !(issuer.hostname === "login.microsoftonline.com" ||
        /^[a-z0-9-]+\.ciamlogin\.com$/.test(issuer.hostname)) ||
      !uuid.test(tenant) || issuer.pathname !== `/${tenant}/v2.0` ||
      !uuid.test(config.clientId) ||
      config.discoveryUrl !== `${config.issuer}/.well-known/openid-configuration` ||
      (config.provider != null && !["google", "apple"].includes(config.provider))) {
    throw invalid();
  }
  return {
    adapter, key, scopes, redirect, provider: config.provider,
    options: {
      auth: {
        clientId: config.clientId,
        authority: `${issuer.origin}/${tenant}`,
        knownAuthorities: [issuer.hostname],
        redirectUri: redirect,
      },
      cache: { cacheLocation: "memoryStorage" },
      system: {
        allowPlatformBroker: false,
        popupBridgeTimeout: 180000,
        iframeBridgeTimeout: 10000,
        serverTelemetryEnabled: false,
        loggerOptions: {
          piiLoggingEnabled: false,
          logLevel: 0,
          loggerCallback: () => {},
        },
      },
    },
  };
}
