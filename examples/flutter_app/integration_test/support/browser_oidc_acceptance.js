/* Test-page-only driver; the ordinary auth.js bundle has no fixture adapter. */
const auth = window.cosmosSyncAuth;
const checks = [];
let stage = "startup";

function check(name, accepted) {
  stage = name;
  if (!accepted || checks.includes(name)) throw new Error("Fixture assertion failed");
  checks.push(name);
}

async function jsonRequest(url, options = {}) {
  const response = await fetch(url, {
    ...options, credentials: "omit", cache: "no-store",
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error("Fixture control failed");
  return response.status === 204 ? null : response.json();
}

async function run() {
  const fixture = await jsonRequest("/fixture");
  const config = {
    issuer: fixture.issuer, clientId: fixture.clientId,
    redirectUrl: fixture.redirectUrl, discoveryUrl: fixture.discoveryUrl,
    scopes: fixture.scopes, browserAdapter: "oidc",
  };
  const encoded = JSON.stringify(config);
  const result = async (action) => JSON.parse(await action);
  const options = async (mode = "normal", subject = "alice") => {
    stage = mode;
    await jsonRequest(`${fixture.issuer}/_fixture/options`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ mode, subject }),
    });
  };
  const signIn = async (mode = "normal", subject = "alice") => {
    await options(mode, subject);
    return result(auth.signIn(encoded));
  };
  const session = async (token) => fetch(`${fixture.url}/v1/session`, {
    headers: { Authorization: `Bearer ${token}` },
    credentials: "omit", signal: AbortSignal.timeout(10000),
  });
  const receipt = () => jsonRequest(`${fixture.issuer}/_fixture/receipt`);
  const waitForCount = async (name, previous) => {
    const deadline = Date.now() + 10000;
    while ((await receipt())[name] <= previous) {
      if (Date.now() > deadline) throw new Error("Fixture stage timed out");
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  };

  const signed = await signIn();
  check("code_s256_nonce_signed_id", signed.ok === true &&
    signed.scopes.length === 1 && signed.scopes[0] === "cosmos_sync" &&
    JSON.stringify(Object.keys(signed).sort()) ===
      JSON.stringify(["accessToken", "expiresAt", "ok", "scopes", "tokenType"]));
  const initial = await session(signed.accessToken);
  const alice = await initial.json();
  check("api_jwt_bff_authority", initial.status === 200 &&
    /^[0-9a-f]{64}$/.test(alice.scopeId) && /^[0-9a-f]{64}$/.test(alice.principalId));
  await options("refresh-no-id");
  const renewed = await result(auth.refresh(encoded));
  check("memory_refresh_no_id", renewed.ok === true &&
    !("idToken" in renewed) && !("refreshToken" in renewed) &&
    (await session(renewed.accessToken)).status === 200);
  check("no_persistent_credentials", localStorage.length === 0 && sessionStorage.length === 0);
  await auth.clear();

  for (const [mode, name] of [
    ["bad-id-issuer", "denied_id_issuer"],
    ["bad-id-audience", "denied_id_audience"],
    ["bad-id-signature", "denied_id_signature"],
    ["bad-id-nonce", "denied_id_nonce"],
    ["bad-state", "denied_state"],
  ]) {
    const denied = await signIn(mode);
    check(name, denied.ok === false && !("accessToken" in denied) &&
      (await result(auth.refresh(encoded))).ok === false);
  }
  for (const [mode, name, expected] of [
    ["bad-api-issuer", "denied_api_issuer", 401],
    ["bad-api-audience", "denied_api_audience", 401],
    ["bad-api-scope", "denied_api_scope", 403],
  ]) {
    const untrustedAPI = await signIn(mode);
    check(name, untrustedAPI.ok === true &&
      (await session(untrustedAPI.accessToken)).status === expected);
    await auth.clear();
  }

  const noRefresh = await signIn("no-refresh");
  const silent = await result(auth.refresh(encoded));
  check("no_refresh_no_iframe", noRefresh.ok === true &&
    silent.ok === false && silent.kind === "interactionRequired" &&
    document.querySelectorAll("iframe").length === 0);
  await signIn();
  await options("refresh-subject-switch");
  const switched = await result(auth.refresh(encoded));
  check("refresh_subject_switch", switched.ok === false &&
    (await result(auth.refresh(encoded))).kind === "interactionRequired");
  await signIn();
  await options("invalid-refresh");
  const invalidRefresh = await result(auth.refresh(encoded));
  check("invalid_refresh", invalidRefresh.ok === false &&
    invalidRefresh.kind === "interactionRequired");

  for (const [mode, counter, name] of [
    ["slow-authorization", "authorization_requests", "popup_cancel_fenced"],
    ["slow-token", "code_exchanges", "token_cancel_fenced"],
  ]) {
    await options(mode);
    const before = (await receipt())[counter] ?? 0;
    const pending = auth.signIn(encoded);
    await waitForCount(counter, before);
    await auth.clear();
    const cancelled = await result(pending);
    check(name, cancelled.ok === false && cancelled.kind === "cancelled" &&
      (await result(auth.refresh(encoded))).kind === "interactionRequired");
  }

  const before = (await receipt()).authorization_requests;
  const wrongCallback = await result(auth.signIn(JSON.stringify({
    ...config, redirectUrl: `${location.origin}/auth-redirect.html`,
  })));
  const wrongAdapter = await result(auth.signIn(JSON.stringify({
    ...config, browserAdapter: "entra",
  })));
  check("callback_adapter_pinning", !wrongCallback.ok && !wrongAdapter.ok &&
    (await receipt()).authorization_requests === before);

  const bobLogin = await signIn("normal", "bob");
  const bobResponse = await session(bobLogin.accessToken);
  const bob = await bobResponse.json();
  check("independent_subject_sessions", bobResponse.status === 200 &&
    bob.scopeId !== alice.scopeId && bob.principalId !== alice.principalId);
  await options();
  const logout = await result(auth.endSession(encoded));
  check("provider_logout", logout.ok === true &&
    (await result(auth.refresh(encoded))).kind === "interactionRequired" &&
    localStorage.length === 0 && sessionStorage.length === 0);
  await options();
}

run().then(async () => {
  await jsonRequest("/protocol-result", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ passed: true, checks, auth: "actual_generic_oidc_popup" }),
  });
  location.replace("/");
}).catch(async () => {
  await fetch("/protocol-result", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      passed: false, checks, auth: "actual_generic_oidc_popup", failure_stage: stage,
    }),
  });
});
