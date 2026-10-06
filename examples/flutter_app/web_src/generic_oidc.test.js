import assert from "node:assert/strict";
import test from "node:test";
import { createHash } from "node:crypto";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { createBrowserAuth } from "./auth_core.js";
import { createGenericOidcClient } from "./generic_oidc.js";

const issuer = "https://issuer.example.test/realm";
const clientId = "non-uuid-browser-client";
const config = {
  issuer, clientId, browserAdapter: "oidc",
  redirectUrl: "https://app.example.test/workspace/oidc-redirect.html",
  discoveryUrl: `${issuer}/discovery`,
  scopes: ["openid", "offline_access", "cosmos_sync"],
};
const key = await generateKeyPair("RS256", { modulusLength: 2048 });
const otherKey = await generateKeyPair("RS256", { modulusLength: 2048 });
const jwk = { ...await exportJWK(key.publicKey), kid: "fixture-key", alg: "RS256", use: "sig" };
const encode = (value = config) => JSON.stringify(value);
const decode = async (promise) => JSON.parse(await promise);
const tick = () => new Promise((resolve) => setImmediate(resolve));
const deferred = () => {
  let resolve;
  const promise = new Promise((yes) => { resolve = yes; });
  return { promise, resolve };
};

function fixture({
  claims = {}, refreshClaims = {}, discovery = {}, scopes = config.scopes,
  omitRefresh = false, reuseID = false, badSignature = false,
  loginWait, initializeWait, loginError, clearError,
} = {}) {
  const clients = [];
  const requests = [];
  const metadata = {
    issuer, authorization_endpoint: `${issuer}/authorize`,
    token_endpoint: `${issuer}/token`, jwks_uri: `${issuer}/jwks`,
    end_session_endpoint: `${issuer}/logout`,
    id_token_signing_alg_values_supported: ["RS256"],
    response_types_supported: ["code"],
    code_challenge_methods_supported: ["S256"],
    token_endpoint_auth_methods_supported: ["none"],
    ...discovery,
  };
  const auth = createBrowserAuth({
    baseUri: "https://app.example.test/workspace/",
    secureContext: true,
    createClient: () => { throw new Error("Generic selection must not construct MSAL"); },
    createGenericClient: (options) => createGenericOidcClient(options, {
      fetcher: async (url, request) => {
        requests.push({ url: String(url), request });
        if (String(url) === config.discoveryUrl) {
          if (initializeWait) await initializeWait.promise;
          return new Response(JSON.stringify(metadata), { headers: { "Content-Type": "application/json" } });
        }
        assert.equal(String(url), `${issuer}/jwks`);
        return new Response(JSON.stringify({ keys: [jwk] }), {
          headers: { "Content-Type": "application/json" },
        });
      },
      createManager: (settings) => {
        let current = null;
        let nonce;
        const state = { settings, renewals: 0, clears: 0, logout: 0 };
        clients.push(state);
        async function user(overrides, initial) {
          const payload = {
            iss: issuer, aud: clientId, sub: "alice",
            exp: Math.floor(Date.now() / 1000) + 3600,
            iat: Math.floor(Date.now() / 1000) - 1,
            ...(initial ? { nonce } : {}),
            ...overrides,
          };
          for (const [name, value] of Object.entries(payload)) {
            if (value === undefined) delete payload[name];
          }
          const id = await new SignJWT(payload)
            .setProtectedHeader({ alg: "RS256", kid: "fixture-key" })
            .sign(badSignature ? otherKey.privateKey : key.privateKey);
          const result = {
            id_token: reuseID && !initial ? current.id_token : id,
            access_token: initial ? "fixture.api.token" : "fixture.rotated.api",
            refresh_token: omitRefresh ? undefined : "fixture.private.refresh",
            profile: { sub: payload.sub },
            token_type: "Bearer",
            scopes,
            expires_at: Math.floor(Date.now() / 1000) + 3600,
          };
          await settings.userStore.set("fixture-user", JSON.stringify(result));
          current = result;
          return result;
        }
        return {
          signinPopup: async (request) => {
            state.loginRequest = request;
            nonce = request.nonce;
            await settings.stateStore.set("fixture-state", "fixture.private.transaction");
            if (loginWait) await loginWait.promise;
            if (loginError) throw loginError;
            return user(claims, true);
          },
          getUser: async () => current,
          signinSilent: async () => {
            state.renewals++;
            return user(refreshClaims, false);
          },
          signoutPopup: async (request) => {
            state.logoutRequest = request;
            state.logout++;
          },
          removeUser: async () => {
            state.clears++;
            current = null;
            await settings.userStore.remove("fixture-user");
            if (clearError) throw clearError;
          },
        };
      },
    }),
  });
  return { auth, clients, requests };
}

test("generic public client is explicit, memory-only and independently validates signed ID", async () => {
  const f = fixture();
  const output = await decode(f.auth.signIn(encode()));
  assert.equal(output.ok, true);
  assert.equal(output.accessToken, "fixture.api.token");
  assert.deepEqual(Object.keys(output).sort(), [
    "accessToken", "expiresAt", "ok", "scopes", "tokenType",
  ]);
  const client = f.clients[0];
  const settings = client.settings;
  assert.equal(settings.authority, issuer);
  assert.equal(settings.client_id, clientId);
  assert.equal(settings.redirect_uri, config.redirectUrl);
  assert.equal(settings.popup_post_logout_redirect_uri, config.redirectUrl);
  assert.equal(settings.response_type, "code");
  assert.equal(settings.disablePKCE, false);
  assert.equal(settings.automaticSilentRenew, false);
  assert.equal(settings.monitorSession, false);
  assert.equal(settings.loadUserInfo, false);
  assert.equal(settings.includeIdTokenInSilentRenew, false);
  assert.equal(settings.revokeTokensOnSignout, false);
  assert.equal(settings.silent_redirect_uri, "");
  assert.equal(settings.fetchRequestCredentials, "omit");
  assert.equal("client_secret" in settings, false);
  assert.equal("client_authentication" in settings, false);
  assert.match(client.loginRequest.nonce, /^[0-9a-f]{64}$/);
  assert.equal(client.loginRequest.popupAbortOnClose, true);
  assert.ok(client.loginRequest.popupSignal instanceof AbortSignal);
  assert.equal(f.requests.length, 2);
  for (const { request } of f.requests) {
    assert.equal(request.credentials, "omit");
    assert.equal(request.redirect, "error");
    assert.equal(request.cache, "no-store");
  }
  await f.auth.clear();
  assert.equal(client.clears, 1);
  assert.equal(await settings.userStore.get("fixture-user"), null);
  assert.equal(await settings.stateStore.get("fixture-state"), null);
  await assert.rejects(settings.userStore.set("late-user", "fixture.private.refresh"),
    (error) => error.errorCode === "user_cancelled");
});

test("no generic mode, provider intent or configuration mismatch can silently use another adapter", async () => {
  for (const changes of [
    { browserAdapter: undefined },
    { browserAdapter: "unsupported" },
    { provider: "google" },
    { redirectUrl: "https://app.example.test/workspace/auth-redirect.html" },
    { redirectUrl: `${config.redirectUrl}?code=fixture` },
    { redirectUrl: "https://other.example.test/workspace/oidc-redirect.html" },
    { discoveryUrl: "https://other.example.test/discovery" },
    { issuer: "http://issuer.example.test/realm" },
    { clientId: "has whitespace" },
    { scopes: ["openid", "profile"] },
  ]) {
    const f = fixture();
    assert.deepEqual(await decode(f.auth.signIn(encode({ ...config, ...changes }))), {
      ok: false, kind: "failed",
    });
    assert.equal(f.clients.length, 0);
  }
  const f = fixture();
  await f.auth.signIn(encode());
  assert.deepEqual(await decode(f.auth.refresh(encode({
    ...config, discoveryUrl: `${issuer}/other-discovery`,
  }))), { ok: false, kind: "interactionRequired" });
  assert.equal(f.clients[0].renewals, 0);
  assert.deepEqual(await decode(f.auth.freshProof(encode(), "f".repeat(64))), {
    ok: false, kind: "failed",
  });
  assert.equal(f.clients.length, 1);
  await f.auth.clear();
});

test("discovery must match the operator issuer, asymmetric keys and public Code/S256 endpoints", async () => {
  for (const discovery of [
    { issuer: "https://foreign.example.test/realm" },
    { authorization_endpoint: "http://issuer.example.test/authorize" },
    { token_endpoint: "https://credential:secret@issuer.example.test/token" },
    { jwks_uri: "https://issuer.example.test/jwks#untrusted" },
    { id_token_signing_alg_values_supported: ["HS256"] },
    { response_types_supported: ["token"] },
    { code_challenge_methods_supported: ["plain"] },
    { token_endpoint_auth_methods_supported: ["client_secret_basic"] },
  ]) {
    const f = fixture({ discovery });
    assert.deepEqual(await decode(f.auth.signIn(encode())), { ok: false, kind: "failed" });
    assert.equal(f.clients.length, 0);
  }
});

test("bad ID signature, issuer, client audience, nonce, time and authorized party never export credentials", async () => {
  for (const options of [
    { badSignature: true },
    { claims: { iss: "https://foreign.example.test" } },
    { claims: { aud: "another-browser-client" } },
    { claims: { nonce: "unbound" } },
    { claims: { nonce: undefined } },
    { claims: { sub: "" } },
    { claims: { exp: Math.floor(Date.now() / 1000) - 60 } },
    { claims: { iat: Math.floor(Date.now() / 1000) + 60 } },
    { claims: { azp: "another-client" } },
    { claims: { aud: [clientId, "another-audience"] } },
    { claims: { at_hash: "unbound-access-token" } },
  ]) {
    const f = fixture(options);
    assert.deepEqual(await decode(f.auth.signIn(encode())), {
      ok: false, kind: "interactionRequired",
    });
    assert.equal(f.clients[0].clears, 1);
    assert.equal(await f.clients[0].settings.userStore.get("fixture-user"), null);
    assert.deepEqual(await decode(f.auth.refresh(encode())), {
      ok: false, kind: "interactionRequired",
    });
  }
  const atHash = createHash("sha256").update("fixture.api.token").digest()
    .subarray(0, 16).toString("base64url");
  const valid = fixture({ claims: { at_hash: atHash, aud: [clientId, "another-audience"], azp: clientId } });
  assert.equal((await decode(valid.auth.signIn(encode()))).ok, true);
  await valid.auth.clear();
});

test("memory refresh stays on the verified subject without requiring a new ID or iframe", async () => {
  for (const reuseID of [false, true]) {
    const f = fixture({ reuseID });
    await f.auth.signIn(encode());
    const output = await decode(f.auth.refresh(encode()));
    assert.equal(output.ok, true);
    assert.equal(output.accessToken, "fixture.rotated.api");
    assert.equal("idToken" in output, false);
    assert.equal("refreshToken" in output, false);
    assert.equal(f.clients[0].renewals, 1);
    await f.auth.clear();
  }
  const absent = fixture({ omitRefresh: true });
  await absent.auth.signIn(encode());
  assert.deepEqual(await decode(absent.auth.refresh(encode())), {
    ok: false, kind: "interactionRequired",
  });
  assert.equal(absent.clients[0].renewals, 0);
  assert.equal(absent.clients[0].clears, 1);
});

test("refresh invalidates switched or newly untrusted ID and downgraded API scopes", async () => {
  for (const refreshClaims of [
    { sub: "bob" },
    { aud: "another-client" },
    { iss: "https://foreign.example.test" },
    { nonce: "new-unbound-nonce" },
    { azp: "another-client" },
  ]) {
    const f = fixture({ refreshClaims });
    await f.auth.signIn(encode());
    assert.deepEqual(await decode(f.auth.refresh(encode())), {
      ok: false, kind: "interactionRequired",
    });
    assert.equal(f.clients[0].clears, 1);
    assert.deepEqual(await decode(f.auth.refresh(encode())), {
      ok: false, kind: "interactionRequired",
    });
  }
  const scopes = fixture({ scopes: ["openid"] });
  assert.deepEqual(await decode(scopes.auth.signIn(encode())), {
    ok: false, kind: "interactionRequired",
  });
});

test("cancelled popup and late discovery/token work cannot write back into private stores", async () => {
  const loginWait = deferred();
  const f = fixture({ loginWait });
  const result = f.auth.signIn(encode());
  while (!f.clients[0]?.loginRequest) await tick();
  await f.auth.clear();
  assert.equal(f.clients[0].loginRequest.popupSignal.aborted, true);
  loginWait.resolve();
  assert.deepEqual(await decode(result), { ok: false, kind: "cancelled" });
  assert.equal(await f.clients[0].settings.userStore.get("fixture-user"), null);
  assert.equal(await f.clients[0].settings.stateStore.get("fixture-state"), null);

  const initializeWait = deferred();
  const init = fixture({ initializeWait });
  const pending = init.auth.signIn(encode());
  while (!init.requests.length) await tick();
  assert.deepEqual(await decode(init.auth.clear()), { ok: true });
  initializeWait.resolve();
  assert.deepEqual(await decode(pending), { ok: false, kind: "cancelled" });
  assert.equal(init.clients.length, 0);
});

test("popup close, timeout and cleanup failures are fixed and late timeout results are fenced", async (t) => {
  for (const [loginError, kind] of [
    [new Error("Popup closed by user"), "cancelled"],
    [{ error: "invalid_grant", error_description: "fixture.private.detail" }, "interactionRequired"],
    [{ errorCode: "network_error", message: "fixture.private.token" }, "transient"],
  ]) {
    const f = fixture({ loginError });
    assert.deepEqual(await decode(f.auth.signIn(encode())), { ok: false, kind });
  }
  const broken = fixture({ clearError: new Error("fixture.private.cleanup") });
  await broken.auth.signIn(encode());
  assert.deepEqual(await decode(broken.auth.clear()), { ok: false, kind: "failed" });
  assert.deepEqual(await decode(broken.auth.refresh(encode())), {
    ok: false, kind: "interactionRequired",
  });

  const loginWait = deferred();
  const f = fixture({ loginWait });
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const pending = f.auth.signIn(encode());
  while (!f.clients[0]?.loginRequest) await tick();
  t.mock.timers.tick(180001);
  assert.deepEqual(await decode(pending), { ok: false, kind: "transient" });
  loginWait.resolve();
  await tick();
  assert.equal(await f.clients[0].settings.userStore.get("fixture-user"), null);
});

test("optional provider logout uses only the registered bridge and a reload cannot renew", async () => {
  const f = fixture();
  await f.auth.signIn(encode());
  assert.deepEqual(await decode(f.auth.endSession(encode())), { ok: true });
  assert.equal(f.clients.length, 2);
  assert.equal(f.clients[0].clears, 1);
  assert.equal(f.clients[1].logout, 1);
  assert.equal(f.clients[1].settings.post_logout_redirect_uri, config.redirectUrl);
  assert.equal(f.clients[1].clears, 1);
  const reload = fixture();
  assert.deepEqual(await decode(reload.auth.refresh(encode())), {
    ok: false, kind: "interactionRequired",
  });
  assert.equal(reload.clients.length, 0);
});
