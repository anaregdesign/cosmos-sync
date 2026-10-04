const identityScopes = new Set([
  "openid", "profile", "email", "offline_access", "address", "phone",
]);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const failed = () => ({ errorCode: "invalid_configuration" });
const cancelled = () => ({ errorCode: "user_cancelled" });
const interaction = () => ({ errorCode: "interaction_required" });

export function createBrowserAuth({ createClient, baseUri, secureContext }) {
  const redirect = new URL("auth-redirect.html", baseUri).href;
  let generation = 0;
  let current = null;
  let busy = false;

  function configuration(encoded) {
    if (!secureContext || typeof encoded !== "string" || encoded.length > 65536) {
      throw failed();
    }
    const config = JSON.parse(encoded);
    const issuer = new URL(config.issuer);
    const tenant = issuer.pathname.split("/")[1];
    if (issuer.protocol !== "https:" || issuer.port || issuer.username ||
        issuer.password || issuer.search || issuer.hash ||
        !(issuer.hostname === "login.microsoftonline.com" ||
          /^[a-z0-9-]+\.ciamlogin\.com$/.test(issuer.hostname)) ||
        !uuid.test(tenant) || issuer.pathname !== `/${tenant}/v2.0` ||
        !uuid.test(config.clientId) || config.redirectUrl !== redirect ||
        config.discoveryUrl !== `${config.issuer}/.well-known/openid-configuration` ||
        (config.postLogoutRedirectUrl != null &&
          config.postLogoutRedirectUrl !== redirect) ||
        (config.provider != null && !["google", "apple"].includes(config.provider)) ||
        !Array.isArray(config.scopes) || !config.scopes.includes("openid") ||
        new Set(config.scopes).size !== config.scopes.length ||
        config.scopes.some((scope) =>
          typeof scope !== "string" || !scope || scope.length > 2048 || /\s/.test(scope))) {
      throw failed();
    }
    const scopes = config.scopes.filter((scope) => !identityScopes.has(scope));
    if (!scopes.length) throw failed();
    const key = JSON.stringify([
      config.issuer, config.clientId, redirect, scopes,
    ]);
    return {
      key, scopes, provider: config.provider,
      options: {
        auth: {
          clientId: config.clientId,
          authority: `${issuer.origin}/${tenant}`,
          knownAuthorities: [issuer.hostname],
          redirectUri: redirect,
        },
        cache: {
          cacheLocation: "memoryStorage",
        },
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

  function kind(error) {
    if (["user_cancelled", "popup_window_error", "empty_window_error"]
        .includes(error?.errorCode)) return "cancelled";
    if (["interaction_required", "login_required", "consent_required",
      "invalid_grant", "no_account_error", "no_tokens_found",
      "token_refresh_required"].includes(error?.errorCode)) {
      return "interactionRequired";
    }
    if (["network_error", "post_request_failed", "get_request_failed",
      "timed_out"].includes(error?.errorCode)) return "transient";
    return "failed";
  }

  async function response(action) {
    try {
      return JSON.stringify({ ok: true, ...await action() });
    } catch (error) {
      return JSON.stringify({ ok: false, kind: kind(error) });
    }
  }

  async function clear() {
    generation++;
    const previous = current;
    current = null;
    if (previous) {
      try {
        await previous.ready;
      } finally {
        await bounded(previous.client.clearCache(), 10000);
      }
    }
  }

  async function bounded(action, milliseconds) {
    let timer;
    try {
      return await Promise.race([
        action,
        new Promise((_, reject) => {
          timer = setTimeout(() => reject({ errorCode: "timed_out" }), milliseconds);
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
  }

  async function accepted(promise, candidate, expectedGeneration, scopes) {
    const result = await promise;
    if (generation !== expectedGeneration || current !== candidate) {
      await bounded(candidate.client.clearCache(), 10000);
      throw cancelled();
    }
    if (typeof result.accessToken !== "string" ||
        !result.accessToken || result.accessToken.length > 16384 ||
        result.tokenType?.toLowerCase() !== "bearer" ||
        !(result.expiresOn instanceof Date) ||
        result.expiresOn.getTime() <= Date.now() + 30000 ||
        !Array.isArray(result.scopes) ||
        scopes.some((scope) => !result.scopes.includes(scope)) ||
        !result.account?.homeAccountId ||
        (candidate.account &&
          (result.account.homeAccountId !== candidate.account.homeAccountId ||
            result.account.localAccountId !== candidate.account.localAccountId ||
            result.account.tenantId !== candidate.account.tenantId))) {
      throw interaction();
    }
    candidate.account = result.account;
    return {
      accessToken: result.accessToken,
      tokenType: result.tokenType,
      scopes: result.scopes,
      expiresAt: result.expiresOn.toISOString(),
    };
  }

  return Object.freeze({
    signIn: (encoded) => response(async () => {
      if (busy) throw failed();
      const config = configuration(encoded);
      busy = true;
      let candidate;
      try {
        await clear();
        const expectedGeneration = generation;
        const client = createClient(config.options);
        candidate = {
          client, key: config.key, ready: bounded(client.initialize(), 10000),
        };
        current = candidate;
        await candidate.ready;
        if (generation !== expectedGeneration || current !== candidate) {
          throw cancelled();
        }
        return await bounded(accepted(client.loginPopup({
          scopes: config.scopes,
          redirectUri: redirect,
          prompt: "select_account",
          ...(config.provider
            ? { extraQueryParameters: { domain_hint: config.provider } } : {}),
        }), candidate, expectedGeneration, config.scopes), 180000);
      } catch (error) {
        if (current === candidate) await clear();
        throw error;
      } finally {
        busy = false;
      }
    }),
    refresh: (encoded) => response(async () => {
      const config = configuration(encoded);
      const candidate = current;
      if (!candidate?.account || candidate.key !== config.key) throw interaction();
      if (busy) throw failed();
      const expectedGeneration = generation;
      busy = true;
      try {
        return await bounded(accepted(candidate.client.acquireTokenSilent({
          scopes: config.scopes,
          account: candidate.account,
          redirectUri: redirect,
          forceRefresh: true,
        }), candidate, expectedGeneration, config.scopes), 20000);
      } catch (error) {
        if (kind(error) === "interactionRequired" ||
            error?.errorCode === "timed_out") {
          if (current === candidate) await clear();
        }
        throw error;
      } finally {
        busy = false;
      }
    }),
    clear: () => response(async () => { await clear(); }),
    endSession: (encoded) => response(async () => {
      if (busy) throw failed();
      const config = configuration(encoded);
      busy = true;
      try {
        await clear();
        const client = createClient(config.options);
        await bounded(client.initialize(), 10000);
        try {
          await bounded(client.logoutPopup({
            postLogoutRedirectUri: redirect,
          }), 180000);
        } finally {
          await bounded(client.clearCache(), 10000);
        }
      } finally {
        busy = false;
      }
    }),
  });
}
