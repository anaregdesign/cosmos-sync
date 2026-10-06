import { broadcastResponseToMainFrame } from "@azure/msal-browser/redirect-bridge";

broadcastResponseToMainFrame().catch(() => {
  document.getElementById("auth-status").textContent =
    "Sign-in could not return to the workspace. Close this window and retry.";
});
