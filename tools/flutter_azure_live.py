#!/usr/bin/env python3
"""Explicit, bounded native UI -> production TLS BFF -> approved actual Cosmos.

Uses a captured, verified REAL API JWT. It does not claim a fresh native login,
provider refresh, OS Keychain restore, process restart or multiple users.
"""
import argparse
import base64
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import threading
import time
import uuid

from live_azure_contract import (Client, LiveWindow, choose_port, load_private_token,
                                 private_json as replace_private_json,
                                 require_write_approval, run_command, stop_process)
from live_azure_preflight import (GateError, check_cli_default, inspect_target,
                                  load_manifest, manifest_digest, require)
from native_entra_auth import private_input, private_json

ROOT = Path(__file__).resolve().parents[1]
STAGES = ("ui_connected", "offline_write_durable", "offline_cache_reopened",
          "create_acknowledged", "update_acknowledged", "cross_replica_document_verified",
          "permission_generation_purged", "revocation_purged", "local_signout_complete")
GET_PATHS = frozenset({"/v1/session", "/v1/snapshot", "/v1/sync", "/v1/events"})


class UIControl:
    """Capability-local fixture, shared hard request/mutation-attempt budget."""
    def __init__(self, fixture, grants, grants_path, max_requests=50):
        self.fixture, self.grants, self.grants_path = fixture, grants, grants_path
        self.max_requests = max_requests
        self.requests, self.mutation_attempts = 0, 0
        self.stages, self.actions = [], []
        self.lock = threading.Lock()
        self.prefix = "/" + secrets.token_urlsafe(32) + "/"
        control = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *unused):
                pass

            def reply(self, status, value):
                payload = json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_GET(self):
                if self.path != control.prefix + "config":
                    self.reply(404, {"error": "invalid_control_path"})
                    return
                # Sole approved target receives the recorded API token over
                # capability-bound loopback, never via args/assets/logs.
                self.reply(200, control.fixture)

            def do_POST(self):
                if self.path not in {control.prefix + name for name in ("stage", "permit", "action")}:
                    self.reply(404, {"error": "invalid_control_path"})
                    return
                try:
                    size = int(self.headers.get("Content-Length", "0"))
                    if not 0 < size <= 2048:
                        raise ValueError()
                    value = json.loads(self.rfile.read(size))
                    if not isinstance(value, dict):
                        raise ValueError()
                    with control.lock:
                        if self.path.endswith("/permit"):
                            if set(value) != {"method", "path"}:
                                raise ValueError()
                            mutation = value["method"] == "POST" and value["path"] == "/v1/mutations"
                            if not (mutation or value["method"] == "GET" and value["path"] in GET_PATHS):
                                raise ValueError()
                            if control.requests >= control.max_requests or mutation and control.mutation_attempts >= 3:
                                self.reply(429, {"error": "private_budget_exhausted"})
                                return
                            control.requests += 1
                            control.mutation_attempts += int(mutation)
                        elif self.path.endswith("/stage"):
                            index = len(control.stages)
                            if set(value) != {"stage"} or index >= len(STAGES) or value["stage"] != STAGES[index]:
                                raise ValueError()
                            control.stages.append(value["stage"])
                            print("FLUTTER_AZURE_UI_STAGE_" + value["stage"].upper(), flush=True)
                        else:
                            if set(value) != {"action"}:
                                raise ValueError()
                            if value["action"] == "downgrade" and control.actions == [] and "cross_replica_document_verified" in control.stages:
                                changed = [{**grant, "canWrite": False, "permissionVersion": "ui-reader-" + secrets.token_hex(8)}
                                           for grant in control.grants]
                            elif value["action"] == "revoke" and control.actions == ["downgrade"] and "permission_generation_purged" in control.stages:
                                changed = [{**grant, "active": False} for grant in control.grants]
                            else:
                                raise ValueError()
                            replace_private_json(control.grants_path, changed)
                            control.grants[:] = changed
                            control.actions.append(value["action"])
                    self.reply(200, {})
                except Exception:
                    self.reply(400, {"error": "invalid_control_request"})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self):
        return "http://127.0.0.1:" + str(self.server.server_port) + self.prefix

    def start(self):
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def execute(manifest_path, flutter_bin, *, binary=None):
    # Read only an owner-private manifest, then preserve existing normal gates.
    private = private_input(manifest_path)
    manifest = load_manifest(manifest_path)
    require(manifest == private and manifest.get("fixtureMode") == "single-account",
            "approved private single-account target required")
    require_write_approval(manifest)
    require(30 <= manifest["budget"]["maxRuntimeSeconds"] <= 120,
            "UI live phase must be bounded to at most 120 seconds")
    parent = ROOT / ".cache/azure-ui-live"
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    parent.chmod(0o700)
    directory = parent / secrets.token_hex(12)
    directory.mkdir(mode=0o700)
    latest = parent / "latest.local.json"
    if latest.exists():
        latest.unlink()
    private_json(latest, {"runDirectory": str(directory)})
    document = "flutter-live-" + uuid.uuid4().hex
    control, window, token_path = None, None, None
    try:
        # Verify EXACT captured bytes again before using the token or Azure.
        token = load_private_token(manifest["testPrincipals"]["writer"]["accessTokenFile"])
        token_path = directory / "api-access.jwt"
        fd = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(token)
        proof = directory / "api-proof"
        proof.mkdir(mode=0o700)
        run_command(["go", "run", "./cmd/verify-entra-principal", "--owner-file", str(ROOT / ".cache/entra-azure/approved-owner.local.json"),
                     "--receipt-file", str(ROOT / ".cache/entra-azure/registration-receipt.local.json"),
                     "--token-file", str(token_path), "--output-dir", str(proof), "--permission-version", "flutter-live-v1"],
                    cwd=ROOT / "bff", env={**os.environ, "GOCACHE": str(ROOT / ".cache/go-build")}, timeout=60)
        identity = private_input(proof / "identity.local.json")
        writer = manifest["testPrincipals"]["writer"]
        require(writer["tenant"] == identity["tenantId"] and writer["subject"] == identity["subject"],
                "approved grant identity differs from signed API-token proof")
        receipt = private_input(ROOT / ".cache/entra-azure/registration-receipt.local.json")
        require(receipt["oidc"] == manifest["oidc"], "manifest API trust configuration differs from approved receipt")
        check_cli_default(manifest)
        metadata = inspect_target(manifest)
        certificate, key = directory / "tls.pem", directory / "tls.key"
        run_command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost",
                     "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1", "-keyout", str(key), "-out", str(certificate)])
        key.chmod(0o600)
        if binary is None:
            binary = directory / "cosmos-sync-bff"
            run_command(["go", "build", "-trimpath", "-o", str(binary), "./cmd/cosmos-sync-bff"], cwd=ROOT / "bff",
                        env={**os.environ, "GOCACHE": str(ROOT / ".cache/go-build")})
        ports = [choose_port(), choose_port()]
        require(ports[0] != ports[1], "two distinct loopback BFF ports required")
        grants_path = directory / "grants.local.json"
        grants = [{"tenant": identity["tenantId"], "subject": identity["subject"], "scopeMode": "user",
                   "permissionVersion": "ui-writer-" + secrets.token_hex(8), "active": True, "canRead": True, "canWrite": True}]
        private_json(grants_path, grants)
        fixture = {"protocolVersion": 1, "bffUrls": [f"https://127.0.0.1:{port}" for port in ports],
                   "certificatePem": certificate.read_text(), "accessToken": token,
                   "nativeConfig": receipt["nativeConfig"], "documentId": document}
        control = UIControl(fixture, grants, grants_path, manifest["budget"]["maxProtocolRequests"])
        control.start()
        template = json.loads((ROOT / "bff/config.example.json").read_text())
        child_env = {**os.environ, "AZURE_TOKEN_CREDENTIALS": "AzureCLICredential", "AZURE_CORE_COLLECT_TELEMETRY": "no",
                     "COSMOS_SYNC_CURSOR_KEY_BASE64": base64.b64encode(secrets.token_bytes(32)).decode(),
                     "COSMOS_SYNC_TLS_CERT": str(certificate), "COSMOS_SYNC_TLS_KEY": str(key),
                     "COSMOS_SYNC_METRICS_TOKEN": secrets.token_urlsafe(32)}
        window = LiveWindow(manifest["budget"]["maxRuntimeSeconds"])
        with ExitStack() as stack:
            stack.callback(window.close)
            context = ssl.create_default_context(cafile=str(certificate))
            health = Client(ports, context, manifest["budget"], window)
            processes = []
            for index, port in enumerate(ports):
                config = {**template, "listen": f"127.0.0.1:{port}", "development": False, "storage": "cosmos",
                          "historyEpoch": "flutter-ui-" + document, "grantsFile": str(grants_path), "oidc": manifest["oidc"],
                          "allowedOrigins": [], "cosmos": {name: manifest["azure"][name] for name in ("endpoint", "database", "container")},
                          "events": {"enabled": True, "pollMilliseconds": 5000, "heartbeatMilliseconds": 5000, "maxStreamSeconds": 15}}
                config["cosmos"]["singleWriteRegion"] = True
                path = directory / f"bff-{index}.local.json"
                private_json(path, config)
                log_fd = os.open(directory / f"bff-{index}.private.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                output = stack.enter_context(os.fdopen(log_fd, "wb"))
                process = subprocess.Popen([str(binary), "-config", str(path)], env=child_env, stdout=output, stderr=output)
                processes.append(process)
                stack.callback(stop_process, process)
                window.add_process(process)
            for index, port in enumerate(ports):
                while True:
                    require(processes[index].poll() is None, "production Cosmos BFF initialization failed")
                    with socket.socket() as probe:
                        probe.settimeout(0.2)
                        listening = probe.connect_ex(("127.0.0.1", port)) == 0
                    if listening:
                        health.request(index, "GET", "/healthz")
                        break
                    health.timeout()
                    time.sleep(0.2)
            control.requests = health.requests
            log_fd = os.open(directory / "flutter.private.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            output = stack.enter_context(os.fdopen(log_fd, "wb"))
            command = [flutter_bin, "test", "integration_test/azure_live_ui_test.dart", "-d", "macos",
                       "--dart-define=COSMOS_SYNC_AZURE_UI_CONTROL_URL=" + control.url, "--reporter", "expanded"]
            process = subprocess.Popen(command, cwd=ROOT / "examples/flutter_app", stdout=output, stderr=output)
            stack.callback(stop_process, process)
            window.add_process(process)
            print("FLUTTER_AZURE_UI_APPROVED_LIVE_PHASE_STARTED", flush=True)
            while process.poll() is None:
                health.timeout()
                time.sleep(0.2)
            require(process.returncode == 0 and tuple(control.stages) == STAGES,
                    "native UI live target did not complete all assertions")
            health.timeout()
            report = {"mode": "approved-live-flutter-ui-cosmos", "targetDigest": manifest_digest(manifest),
                      "actualCosmos": True, "productionFactory": "NewCosmosStore", "development": False,
                      "authAdapter": "recorded-signature-verified-real-provider-api-jwt", "newProviderLogin": False,
                      "tlsVerification": "owned-test-ca-only-no-system-store-changes", "realNativeUI": True, "realSqlite": True,
                      "passed": list(control.stages), "protocolRequests": control.requests,
                      "mutationAttempts": control.mutation_attempts, "acceptedNewMutations": 2,
                      "retainedTestDocumentId": document, "liveSeconds": round(time.monotonic() - window.started, 3),
                      "metadataGuardCompatible": metadata["productionGuardCompatible"],
                      "notVerified": ["multi-principal provider isolation", "OS process restart", "fresh native login in this target",
                                      "hosted deployment", "physical-device Azure connection"]}
        private_json(directory / "proof.json", report)
        return report
    except BaseException:
        partial = {"mode": "incomplete-flutter-ui-cosmos", "targetDigest": manifest_digest(manifest),
                   "passed": list(control.stages) if control else [], "protocolRequests": control.requests if control else 0,
                   "mutationAttempts": control.mutation_attempts if control else 0,
                   "acceptedNewMutations": "unknown-on-failure" if control and control.mutation_attempts else 0,
                   "testDataMayBeRetained": bool(control and control.mutation_attempts), "retainedTestDocumentId": document,
                   "livePhaseStarted": window is not None}
        private_json(directory / "partial-proof.json", partial)
        raise GateError("approved native UI contract incomplete; inspect private partial evidence") from None
    finally:
        if control:
            control.close()
        # Only our copy is no longer needed. The separately approved native and
        # Azure contract token files belong to their coordinators.
        if token_path:
            token_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--execute-approved-ui-contract", action="store_true", required=True)
    parser.add_argument("--flutter-bin", default=os.environ.get("FLUTTER_BIN", "flutter"))
    parser.add_argument("--bff-binary", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(execute(args.manifest, args.flutter_bin, binary=args.bff_binary)), flush=True)
        return 0
    except BaseException:
        print("FLUTTER_AZURE_UI_INCOMPLETE_CHECK_PRIVATE_EVIDENCE", flush=True)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
