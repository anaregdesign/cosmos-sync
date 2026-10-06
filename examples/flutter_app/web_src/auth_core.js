import { browserConfiguration } from "./auth_config.js";

const failed = () => ({ errorCode: "invalid_configuration" });
const cancelled = () => ({ errorCode: "user_cancelled" });
const interaction = () => ({ errorCode: "interaction_required" });

export function createBrowserAuth({
  createClient, createGenericClient, baseUri, secureContext,
}) {
  let generation = 0;
  let current = null;
  let busy = false;
  let proofGeneration = 0;
  let proofCandidate = null;

  function configuration(encoded) {
    return browserConfiguration(encoded, baseUri, secureContext);
  }

  function clientFor(config) {
    const factory = config.adapter === "oidc" ? createGenericClient : createClient;
    if (typeof factory !== "function") throw failed();
    return factory(config.options);
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
    try {
      await cancelProof();
    } finally {
      if (previous) await clearCandidate(previous);
    }
  }

  async function cancelProof() {
    proofGeneration++;
    const candidate = proofCandidate;
    proofCandidate = null;
    if (candidate) await clearCandidate(candidate);
  }

  async function clearCandidate(candidate) {
    // A generic client's guarded stores reject late token writes after abort.
    if (typeof candidate.client.cancel === "function") {
      candidate.client.cancel();
      await bounded(candidate.client.clearCache(), 10000);
      return;
    }
    try {
      await candidate.ready;
    } finally {
      await bounded(candidate.client.clearCache(), 10000);
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

  function checkedTokens(result, scopes, account) {
    if (typeof result.accessToken !== "string" ||
        !result.accessToken || result.accessToken.length > 16384 ||
        result.tokenType?.toLowerCase() !== "bearer" ||
        !(result.expiresOn instanceof Date) ||
        result.expiresOn.getTime() <= Date.now() + 30000 ||
        !Array.isArray(result.scopes) ||
        scopes.some((scope) => !result.scopes.includes(scope)) ||
        !result.account?.homeAccountId ||
        (account &&
          (result.account.homeAccountId !== account.homeAccountId ||
            result.account.localAccountId !== account.localAccountId ||
            result.account.tenantId !== account.tenantId))) {
      throw interaction();
    }
    return {
      accessToken: result.accessToken,
      tokenType: result.tokenType,
      scopes: result.scopes,
      expiresAt: result.expiresOn.toISOString(),
    };
  }

  async function accepted(promise, candidate, expectedGeneration, scopes) {
    const result = await promise;
    if (generation !== expectedGeneration || current !== candidate) {
      await bounded(candidate.client.clearCache(), 10000);
      throw cancelled();
    }
    const tokens = checkedTokens(result, scopes, candidate.account);
    candidate.account = result.account;
    return tokens;
  }

  async function acceptedProof(promise, candidate, main, expectedGeneration,
      expectedProofGeneration, scopes) {
    const result = await promise;
    if (generation !== expectedGeneration || current !== main ||
        proofGeneration !== expectedProofGeneration || proofCandidate !== candidate) {
      await bounded(candidate.client.clearCache(), 10000);
      throw cancelled();
    }
    const tokens = checkedTokens(result, scopes);
    if (typeof result.idToken !== "string" || !result.idToken ||
        result.idToken.length > 16384 ||
        !/^[A-Za-z0-9\-._~+/]+=*$/.test(result.idToken)) throw failed();
    return { ...tokens, idToken: result.idToken };
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
        const client = clientFor(config);
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
          redirectUri: config.redirect,
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
          redirectUri: config.redirect,
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
    freshProof: (encoded, nonce) => response(async () => {
      if (busy || typeof nonce !== "string" || !/^[0-9a-f]{64}$/.test(nonce)) {
        throw failed();
      }
      const config = configuration(encoded);
      if (config.adapter !== "entra") throw failed();
      const main = current;
      if (!main?.account || main.key !== config.key) throw interaction();
      const expectedGeneration = generation;
      const expectedProofGeneration = ++proofGeneration;
      busy = true;
      let candidate;
      try {
        const client = clientFor(config);
        candidate = { client, ready: bounded(client.initialize(), 10000) };
        proofCandidate = candidate;
        await candidate.ready;
        if (generation !== expectedGeneration || current !== main ||
            proofGeneration !== expectedProofGeneration || proofCandidate !== candidate) {
          throw cancelled();
        }
        return await bounded(acceptedProof(client.loginPopup({
          scopes: config.scopes,
          redirectUri: config.redirect,
          nonce,
          prompt: "login",
          claims: JSON.stringify({ id_token: { auth_time: { essential: true } } }),
          extraQueryParameters: { max_age: "0" },
        }), candidate, main, expectedGeneration, expectedProofGeneration,
        config.scopes), 180000);
      } finally {
        if (proofCandidate === candidate) proofCandidate = null;
        try {
          if (candidate) await bounded(candidate.client.clearCache(), 10000);
        } finally {
          busy = false;
        }
      }
    }),
    cancelProof: () => response(async () => { await cancelProof(); }),
    clear: () => response(async () => { await clear(); }),
    endSession: (encoded) => response(async () => {
      if (busy) throw failed();
      const config = configuration(encoded);
      busy = true;
      try {
        await clear();
        const client = clientFor(config);
        await bounded(client.initialize(), 10000);
        try {
          await bounded(client.logoutPopup({
            postLogoutRedirectUri: config.redirect,
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
