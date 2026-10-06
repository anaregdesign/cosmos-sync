#!/usr/bin/env python3
"""Offline plan or explicitly approved bounded SDK -> hosted ACA -> Cosmos test.

No deployment, membership edits, provider registration or new login is performed.
Execution may initialize the signed-in account's builtin personal policy and
retains one test document's three accepted mutations, receipts and tombstone.
"""
import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import threading
import time

from live_azure_contract import LiveWindow, run_command, stop_process
from live_azure_preflight import GateError, account_https_origin, manifest_digest, require
from native_entra_auth import private_json

ROOT = Path(__file__).resolve().parents[1]
STAGES = ("session_bootstrapped", "offline_write_durable", "offline_cache_reopened",
          "create_acknowledged", "peer_received_create", "update_acknowledged",
          "server_hint_received", "stale_write_conflicted", "server_version_chosen",
          "remote_update_synchronized", "delete_acknowledged",
          "remote_tombstone_watched", "cache_reopened_with_tombstone")
GET_PATHS = frozenset(("/v1/session", "/v1/snapshot", "/v1/sync", "/v1/events"))


def private_bytes(path, limit):
    """Open once without following symlinks; never expose filesystem errors."""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()
                    and stat.S_IMODE(info.st_mode) == 0o600 and info.st_size <= limit,
                    "hosted validation requires private current-owner regular files")
            value = stream.read(limit + 1)
            require(len(value) <= limit, "private input exceeds the bound")
            return value
    except OSError:
        raise GateError("cannot read approved private input") from None


def private_input(path):
    try:
        value = json.loads(private_bytes(path, 65536))
        require(isinstance(value, dict), "private JSON input must be an object")
        return value
    except (ValueError, UnicodeError):
        raise GateError("invalid approved private JSON input") from None


def load_manifest(path):
    return validate_manifest(private_input(path))


def validate_manifest(value):
    try:
        require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
                and value["authorizationMode"] == "builtin",
                "hosted validation requires the approved builtin authorization mode")
        account_https_origin(value["endpoint"])
        # Use the app's exact platform HTTPS origin, never arbitrary path prefixes.
        require(all(isinstance(value[key], str) and value[key].strip()
                    for key in ("targetApprovalReference", "liveWriteApprovalReference")),
                "hosted endpoint and three retained app mutations require owner approval")
        require(value["testDataRetentionAcknowledged"] is True,
                "retained journal, receipts and tombstone must be acknowledged")
        require(type(value["replicas"]) is int and value["replicas"] == 1,
                "this verifier supports one approved hosted replica")
        for key in ("accessTokenFile", "ownerFile", "receiptFile"):
            require(isinstance(value[key], str) and Path(value[key]).is_absolute(),
                    "approved private input paths must be absolute")
        budget = value["budget"]
        require(type(budget["maxRuntimeSeconds"]) is int and 30 <= budget["maxRuntimeSeconds"] <= 120,
                "hosted runtime must be bounded to 30..120 seconds")
        require(type(budget["maxProtocolRequests"]) is int and 20 <= budget["maxProtocolRequests"] <= 40,
                "hosted BFF request budget must be bounded to 20..40")
        require(type(budget["maxAcceptedAppMutations"]) is int and budget["maxAcceptedAppMutations"] == 3,
                "this verifier allows exactly three new app mutations")
        return value
    except (KeyError, TypeError):
        raise GateError("hosted validation manifest is missing required fields") from None


class HostedControl:
    """Capability-bound loopback configuration and hard protocol attempt budget."""
    def __init__(self, fixture, *, max_requests=40, seconds=120, clock=time.monotonic,
                 stages=STAGES, get_paths=GET_PATHS, request_ledger=None):
        require(type(max_requests) is int and 1 <= max_requests <= 40
                and type(seconds) is int and 1 <= seconds <= 120, "invalid hosted control bounds")
        self.fixture = fixture
        self.origin = account_https_origin(fixture["endpoint"])
        self.clock, self.deadline = clock, clock() + seconds
        self.max_requests = max_requests
        self.requests, self.mutation_attempts = 0, 0
        self.accepted, self.conflicts = 0, 0
        self.pending_attempt, self.unknown_outcome = None, False
        self.stages, self.lock = [], threading.Lock()
        self.expected_stages, self.get_paths, self.request_ledger = stages, get_paths, request_ledger
        self.aggregate_requests = None
        self.prefix = "/" + secrets.token_urlsafe(32) + "/"
        control = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *unused):
                pass

            def setup(self):
                super().setup()
                self.connection.settimeout(2)

            def reply(self, status, value):
                payload = json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def permitted_peer(self):
                return (self.headers.get("Host") == "127.0.0.1:" + str(control.server.server_port)
                        and self.headers.get("Origin") is None)

            def do_GET(self):
                if not self.permitted_peer() or self.path != control.prefix + "config":
                    self.reply(404, {"error": "invalid_control_path"})
                    return
                if control.clock() >= control.deadline:
                    self.reply(429, {"error": "private_runtime_exhausted"})
                    return
                self.reply(200, control.fixture)

            def do_POST(self):
                if not self.permitted_peer() or self.path not in (control.prefix + name for name in ("permit", "stage", "result")):
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
                        if control.clock() >= control.deadline:
                            self.reply(429, {"error": "private_runtime_exhausted"})
                            return
                        result = {}
                        if self.path.endswith("/permit"):
                            if set(value) != {"method", "path", "origin"} or account_https_origin(value["origin"]) != control.origin:
                                raise ValueError()
                            mutation = value["method"] == "POST" and value["path"] == "/v1/mutations"
                            if not (mutation or value["method"] == "GET" and value["path"] in control.get_paths):
                                raise ValueError()
                            if control.unknown_outcome or control.requests >= control.max_requests or mutation and (
                                    control.mutation_attempts >= 4 or control.accepted >= 3 or control.pending_attempt is not None):
                                self.reply(429, {"error": "private_budget_exhausted"})
                                return
                            if control.request_ledger is not None:
                                try:
                                    control.aggregate_requests = control.request_ledger.reserve()["protocolRequests"]
                                except GateError:
                                    self.reply(429, {"error": "private_aggregate_budget_exhausted"})
                                    return
                            control.requests += 1
                            control.mutation_attempts += int(mutation)
                            if mutation:
                                control.pending_attempt = control.mutation_attempts
                                result = {"mutationAttempt": control.pending_attempt}
                        elif self.path.endswith("/result"):
                            if set(value) != {"mutationAttempt", "outcome"} or type(value["mutationAttempt"]) is not int or value["mutationAttempt"] != control.pending_attempt:
                                raise ValueError()
                            if value["outcome"] not in ("accepted", "conflict", "unknown"):
                                raise ValueError()
                            control.accepted += int(value["outcome"] == "accepted")
                            control.conflicts += int(value["outcome"] == "conflict")
                            control.unknown_outcome = value["outcome"] == "unknown"
                            control.pending_attempt = None
                        else:
                            index = len(control.stages)
                            if set(value) != {"stage"} or index >= len(control.expected_stages) or value["stage"] != control.expected_stages[index]:
                                raise ValueError()
                            control.stages.append(value["stage"])
                    self.reply(200, result)
                except Exception:
                    self.reply(400, {"error": "invalid_control_request"})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = False
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)

    @property
    def url(self):
        return "http://127.0.0.1:" + str(self.server.server_port) + self.prefix

    def start(self):
        self.thread.start()

    def close(self):
        if self.thread.is_alive():
            self.server.shutdown()
        self.server.server_close()
        if self.thread.ident is not None:
            self.thread.join(timeout=3)


def verify_token(manifest, directory, *, go_bin="go"):
    try:
        token = private_bytes(manifest["accessTokenFile"], 16384).decode().strip()
    except UnicodeError:
        raise GateError("approved API JWT is invalid") from None
    require(re.fullmatch(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", token) is not None,
            "approved API JWT is invalid")
    token_path = directory / "api-access.jwt"
    fd = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w") as output:
        output.write(token)
    proof = directory / "api-proof"
    proof.mkdir(mode=0o700)
    run_command([go_bin, "run", "./cmd/verify-entra-principal", "--owner-file", manifest["ownerFile"],
                 "--receipt-file", manifest["receiptFile"], "--token-file", str(token_path),
                 "--output-dir", str(proof), "--permission-version", "hosted-proof-only"],
                cwd=ROOT / "bff", env={**os.environ, "GOCACHE": str(ROOT / ".cache/go-build")}, timeout=60)
    identity = private_input(proof / "identity.local.json")
    receipt = private_input(manifest["receiptFile"])
    require(identity["issuer"] == receipt["oidc"]["issuer"]
            and identity["audience"] == receipt["oidc"]["audience"],
            "verified API trust differs from the approved provider receipt")
    expiry = datetime.fromisoformat(identity["accessTokenExpiry"].replace("Z", "+00:00"))
    require((expiry - datetime.now(timezone.utc)).total_seconds() > manifest["budget"]["maxRuntimeSeconds"] + 30,
            "a fresh verified API JWT is required for the complete hosted test")
    return token


def execute(manifest, dart_bin, *, go_bin="go"):
    validate_manifest(manifest)  # Refuse before token reads, proof or networking.
    parent = ROOT / ".cache/hosted-azure-live"
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(parent.is_dir() and not parent.is_symlink() and parent.stat().st_uid == os.geteuid(),
            "hosted evidence directory must be current-owner and private")
    parent.chmod(0o700)
    directory = parent / secrets.token_hex(12)
    directory.mkdir(mode=0o700)
    document = "hosted-live-" + secrets.token_hex(12)
    control, window, process = None, None, None
    report = {"mode": "incomplete-hosted-azure-sdk", "targetDigest": manifest_digest(manifest),
              "retainedTestDocumentId": document, "passed": [], "protocolRequests": 0,
              "mutationAttempts": 0, "acceptedNewAppMutations": 0, "livePhaseStarted": False}
    try:
        token = verify_token(manifest, directory, go_bin=go_bin)
        fixture = {"protocolVersion": 1, "endpoint": manifest["endpoint"], "accessToken": token,
                   "documentId": document, "cacheDirectory": str(directory / "sqlite")}
        budget = manifest["budget"]
        control = HostedControl(fixture, max_requests=budget["maxProtocolRequests"], seconds=budget["maxRuntimeSeconds"])
        control.start()
        window = LiveWindow(budget["maxRuntimeSeconds"])
        log_fd = os.open(directory / "dart.private.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(log_fd, "wb") as output:
            process = subprocess.Popen([dart_bin, "run", "test/hosted_azure_live.dart"],
                cwd=ROOT / "packages/cosmos_sync", stdout=output, stderr=output,
                env={**os.environ, "COSMOS_SYNC_HOSTED_CONTROL_URL": control.url})
            window.add_process(process)
            report["livePhaseStarted"] = True
            while process.poll() is None:
                require(not window.expired.is_set() and time.monotonic() < window.deadline,
                        "hosted SDK test exceeded its runtime bound")
                time.sleep(0.05)
            require(process.returncode == 0 and tuple(control.stages) == STAGES
                    and control.mutation_attempts == 4 and control.accepted == 3 and control.conflicts == 1
                    and control.pending_attempt is None and not control.unknown_outcome,
                    "hosted SDK test did not complete all bounded assertions")
        report.update({"mode": "approved-hosted-azure-sdk", "actualHostedBff": True,
                       "realSqlite": True, "tlsVerification": "system-trust-no-redirects",
                       "authAdapter": "recorded-signature-verified-real-provider-api-jwt",
                       "acceptedNewAppMutations": 3,
                       "notVerified": ["new native provider login in this target", "native UI", "OS process restart",
                                       "multiple users or shared membership revocation", "multiple hosted replicas",
                                       "merge-and-retry conflict resolution", "physical-device hosted access"],
                       "builtinAccountRegistrationMayPersist": True})
        return report
    finally:
        cleanup = {}
        if process is not None:
            try:
                stop_process(process)
                cleanup["ownedProcessStopped"] = True
            except Exception:
                cleanup["ownedProcessStopped"] = False
        if window is not None:
            try:
                window.close()
                cleanup["watchdogStopped"] = True
            except Exception:
                cleanup["watchdogStopped"] = False
        if control is not None:
            report.update({"passed": list(control.stages), "protocolRequests": control.requests,
                           "mutationAttempts": control.mutation_attempts,
                           "acceptedMutationResponses": control.accepted,
                           "rejectedConflictResponses": control.conflicts,
                           "unknownOutcome": control.unknown_outcome or control.pending_attempt is not None,
                           "testDataMayBeRetained": control.mutation_attempts > 0})
            if report["mode"] == "incomplete-hosted-azure-sdk" and control.mutation_attempts:
                report["acceptedNewAppMutations"] = "unknown-on-failure"
            try:
                control.close()
                cleanup["ownedControlStopped"] = True
            except Exception:
                cleanup["ownedControlStopped"] = False
        try:
            (directory / "api-access.jwt").unlink(missing_ok=True)
            cleanup["copiedApiJwtRemoved"] = True
        except OSError:
            cleanup["copiedApiJwtRemoved"] = False
        report["cleanup"] = cleanup
        private_json(directory / "proof.json", report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--execute-approved", action="store_true")
    parser.add_argument("--dart-bin", default="dart")
    parser.add_argument("--go-bin", default="go")
    args = parser.parse_args()
    manifest = load_manifest(args.manifest)
    if args.execute_approved:
        report = execute(manifest, args.dart_bin, go_bin=args.go_bin)
    else:
        report = {"mode": "offline-hosted-plan", "targetDigest": manifest_digest(manifest),
                  "azureContacted": False, "tokensLoaded": False, "resourcesModified": False,
                  "maxProtocolRequests": manifest["budget"]["maxProtocolRequests"],
                  "maxAcceptedAppMutations": 3, "maxMutationAttempts": 4,
                  "plannedStages": list(STAGES)}
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt):
        print("HOSTED_AZURE_VALIDATION_FAILED_CHECK_PRIVATE_EVIDENCE", file=sys.stderr)
        raise SystemExit(1)
