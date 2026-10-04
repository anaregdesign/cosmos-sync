import { parentPort, workerData } from "node:worker_threads";
import { PublicClientApplication } from "@azure/msal-browser";

const config = new PublicClientApplication(JSON.parse(workerData)).getConfiguration();
parentPort.postMessage({
  cache: config.cache,
  auth: config.auth,
  system: {
    popupBridgeTimeout: config.system.popupBridgeTimeout,
    iframeBridgeTimeout: config.system.iframeBridgeTimeout,
    allowPlatformBroker: config.system.allowPlatformBroker,
    serverTelemetryEnabled: config.system.serverTelemetryEnabled,
  },
});
