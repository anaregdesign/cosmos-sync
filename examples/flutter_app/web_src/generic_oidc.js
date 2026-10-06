import {
  ErrorTimeout, InMemoryWebStorage, Log, UserManager, WebStorageStateStore,
} from "oidc-client-ts";
import { createRemoteJWKSet, customFetch, jwtVerify } from "jose";

const algorithms = ["RS256", "RS384", "RS512", "ES256", "ES384", "ES512"];
const cancelled = () => ({ errorCode: "user_cancelled" });
const invalid = () => ({ errorCode: "invalid_configuration" });
const interaction = () => ({ errorCode: "interaction_required" });
const network = () => ({ errorCode: "network_error" });

function httpsEndpoint(value) {
  if (typeof value !== "string" || value.length > 2048) throw invalid();
  const uri = new URL(value);
  if (uri.protocol !== "https:" || uri.username || uri.password || uri.hash) {
    throw invalid();
  }
  return uri.href;
}

function randomNonce() {
  return [...crypto.getRandomValues(new Uint8Array(32))]
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function safeFailure(error) {
  if (error?.errorCode) return { errorCode: error.errorCode };
  if (["login_required", "consent_required", "interaction_required", "invalid_grant"]
      .includes(error?.error)) return interaction();
  if (error?.name === "AbortError") return cancelled();
  if (["Popup closed by user", "Popup closed", "Popup aborted",
    "Attempted to navigate on a disposed window"].includes(error?.message)) {
    return cancelled();
  }
  if (error instanceof ErrorTimeout ||
      error?.name === "TimeoutError" || error?.code === "ERR_JWKS_TIMEOUT") {
    return { errorCode: "timed_out" };
  }
  return { errorCode: "invalid_response" };
}

class GuardedMemoryStorage extends InMemoryWebStorage {
  constructor(active) {
    super();
    this.active = active;
  }

  setItem(key, value) {
    if (!this.active()) throw cancelled();
    super.setItem(key, value);
  }

  getItem(key) {
    return super.getItem(key) ?? null;
  }
}

async function discoveryJSON(response) {
  if (!response.ok || !response.body) throw network();
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > 65536) throw invalid();
      chunks.push(value);
    }
  } finally {
    await reader.cancel();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}

export function createGenericOidcClient(config, {
  createManager = (settings) => new UserManager(settings),
  fetcher = globalThis.fetch,
} = {}) {
  Log.setLevel(Log.NONE);
  const lifetime = new AbortController();
  let closed = false;
  let manager;
  let metadata;
  let keys;
  let ready;
  let identity;
  let nonce;
  const active = () => !closed;
  const users = new GuardedMemoryStorage(active);
  const states = new GuardedMemoryStorage(active);
  const assertActive = () => { if (closed) throw cancelled(); };

  async function trustedFetch(url, options = {}) {
    try {
      return await fetcher(url, {
        ...options, credentials: "omit", redirect: "error", cache: "no-store",
        signal: AbortSignal.any([
          lifetime.signal, options.signal ?? AbortSignal.timeout(10000),
        ]),
      });
    } catch (error) {
      if (closed) throw cancelled();
      if (error?.name === "TimeoutError") throw { errorCode: "timed_out" };
      throw network();
    }
  }

  async function initialize() {
    assertActive();
    if (!ready) ready = (async () => {
      const discovery = await discoveryJSON(await trustedFetch(config.discoveryUrl, {
        headers: { Accept: "application/json" },
      }));
      assertActive();
      if (discovery?.issuer !== config.issuer ||
          !Array.isArray(discovery.id_token_signing_alg_values_supported) ||
          !discovery.id_token_signing_alg_values_supported.some((alg) => algorithms.includes(alg)) ||
          (discovery.response_types_supported != null &&
            !discovery.response_types_supported.includes("code")) ||
          (discovery.code_challenge_methods_supported != null &&
            !discovery.code_challenge_methods_supported.includes("S256")) ||
          (discovery.token_endpoint_auth_methods_supported != null &&
            !discovery.token_endpoint_auth_methods_supported.includes("none"))) {
        throw invalid();
      }
      metadata = {
        issuer: config.issuer,
        authorization_endpoint: httpsEndpoint(discovery.authorization_endpoint),
        token_endpoint: httpsEndpoint(discovery.token_endpoint),
        jwks_uri: httpsEndpoint(discovery.jwks_uri),
        id_token_signing_alg_values_supported: discovery.id_token_signing_alg_values_supported,
        ...(discovery.end_session_endpoint == null ? {} : {
          end_session_endpoint: httpsEndpoint(discovery.end_session_endpoint),
        }),
      };
      keys = createRemoteJWKSet(new URL(metadata.jwks_uri), {
        timeoutDuration: 10000,
        [customFetch]: trustedFetch,
      });
      manager = createManager({
        authority: config.issuer,
        client_id: config.clientId,
        redirect_uri: config.redirectUri,
        post_logout_redirect_uri: config.postLogoutRedirectUri,
        popup_post_logout_redirect_uri: config.postLogoutRedirectUri,
        silent_redirect_uri: "",
        response_type: "code",
        scope: config.scopes.join(" "),
        metadata,
        userStore: new WebStorageStateStore({ store: users }),
        stateStore: new WebStorageStateStore({ store: states }),
        automaticSilentRenew: false,
        monitorSession: false,
        loadUserInfo: false,
        validateSubOnSilentRenew: true,
        includeIdTokenInSilentRenew: false,
        revokeTokensOnSignout: false,
        disablePKCE: false,
        fetchRequestCredentials: "omit",
        requestTimeoutInSeconds: 10,
        silentRequestTimeoutInSeconds: 20,
        popupWindowTarget: "_blank",
      });
    })();
    try {
      await ready;
    } catch (error) {
      throw safeFailure(error);
    }
  }

  async function verifyID(user, initial) {
    if (typeof user?.id_token !== "string" || user.id_token.length > 16384 ||
        !user.id_token || user.id_token === user.access_token) throw interaction();
    let verified;
    try {
      verified = await jwtVerify(user.id_token, keys, {
        issuer: config.issuer,
        audience: config.clientId,
        algorithms: algorithms.filter((alg) =>
          metadata.id_token_signing_alg_values_supported.includes(alg)),
        requiredClaims: ["iss", "aud", "sub", "exp", "iat", ...(initial ? ["nonce"] : [])],
      });
    } catch (error) {
      if (error?.errorCode || error?.code === "ERR_JWKS_TIMEOUT") {
        throw safeFailure(error);
      }
      throw interaction();
    }
    assertActive();
    const { payload, protectedHeader } = verified;
    if (typeof payload.sub !== "string" || !payload.sub || payload.sub.length > 256 ||
        !Number.isInteger(payload.exp) || !Number.isInteger(payload.iat) ||
        payload.iat > Math.floor(Date.now() / 1000) ||
        (payload.nbf != null && !Number.isInteger(payload.nbf)) ||
        ((initial || payload.nonce != null) && payload.nonce !== nonce) ||
        (payload.azp != null && payload.azp !== config.clientId) ||
        (Array.isArray(payload.aud) && payload.aud.length > 1 && payload.azp !== config.clientId) ||
        (identity && payload.sub !== identity.subject) ||
        user.profile?.sub !== payload.sub) {
      throw interaction();
    }
    if (payload.at_hash != null) {
      const hash = new Uint8Array(await crypto.subtle.digest(
        `SHA-${protectedHeader.alg.slice(2)}`, new TextEncoder().encode(user.access_token),
      ));
      const expected = btoa(String.fromCharCode(...hash.slice(0, hash.length / 2)))
        .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
      if (payload.at_hash !== expected) throw interaction();
    }
    assertActive();
    identity = { subject: payload.sub, idToken: user.id_token };
  }

  function ordinaryResult(user) {
    assertActive();
    if (!identity || user?.profile?.sub !== identity.subject ||
        !Number.isInteger(user.expires_at) ||
        user.expires_at * 1000 <= Date.now() + 30000) throw interaction();
    return {
      accessToken: user.access_token,
      tokenType: user.token_type,
      scopes: user.scopes,
      expiresOn: new Date(user.expires_at * 1000),
      account: {
        homeAccountId: identity.subject,
        localAccountId: identity.subject,
        tenantId: config.issuer,
      },
    };
  }

  async function operation(action) {
    try {
      assertActive();
      return await action();
    } catch (error) {
      if (closed) throw cancelled();
      throw safeFailure(error);
    }
  }

  function cancel() {
    closed = true;
    lifetime.abort();
    users.clear();
    states.clear();
    identity = null;
    nonce = null;
  }

  return Object.freeze({
    initialize,
    loginPopup: () => operation(async () => {
      nonce = randomNonce();
      const user = await manager.signinPopup({
        nonce, popupSignal: lifetime.signal, popupAbortOnClose: true,
      });
      await verifyID(user, true);
      return ordinaryResult(user);
    }),
    acquireTokenSilent: () => operation(async () => {
      const previous = await manager.getUser();
      assertActive();
      if (!identity || !previous?.refresh_token) throw interaction();
      const user = await manager.signinSilent();
      assertActive();
      if (user.id_token !== identity.idToken) await verifyID(user, false);
      return ordinaryResult(user);
    }),
    logoutPopup: () => operation(async () => {
      if (!metadata.end_session_endpoint) throw { errorCode: "logout_unavailable" };
      await manager.signoutPopup({
        popupSignal: lifetime.signal, popupAbortOnClose: true,
      });
      assertActive();
    }),
    cancel,
    clearCache: async () => {
      cancel();
      if (manager) await manager.removeUser();
    },
  });
}
