import {
  InMemoryWebStorage, Log, UserManager, WebStorageStateStore,
} from "oidc-client-ts";

async function completePopup() {
  const responseUrl = location.href;
  const callback = new URL("oidc-redirect.html", document.baseURI).href;
  history.replaceState(null, "", callback);
  Log.setLevel(Log.NONE);
  // These public transport settings perform no discovery or authentication.
  // The opener verifies its own transaction, PKCE, nonce and signed tokens.
  const manager = new UserManager({
    authority: location.origin,
    client_id: "cosmos-sync-popup-bridge",
    redirect_uri: callback,
    userStore: new WebStorageStateStore({ store: new InMemoryWebStorage() }),
    stateStore: new WebStorageStateStore({ store: new InMemoryWebStorage() }),
    automaticSilentRenew: false,
    monitorSession: false,
    loadUserInfo: false,
  });
  await manager.signinPopupCallback(responseUrl);
}

completePopup().catch(() => {
  document.getElementById("auth-status").textContent =
    "Sign-in could not be completed. Close this window and retry in the workspace.";
});
