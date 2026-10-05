import assert from "node:assert/strict";
import test from "node:test";
import { Worker } from "node:worker_threads";
import { createBrowserAuth } from "./auth_core.js";

const issuer =
  "https://example.ciamlogin.com/11111111-1111-4111-8111-111111111111/v2.0";
const config = {
  issuer,
  clientId: "22222222-2222-4222-8222-222222222222",
  redirectUrl: "https://app.example.test/workspace/auth-redirect.html",
  discoveryUrl: `${issuer}/.well-known/openid-configuration`,
  scopes: ["openid", "profile", "offline_access", "api://bff/Cosmos.Sync"],
};
const encode = (value = config) => JSON.stringify(value);
const success = (overrides = {}) => ({
  accessToken: "fixture.api.token",
  idToken: "fixture.id.token",
  refreshToken: "fixture.private.refresh",
  expiresOn: new Date(Date.now() + 3600000),
  tokenType: "Bearer",
  scopes: ["api://bff/Cosmos.Sync"],
  account: {
    homeAccountId: "fixture.home",
    localAccountId: "fixture.object",
    tenantId: "fixture.tenant",
  },
  ...overrides,
});
const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};

function fixture({
  secureContext = true,
  initialize = async () => {},
  logout = async () => {},
  login = async () => success(),
} = {}) {
  const clients = [];
  let options;
  const auth = createBrowserAuth({
    secureContext,
    baseUri: "https://app.example.test/workspace/",
    createClient: (value) => {
      options = value;
      const index = clients.length;
      const client = {
        clears: 0,
        initialize,
        loginPopup: async (request) => {
          client.loginRequest = request;
          return login(request, index);
        },
        acquireTokenSilent: async (request) => {
          client.refreshRequest = request;
          return success({ accessToken: "fixture.rotated.token" });
        },
        logoutPopup: async (request) => {
          client.logoutRequest = request;
          await logout(request);
        },
        clearCache: async () => { client.clears++; },
      };
      clients.push(client);
      return client;
    },
  });
  return {
    auth, clients,
    get options() { return options; },
  };
}
const decode = async (promise) => JSON.parse(await promise);

test("uses supported MSAL5 memory-only popup configuration and no secret", async () => {
  const f = fixture();
  assert.equal((await decode(f.auth.signIn(encode()))).ok, true);
  // MSAL opens a BroadcastChannel, including in Node. Isolate the constructor
  // check and release its worker instead of leaking a browser-lifetime channel.
  const worker = new Worker(new URL("./msal-config.worker.js", import.meta.url), {
    workerData: JSON.stringify(f.options),
  });
  let timer;
  let actual;
  try {
    actual = await new Promise((resolve, reject) => {
      worker.once("message", resolve);
      worker.once("error", reject);
      timer = setTimeout(() => reject(new Error("MSAL constructor timed out.")), 10000);
    });
  } finally {
    clearTimeout(timer);
    await worker.terminate();
  }
  assert.equal(actual.cache.cacheLocation, "memoryStorage");
  assert.equal(actual.system.popupBridgeTimeout, 180000);
  assert.equal(actual.system.iframeBridgeTimeout, 10000);
  assert.equal(actual.system.allowPlatformBroker, false);
  assert.equal(actual.system.serverTelemetryEnabled, false);
  assert.equal(actual.auth.redirectUri, config.redirectUrl);
  assert.deepEqual(actual.auth.knownAuthorities, ["example.ciamlogin.com"]);
  assert.equal(actual.auth.authority, issuer.replace("/v2.0", ""));
  assert.equal("clientSecret" in actual.auth, false);
  assert.deepEqual(f.clients[0].loginRequest.scopes, ["api://bff/Cosmos.Sync"]);
  assert.equal(f.clients[0].loginRequest.prompt, "select_account");
  const output = await f.auth.signIn(encode());
  assert.equal(output.includes("refreshToken"), false);
  assert.equal(output.includes("homeAccountId"), false);
  assert.equal(output.includes("idToken"), false);
  await f.auth.clear();
});

test("silent refresh stays inside MSAL, selects the same account and forces renewal", async () => {
  const f = fixture();
  await f.auth.signIn(encode());
  const renewed = await decode(f.auth.refresh(encode()));
  assert.equal(renewed.accessToken, "fixture.rotated.token");
  assert.equal(f.clients[0].refreshRequest.forceRefresh, true);
  assert.equal(f.clients[0].refreshRequest.account.homeAccountId, "fixture.home");
  assert.equal("refreshToken" in f.clients[0].refreshRequest, false);
  await f.auth.clear();
  assert.equal(f.clients[0].clears, 1);
  assert.deepEqual(await decode(f.auth.refresh(encode())), {
    ok: false, kind: "interactionRequired",
  });
});

test("a fresh document cannot restore a previous session", async () => {
  const first = fixture();
  await first.auth.signIn(encode());
  const reloaded = fixture();
  assert.deepEqual(await decode(reloaded.auth.refresh(encode())), {
    ok: false, kind: "interactionRequired",
  });
  assert.equal(reloaded.clients.length, 0);
  await first.auth.clear();
});

test("rejects mismatched origins, ports, callback paths, issuers and discovery", async () => {
  for (const changes of [
    { redirectUrl: "https://different.example.test/workspace/auth-redirect.html" },
    { redirectUrl: "https://app.example.test:444/workspace/auth-redirect.html" },
    { redirectUrl: "https://app.example.test/auth-redirect.html" },
    { redirectUrl: `${config.redirectUrl}?code=unexpected` },
    { issuer: issuer.replace("example.ciamlogin.com", "ciamlogin.com.evil.test") },
    { issuer: issuer.replace("/11111111-1111-4111-8111-111111111111/", "/common/") },
    { discoveryUrl: "https://different.example.test/.well-known/openid-configuration" },
    { postLogoutRedirectUrl: "https://different.example.test/logout" },
    { clientId: "not-a-client-id" },
    { scopes: ["openid", "profile"] },
    { scopes: ["openid", "api://bff/Cosmos.Sync", "api://bff/Cosmos.Sync"] },
    { provider: "arbitrary-provider" },
  ]) {
    const f = fixture();
    assert.deepEqual(await decode(f.auth.signIn(encode({ ...config, ...changes }))), {
      ok: false, kind: "failed",
    });
    assert.equal(f.clients.length, 0);
  }
  const insecure = fixture({ secureContext: false });
  assert.deepEqual(await decode(insecure.auth.signIn(encode())), {
    ok: false, kind: "failed",
  });
  assert.equal(insecure.clients.length, 0);
});

test("cancellation drops late callbacks and clears their private MSAL cache", async () => {
  const f = fixture();
  const pending = deferred();
  const first = f.auth.signIn(encode());
  await new Promise((resolve) => setImmediate(resolve));
  await first;
  const originalFactoryClient = f.clients[0];
  await f.auth.clear();
  assert.equal(originalFactoryClient.clears, 1);

  const controlled = createBrowserAuth({
    baseUri: "https://app.example.test/workspace/",
    secureContext: true,
    createClient: () => ({
      initialize: async () => {},
      loginPopup: () => pending.promise,
      clearCache: async () => { originalFactoryClient.clears++; },
    }),
  });
  const result = controlled.signIn(encode());
  await new Promise((resolve) => setImmediate(resolve));
  await controlled.clear();
  pending.resolve(success());
  assert.deepEqual(await decode(result), { ok: false, kind: "cancelled" });
  assert.equal(originalFactoryClient.clears, 3);
  assert.deepEqual(await decode(controlled.refresh(encode())), {
    ok: false, kind: "interactionRequired",
  });
});

test("provider and popup errors never return raw messages, URLs, tokens or account data", async () => {
  for (const [errorCode, expected] of [
    ["user_cancelled", "cancelled"],
    ["popup_window_error", "cancelled"],
    ["network_error", "transient"],
    ["invalid_grant", "interactionRequired"],
    ["nonce_mismatch", "failed"],
  ]) {
    const f = fixture();
    await f.auth.signIn(encode());
    f.clients[0].acquireTokenSilent = async () => {
      throw { errorCode, message: "sensitive@example.test code=secret-token" };
    };
    assert.deepEqual(await decode(f.auth.refresh(encode())), {
      ok: false, kind: expected,
    });
    await f.auth.clear();
  }
});

test("missing API scopes, expired tokens and account switches invalidate refresh", async () => {
  for (const overrides of [
    { scopes: ["openid", "profile"] },
    { accessToken: "" },
    { tokenType: "POP" },
    { expiresOn: new Date(Date.now() + 29999) },
    { account: { ...success().account, homeAccountId: "different.home" } },
    { account: { ...success().account, localAccountId: "different.object" } },
    { account: { ...success().account, tenantId: "different.tenant" } },
  ]) {
    const f = fixture();
    await f.auth.signIn(encode());
    f.clients[0].acquireTokenSilent = async () => success(overrides);
    assert.deepEqual(await decode(f.auth.refresh(encode())), {
      ok: false, kind: "interactionRequired",
    });
    assert.equal(f.clients[0].clears, 1);
  }
});

test("changing client configuration cannot renew the old MSAL account", async () => {
  const f = fixture();
  await f.auth.signIn(encode());
  assert.deepEqual(await decode(f.auth.refresh(encode({
    ...config, clientId: "33333333-3333-4333-8333-333333333333",
  }))), { ok: false, kind: "interactionRequired" });
  assert.equal(f.clients[0].refreshRequest, undefined);
  await f.auth.clear();
});

test("a concurrent popup is rejected and optional provider logout uses the pinned bridge", async () => {
  const pending = deferred();
  const f = fixture();
  await f.auth.signIn(encode());
  f.clients[0].acquireTokenSilent = () => pending.promise;
  const refresh = f.auth.refresh(encode());
  assert.deepEqual(await decode(f.auth.signIn(encode())), {
    ok: false, kind: "failed",
  });
  pending.resolve(success());
  assert.equal((await decode(refresh)).ok, true);
  assert.equal((await decode(f.auth.endSession(encode()))).ok, true);
  assert.equal(f.clients[1].logoutRequest.postLogoutRedirectUri, config.redirectUrl);
  assert.equal(f.clients[1].clears, 1);
});

test("a provider navigation hint never changes the credential configuration or refresh request", async () => {
  const f = fixture();
  await f.auth.signIn(encode({ ...config, provider: "apple" }));
  assert.deepEqual(f.clients[0].loginRequest.extraQueryParameters, { domain_hint: "apple" });
  assert.equal((await decode(f.auth.refresh(encode()))).ok, true);
  assert.equal(f.clients[0].refreshRequest.extraQueryParameters, undefined);
  await f.auth.clear();
});

test("initialization timeout cannot hang cleanup or launch a late popup", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const pending = deferred();
  const f = fixture({ initialize: () => pending.promise });
  const result = f.auth.signIn(encode());
  await new Promise((resolve) => setImmediate(resolve));
  t.mock.timers.tick(10000);
  assert.deepEqual(await decode(result), { ok: false, kind: "transient" });
  assert.equal(f.clients[0].clears, 1);
  pending.resolve();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(f.clients[0].loginRequest, undefined);
  assert.deepEqual(await decode(f.auth.refresh(encode())), {
    ok: false, kind: "interactionRequired",
  });
});

test("initialization rejection clears memory and exposes only a fixed failure", async () => {
  const f = fixture({
    initialize: async () => {
      throw { errorCode: "network_error", message: "sensitive@example.test token=secret" };
    },
  });
  assert.deepEqual(await decode(f.auth.signIn(encode())), {
    ok: false, kind: "transient",
  });
  assert.equal(f.clients[0].clears, 1);
  assert.equal(f.clients[0].loginRequest, undefined);
  assert.equal((await decode(f.auth.clear())).ok, true);
});

test("a cleanup timeout is reported and cannot retain a renewable session", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const f = fixture();
  await f.auth.signIn(encode());
  f.clients[0].clearCache = () => new Promise(() => {});
  const result = f.auth.clear();
  await new Promise((resolve) => setImmediate(resolve));
  t.mock.timers.tick(10000);
  assert.deepEqual(await decode(result), { ok: false, kind: "transient" });
  assert.deepEqual(await decode(f.auth.refresh(encode())), {
    ok: false, kind: "interactionRequired",
  });
});

test("a failed provider logout still clears its temporary SDK instance", async () => {
  const f = fixture({
    logout: async () => { throw { errorCode: "user_cancelled" }; },
  });
  await f.auth.signIn(encode());
  assert.deepEqual(await decode(f.auth.endSession(encode())), {
    ok: false, kind: "cancelled",
  });
  assert.equal(f.clients[0].clears, 1);
  assert.equal(f.clients[1].clears, 1);
  assert.deepEqual(await decode(f.auth.refresh(encode())), {
    ok: false, kind: "interactionRequired",
  });
});

test("fresh proof uses an isolated memory client and never replaces the main account", async () => {
    const f = fixture({
      login: async (_, index) => success(index === 0 ? {} : {
        account: { ...success().account, homeAccountId: "independent.home" },
      }),
    });
    await f.auth.signIn(encode());
    const proof = await decode(f.auth.freshProof(encode(), "f".repeat(64)));
    assert.equal(proof.ok, true);
    assert.equal(proof.idToken, "fixture.id.token");
    assert.equal("account" in proof, false);
    assert.equal("refreshToken" in proof, false);
    assert.equal(f.clients[0].clears, 0);
    assert.equal(f.clients[1].clears, 1);
    const request = f.clients[1].loginRequest;
    assert.equal(request.nonce, "f".repeat(64));
    assert.equal(request.prompt, "login");
    assert.deepEqual(JSON.parse(request.claims), { id_token: { auth_time: { essential: true } } });
    assert.deepEqual(request.extraQueryParameters, { max_age: "0" });
    assert.equal((await decode(f.auth.refresh(encode()))).ok, true);
    assert.equal(f.clients[0].refreshRequest.account.homeAccountId, "fixture.home");
    await f.auth.clear();
  });

test("proof cancellation rejects late credentials without signing out the main account", async () => {
    const pending = deferred();
    const f = fixture({ login: async (_, index) => index === 0 ? success() : pending.promise });
    await f.auth.signIn(encode());
    const proof = f.auth.freshProof(encode(), "f".repeat(64));
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(await decode(f.auth.refresh(encode())), { ok: false, kind: "failed" });
    assert.equal((await decode(f.auth.cancelProof())).ok, true);
    pending.resolve(success());
    assert.deepEqual(await decode(proof), { ok: false, kind: "cancelled" });
    assert.ok(f.clients[1].clears >= 2);
    assert.equal(f.clients[0].clears, 0);
    assert.equal((await decode(f.auth.refresh(encode()))).ok, true);
    await f.auth.clear();
  });

test("signout invalidates an in-flight isolated proof and both private caches", async () => {
    const pending = deferred();
    const f = fixture({ login: async (_, index) => index === 0 ? success() : pending.promise });
    await f.auth.signIn(encode());
    const proof = f.auth.freshProof(encode(), "f".repeat(64));
    await new Promise((resolve) => setImmediate(resolve));
    await f.auth.clear();
    pending.resolve(success());
    assert.deepEqual(await decode(proof), { ok: false, kind: "cancelled" });
    assert.equal(f.clients[0].clears, 1);
    assert.ok(f.clients[1].clears >= 2);
    assert.deepEqual(await decode(f.auth.refresh(encode())), { ok: false, kind: "interactionRequired" });
  });

test("proof rejects a client nonce, wrong configuration and missing ID proof without changing main login", async () => {
    const f = fixture({ login: async (_, index) => success(index === 0 ? {} : { idToken: "" }) });
    await f.auth.signIn(encode());
    assert.deepEqual(await decode(f.auth.freshProof(encode(), "client-nonce")), { ok: false, kind: "failed" });
    assert.equal(f.clients.length, 1);
    assert.deepEqual(await decode(f.auth.freshProof(encode({
      ...config, clientId: "33333333-3333-4333-8333-333333333333",
    }), "f".repeat(64))), { ok: false, kind: "interactionRequired" });
    assert.equal(f.clients.length, 1);
    assert.deepEqual(await decode(f.auth.freshProof(encode(), "f".repeat(64))), { ok: false, kind: "failed" });
    assert.equal(f.clients[1].clears, 1);
    assert.equal(f.clients[0].clears, 0);
    assert.equal((await decode(f.auth.refresh(encode()))).ok, true);
    await f.auth.clear();
  });

test("proof timeout is redacted and a late MSAL result is cleared without changing main login", async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] });
    const pending = deferred();
    const f = fixture({ login: async (_, index) => index === 0 ? success() : pending.promise });
    await f.auth.signIn(encode());
    const proof = f.auth.freshProof(encode(), "f".repeat(64));
    await new Promise((resolve) => setImmediate(resolve));
    t.mock.timers.tick(180000);
    assert.deepEqual(await decode(proof), { ok: false, kind: "transient" });
    pending.resolve(success());
    await new Promise((resolve) => setImmediate(resolve));
    assert.ok(f.clients[1].clears >= 2);
    assert.equal(f.clients[0].clears, 0);
    assert.equal((await decode(f.auth.refresh(encode()))).ok, true);
    await f.auth.clear();
});
