#!/usr/bin/env python3
"""Explicitly gated, bounded two-production-BFF contract against approved Cosmos."""

import argparse
import base64
from contextlib import ExitStack, closing
import http.client
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlencode
import uuid

from live_azure_preflight import (GateError, check_cli_default, fixture_mode, inspect_target,
                                  load_manifest, manifest_digest, nonempty, principal_roles,
                                  protocol_request_plan, require,
                                  require_target_approval)

ROOT = Path(__file__).resolve().parents[1]
SESSION_HEADER = "X-Cosmos-Sync-Session"
SESSION_HEADERS = {"scopeId": "X-Cosmos-Sync-Scope",
                   "permissionVersion": "X-Cosmos-Sync-Permission",
                   "principalId": "X-Cosmos-Sync-Principal",
                   "scopeMode": "X-Cosmos-Sync-Scope-Mode"}


def load_private_token(path):
    file = Path(path)
    try:
        info = file.stat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) & 0o077 == 0,
                "access token files must be regular, current-user-owned and private (0600 or stricter)")
        require(info.st_size <= 16384, "access token file exceeds the JWT bound")
        token = file.read_text().strip()
        require(token.count(".") == 2 and len(token) >= 32
                and not any(char.isspace() for char in token),
                "access token file must contain one JWT and no other content")
        return token
    except OSError:
        raise GateError("cannot read an approved private JWT file") from None


def private_json(path, value):
    temporary = path.with_suffix(".new")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(value, output)
    os.replace(temporary, path)


def require_write_approval(manifest):
    require_target_approval(manifest)
    require(nonempty(manifest.get("liveWriteApprovalReference")),
            "owner must explicitly authorize retained test writes in this target")
    budget = manifest["budget"]
    require(type(budget["maxProtocolRequests"]) is int
            and protocol_request_plan(manifest) <= budget["maxProtocolRequests"] <= 50,
            "live fixture request plan exceeds the approved bound before credentials or Azure access")
    ceiling = budget["ceilingAmount"]
    require(((type(ceiling) in (int, float) and ceiling > 0)
             or (ceiling is None and budget.get("unboundedCostApproved") is True))
            and budget["testDataRetentionAcknowledged"] is True,
            "owner must approve costs and retained journal/receipt/tombstone test data")
    for key, value in manifest["oidc"].items():
        require("owner-selected" not in str(value), "replace OIDC placeholders with the approved API configuration")
    for role in principal_roles(manifest):
        principal = manifest["testPrincipals"][role]
        require(not any("owner-selected" in str(value) for value in principal.values()),
                "replace test-principal placeholders after owner approval")


def choose_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def run_command(arguments, *, cwd=None, env=None, timeout=120):
    try:
        completed = subprocess.run(arguments, cwd=cwd, env=env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise GateError("local build/TLS preparation could not complete") from None
    require(completed.returncode == 0, "local build/TLS preparation failed; no command output is exposed")


class LiveWindow:
    """An absolute live phase deadline, independent of socket progress."""

    def __init__(self, seconds):
        self.started = time.monotonic()
        self.deadline = self.started + seconds
        self.expired = threading.Event()
        self.lock = threading.Lock()
        self.processes = []
        self.sockets = set()
        self.timer = threading.Timer(max(0, self.deadline - time.monotonic()), self.expire)
        self.timer.daemon = True
        self.timer.start()

    def add_process(self, process):
        with self.lock:
            self.processes.append(process)
        if self.expired.is_set() and process.poll() is None:
            process.kill()

    def add_socket(self, connection_socket):
        if connection_socket is None:
            return
        with self.lock:
            self.sockets.add(connection_socket)
        if self.expired.is_set():
            self.close_socket(connection_socket)

    def remove_socket(self, connection_socket):
        with self.lock:
            self.sockets.discard(connection_socket)

    @staticmethod
    def close_socket(connection_socket):
        try:
            connection_socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def expire(self):
        self.expired.set()
        with self.lock:
            processes, sockets = list(self.processes), list(self.sockets)
        for process in processes:
            try:
                if process.poll() is None:
                    process.kill()  # No new local-server Cosmos requests after the deadline.
            except OSError:
                pass
        for connection_socket in sockets:
            self.close_socket(connection_socket)

    def close(self):
        self.timer.cancel()


class Client:
    def __init__(self, ports, context, budget, window=None):
        self.ports, self.context, self.budget = ports, context, budget
        self.window = window
        self.deadline = window.deadline if window else time.monotonic() + budget["maxRuntimeSeconds"]
        self.requests = 0
        self.results = []
        self.consistency = {}
        self.write_attempted = False

    def timeout(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0 or (self.window and self.window.expired.is_set()):
            if self.window:
                self.window.expire()
            raise GateError("live contract exceeded the approved runtime bound")
        return min(15, remaining)

    def reset_socket_timeout(self, connection, connection_socket=None, maximum=15):
        connection.timeout = min(maximum, self.timeout())
        current_socket = connection_socket or getattr(connection, "sock", None)
        if current_socket is not None:
            current_socket.settimeout(connection.timeout)
            if self.window:
                self.window.add_socket(current_socket)
        return current_socket

    def connection(self, replica):
        require(self.requests < self.budget["maxProtocolRequests"],
                "live contract exceeded the approved protocol-request bound")
        self.requests += 1
        return http.client.HTTPSConnection("127.0.0.1", self.ports[replica],
                                           context=self.context, timeout=self.timeout())

    def headers(self, token=None, session=None, *, consistency=True):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        if session:
            headers.update({header: session[field] for field, header in SESSION_HEADERS.items()})
            envelope = self.consistency.get(session["principalId"] + session["scopeMode"])
            if consistency and envelope:
                headers[SESSION_HEADER] = envelope
        return headers

    def request(self, replica, method, path, *, token=None, session=None,
                payload=None, expected=200, code=None, headers=None, update_session=True):
        body = None if payload is None else json.dumps(payload, separators=(",", ":")).encode()
        request_headers = headers if headers is not None else self.headers(token, session)
        connection_socket = None
        try:
            with closing(self.connection(replica)) as connection:
                self.timeout()
                if method == "POST":
                    self.write_attempted = True
                connection.request(method, path, body=body, headers=request_headers)
                connection_socket = self.reset_socket_timeout(connection)
                response = connection.getresponse()
                self.reset_socket_timeout(connection, connection_socket)
                status = response.status
                raw = response.read(1024 * 1024 + 1)
                self.timeout()  # Socket inactivity timeouts are not an absolute deadline.
                require(len(raw) <= 1024 * 1024, "live response exceeded the harness bound")
                result = json.loads(raw) if raw else {}
                permitted = expected if isinstance(expected, tuple) else (expected,)
                require(status in permitted, f"live request failed its expected HTTP {expected} assertion")
                if code is not None:
                    require(result.get("code") == code, "live request failed its expected protocol-code assertion")
                envelope = response.getheader(SESSION_HEADER)
                if update_session and session and envelope:
                    self.consistency[session["principalId"] + session["scopeMode"]] = envelope
                self.timeout()
                return result
        except (OSError, http.client.HTTPException, ValueError):
            raise GateError("live TLS/HTTP request failed; credentials and arbitrary response data are suppressed") from None
        finally:
            if self.window and connection_socket is not None:
                self.window.remove_socket(connection_socket)

    def record(self, name):
        self.timeout()
        self.results.append(name)

    def session(self, replica, token, mode="tenant"):
        value = self.request(replica, "GET", "/v1/session?" + urlencode({"scope": mode}), token=token)
        require(all(nonempty(value.get(field)) for field in SESSION_HEADERS), "invalid live session shape")
        require(value["scopeMode"] == mode, "live session returned the wrong scope mode")
        return value

    def sync(self, replica, token, session, cursor=None):
        query = {"limit": "10"}
        if cursor is not None:
            query["cursor"] = cursor
        value = self.request(replica, "GET", "/v1/sync?" + urlencode(query), token=token, session=session)
        require(isinstance(value.get("changes"), list) and nonempty(value.get("cursor"))
                and value.get("hasMore") is False, "selected test scope is not a bounded completed journal")
        return value

    def event(self, replica, token, session, cursor, *, after_connected=None):
        connection_socket = None
        try:
            with closing(self.connection(replica)) as connection:
                connection.timeout = min(10, self.timeout())
                connection.request("GET", "/v1/events?" + urlencode({"cursor": cursor}),
                                   headers=self.headers(token, session))
                connection_socket = self.reset_socket_timeout(connection, maximum=10)
                response = connection.getresponse()
                self.reset_socket_timeout(connection, connection_socket, maximum=10)
                require(response.status == 200 and response.getheader("Content-Type", "").startswith("text/event-stream"),
                        "live events endpoint did not produce authenticated SSE")
                if after_connected:
                    # Headers have arrived, then alter only the harness-owned grant file.
                    after_connected()
                    self.timeout()
                event, event_id, data = None, None, []
                consumed = 0
                while consumed < 65536:
                    self.reset_socket_timeout(connection, connection_socket, maximum=10)
                    line = response.readline(65537 - consumed)
                    self.timeout()
                    consumed += len(line)
                    require(bool(line), "live SSE closed before its expected event")
                    text = line.decode("utf-8").rstrip("\r\n")
                    if not text and event and data:
                        return event, event_id, json.loads("\n".join(data))
                    if text.startswith("event: "):
                        event = text[7:]
                    elif text.startswith("id: "):
                        event_id = text[4:]
                    elif text.startswith("data: "):
                        data.append(text[6:])
                raise GateError("live SSE exceeded the harness parser bound")
        except (OSError, http.client.HTTPException, ValueError):
            raise GateError("live SSE could not complete within its time/body bounds") from None
        finally:
            if self.window and connection_socket is not None:
                self.window.remove_socket(connection_socket)


def grants_for(manifest, permission):
    grants = []
    for role in (("writer",) if fixture_mode(manifest) == "single-account" else ("writer", "reader")):
        principal = manifest["testPrincipals"][role]
        for mode in ("tenant", "user"):
            grants.append({"tenant": principal["tenant"], "subject": principal["subject"],
                           "scopeMode": mode, "permissionVersion": permission,
                           "active": True, "canRead": True, "canWrite": role == "writer"})
    return grants


def exercise_contract(client, tokens, grants, grants_path, prefix, *, outsider_same_tenant=True,
                      single_account=False):
    client.request(0, "GET", "/v1/session", expected=401, code="unauthorized")
    client.request(0, "GET", "/v1/session", token="invalid.jwt.fixture", expected=401, code="unauthorized")
    client.record("missing-and-invalid-access-jwt-rejected")
    writer = client.session(0, tokens["writer"])
    require(client.session(1, tokens["writer"]) == writer, "replicas returned different server-managed sessions")
    personal_writer = client.session(0, tokens["writer"], "user")
    if single_account:
        tokens = {**tokens, "reader": tokens["writer"]}
        reader, personal_reader = writer, personal_writer
        require(personal_writer["scopeId"] != writer["scopeId"], "personal versus tenant scope isolation failed")
        client.record("two-local-replica-one-principal-personal-and-tenant-sessions")
    else:
        reader = client.session(1, tokens["reader"])
        require(writer["scopeId"] == reader["scopeId"] and writer["principalId"] != reader["principalId"],
                "shared tenant scope did not retain distinct principal identity")
        personal_reader = client.session(1, tokens["reader"], "user")
        require(personal_reader["scopeId"] != personal_writer["scopeId"]
                and personal_writer["scopeId"] != writer["scopeId"], "personal partition isolation failed")
        client.record("two-replica-personal-and-shared-tenant-sessions")
    baseline = client.sync(0, tokens["writer"], writer)
    require(baseline["changes"] == [], "selected test tenant scope must be empty; no test writes were attempted")
    reader_baseline = baseline if single_account else client.sync(1, tokens["reader"], reader)
    require(reader_baseline["changes"] == [], "selected shared test scope changed before test writes")
    create = {"operationId": str(uuid.uuid4()), "documentId": prefix,
              "kind": "put", "data": {"fixture": "cosmos-sync-live-contract", "value": "created"}, "baseVersion": 0}
    if not single_account:
        client.request(1, "POST", "/v1/mutations", token=tokens["reader"], session=reader,
                       payload=create, expected=403, code="forbidden")
        # A trusted same-tenant ungranted principal must prove 403, not a JWT error.
        client.request(0, "GET", "/v1/session", token=tokens["outsider"],
                       expected=403 if outsider_same_tenant else (401, 403))
    forged = client.headers(tokens["writer"], writer)
    forged[SESSION_HEADERS["scopeId"]] = personal_reader["scopeId"]
    client.request(1, "GET", "/v1/sync", headers=forged, expected=403, code="session_mismatch")
    client.record("forged-partition-denied" if single_account else "reader-write-ungranted-jwt-and-forged-partition-denied")
    first = client.request(0, "POST", "/v1/mutations", token=tokens["writer"], session=writer, payload=create)["document"]
    require(first["id"] == prefix and first["version"] == 1 and first["deleted"] is False,
            "fresh test scope create was not sequence one")
    require(nonempty(client.consistency.get(writer["principalId"] + writer["scopeMode"])),
            "real Cosmos create did not produce a signed consistency envelope")
    replay = client.request(1, "POST", "/v1/mutations", token=tokens["writer"], session=writer, payload=create)["document"]
    require(replay == first, "cross-replica exact operation replay changed the result")
    client.request(1, "POST", "/v1/mutations", token=tokens["writer"], session=writer,
                   payload={**create, "data": {"value": "changed-same-operation"}}, expected=409, code="idempotency_mismatch")
    client.record("cosmos-atomic-create-session-envelope-and-cross-replica-idempotency")
    event, event_id, data = client.event(1, tokens["reader"], reader, reader_baseline["cursor"])
    require(event == "change" and nonempty(event_id) and data.get("cursor") == event_id
            and "documents" not in data and "changes" not in data, "SSE change hint contained an invalid cursor or document payload")
    client.record("authenticated-live-cosmos-change-hint")
    snapshot = client.request(0, "GET", "/v1/snapshot?limit=1", token=tokens["writer"], session=writer)
    require(snapshot.get("documents") == [first] and snapshot.get("cutoverSequence") == 1,
            "fixed-head snapshot did not contain the initial document")
    update = {**create, "operationId": str(uuid.uuid4()), "baseVersion": 1,
              "data": {"fixture": "cosmos-sync-live-contract", "value": "updated"}}
    second = client.request(1, "POST", "/v1/mutations", token=tokens["writer"], session=writer, payload=update)["document"]
    require(second["version"] == 2 and second["data"] == update["data"], "live conditional update did not advance exactly once")
    resumed = client.request(1, "GET", "/v1/snapshot?" + urlencode({"limit": 1, "cursor": snapshot["cursor"]}),
                             token=tokens["writer"], session=writer)
    require(resumed.get("cutoverSequence") == 1 and resumed.get("documents") == []
            and resumed.get("hasMore") is False, "snapshot resume moved its fixed cutover after a concurrent update")
    client.record("fixed-cutover-snapshot-resumes-on-another-replica")
    conflict = client.request(0, "POST", "/v1/mutations", token=tokens["writer"], session=writer,
                              payload={**create, "operationId": str(uuid.uuid4())}, expected=409, code="conflict")
    require(conflict.get("current") == second, "stale base did not return the current authorized document")
    page = client.sync(0, tokens["writer"], writer, baseline["cursor"])
    require(page["changes"] == [first, second], "journal was not contiguous and ordered inside the test partition")
    require(client.sync(1, tokens["writer"], writer, page["cursor"])["changes"] == [], "cross-replica resume repeated acknowledged changes")
    if not single_account:
        client.request(1, "GET", "/v1/sync?" + urlencode({"cursor": page["cursor"]}),
                       token=tokens["reader"], session=reader, expected=410, code="resync_required")
    client.record("etag-conflict-contiguous-journal-resume" if single_account
                  else "etag-conflict-contiguous-journal-resume-and-cross-principal-cursor-denial")
    deletion = {**create, "operationId": str(uuid.uuid4()), "kind": "delete", "data": None, "baseVersion": 2}
    tombstone = client.request(0, "POST", "/v1/mutations", token=tokens["writer"], session=writer, payload=deletion)["document"]
    require(tombstone["version"] == 3 and tombstone["deleted"] is True and tombstone["data"] is None,
            "delete did not preserve its ordered tombstone")
    require(client.request(1, "POST", "/v1/mutations", token=tokens["writer"], session=writer, payload=deletion)["document"] == tombstone,
            "cross-replica delete retry changed its receipt")
    require(client.sync(1, tokens["writer"], writer, page["cursor"])["changes"] == [tombstone],
            "resumed journal did not contain exactly the deletion tombstone")
    client.record("ordered-tombstone-and-durable-delete-receipt")
    if single_account:
        grants[:] = [{**grant, "canWrite": False, "permissionVersion": prefix + "-reader"}
                     for grant in grants]
        private_json(grants_path, grants)
        reader = client.session(1, tokens["writer"])
        require(reader["principalId"] == writer["principalId"] and reader["scopeId"] == writer["scopeId"]
                and reader["permissionVersion"] != writer["permissionVersion"],
                "same-principal writer-to-reader transition did not change permission version")
        # A new grant version invalidates the old signed consistency envelope.
        # Acquire a fresh reader envelope from its subsequent successful sync.
        client.consistency.pop(reader["principalId"] + reader["scopeMode"], None)
        client.request(0, "GET", "/v1/sync", token=tokens["writer"], session=writer,
                       expected=403, code="session_mismatch")
        client.request(1, "POST", "/v1/mutations", token=tokens["reader"], session=reader,
                       payload={**create, "operationId": str(uuid.uuid4()), "baseVersion": 3},
                       expected=403, code="forbidden")
        client.request(1, "GET", "/v1/sync?" + urlencode({"cursor": page["cursor"]}),
                       token=tokens["reader"], session=reader, expected=410, code="resync_required")
        client.record("same-principal-writer-to-reader-denies-write-and-old-permission-context")
    reader_end = client.sync(1, tokens["reader"], reader)
    require(reader_end["changes"] == [first, second, tombstone], "read-only tenant member could not synchronize the committed history")

    def revoke_reader():
        revoked = [{**grant, "active": False} if grant["subject"] == manifest_reader_subject(grants)
                   else grant for grant in grants]
        private_json(grants_path, revoked)

    event, _, data = client.event(1, tokens["reader"], reader, reader_end["cursor"], after_connected=revoke_reader)
    require(event == "error" and data.get("code") == "forbidden", "current grant revocation did not end the live authenticated stream")
    client.request(0, "GET", "/v1/session", token=tokens["reader"], expected=403, code="forbidden")
    client.record("harness-owned-grant-revocation-stops-stream-and-new-requests")


def manifest_reader_subject(grants):
    return next(grant["subject"] for grant in grants if grant["canWrite"] is False)


def stop_process(process):
    try:
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=12)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
    except BaseException:
        # Cleanup must still stop its own child when interrupted or another
        # cleanup step fails; never leave a production Cosmos connection behind.
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        raise


def execute(manifest, binary=None):
    require_write_approval(manifest)
    prefix = "live-" + uuid.uuid4().hex
    preparation_started = time.monotonic()
    client, live_started, live_finished, cleanup_started = None, None, None, None
    try:
        # These read-only/local preparation phases precede the timed BFF phase.
        # They have individual CLI/build timeouts and never start a Cosmos store.
        tokens = {role: load_private_token(manifest["testPrincipals"][role]["accessTokenFile"])
                  for role in principal_roles(manifest)}
        check_cli_default(manifest)
        preflight = inspect_target(manifest)
        with tempfile.TemporaryDirectory(prefix="cosmos-sync-live-") as folder, ExitStack() as stack:
            directory = Path(folder)
            directory.chmod(0o700)
            certificate, key = directory / "tls.pem", directory / "tls.key"
            run_command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                         "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
                         "-keyout", str(key), "-out", str(certificate)])
            key.chmod(0o600)
            if binary is None:
                binary = directory / "cosmos-sync-bff"
                run_command(["go", "build", "-trimpath", "-o", str(binary), "./cmd/cosmos-sync-bff"], cwd=ROOT / "bff",
                            env={**os.environ, "GOCACHE": str(ROOT / ".cache/go-build"),
                                 "GOMODCACHE": str(ROOT / ".cache/go-mod")})
            else:
                binary = binary.resolve()
                require(binary.is_file(), "selected BFF binary is missing")
            grants_path = directory / "grants.json"
            grants = grants_for(manifest, prefix)
            private_json(grants_path, grants)
            ports = [choose_port(), choose_port()]
            require(ports[0] != ports[1], "could not allocate two distinct loopback ports")
            child_env = {**os.environ, "AZURE_TOKEN_CREDENTIALS": "AzureCLICredential",
                         "AZURE_CORE_COLLECT_TELEMETRY": "no",
                         "COSMOS_SYNC_CURSOR_KEY_BASE64": base64.b64encode(secrets.token_bytes(32)).decode(),
                         "COSMOS_SYNC_TLS_CERT": str(certificate), "COSMOS_SYNC_TLS_KEY": str(key),
                         "COSMOS_SYNC_METRICS_TOKEN": secrets.token_urlsafe(32)}
            processes = []
            template = json.loads((ROOT / "bff/config.example.json").read_text())
            window = LiveWindow(manifest["budget"]["maxRuntimeSeconds"])
            live_started = window.started
            stack.callback(window.close)
            context = ssl.create_default_context(cafile=str(certificate))
            client = Client(ports, context, manifest["budget"], window)
            for replica, port in enumerate(ports):
                client.timeout()
                config = {**template, "listen": f"127.0.0.1:{port}", "development": False,
                          "storage": "cosmos", "historyEpoch": prefix, "grantsFile": str(grants_path),
                          "oidc": manifest["oidc"], "allowedOrigins": [],
                          "cosmos": {key: manifest["azure"][key] for key in ("endpoint", "database", "container")},
                          "events": {"enabled": True, "pollMilliseconds": 1000,
                                     "heartbeatMilliseconds": 5000, "maxStreamSeconds": 15}}
                config["cosmos"]["singleWriteRegion"] = True
                path = directory / f"bff-{replica}.json"
                private_json(path, config)
                # Logs remain private and are destroyed with this harness directory.
                log = stack.enter_context((directory / f"bff-{replica}.log").open("wb"))
                process = subprocess.Popen([str(binary), "-config", str(path)], env=child_env,
                                           stdout=log, stderr=log)
                processes.append(process)
                stack.callback(stop_process, process)
                window.add_process(process)
            for replica in (0, 1):
                while True:
                    require(processes[replica].poll() is None,
                            "production BFF initialization failed; verify OIDC, Azure identity/RBAC and network access")
                    with socket.socket() as probe:
                        probe.settimeout(0.2)
                        listening = probe.connect_ex(("127.0.0.1", ports[replica])) == 0
                    if listening:
                        client.request(replica, "GET", "/healthz")
                        break
                    client.timeout()
                    time.sleep(0.25)
            single_account = fixture_mode(manifest) == "single-account"
            exercise_contract(client, tokens, grants, grants_path, prefix,
                              single_account=single_account,
                              outsider_same_tenant=single_account or (
                                  manifest["testPrincipals"]["outsider"]["tenant"]
                                  == manifest["testPrincipals"]["writer"]["tenant"]))
            client.timeout()
            live_finished = time.monotonic()
            result = {"schemaVersion": 1, "targetDigest": manifest_digest(manifest),
                    "mode": "approved-live-cosmos-contract", "productionFactory": "NewCosmosStore",
                    "fixtureMode": fixture_mode(manifest),
                    "development": False, "credentialMode": "AzureCLICredential",
                    "tlsVerification": "ephemeral-loopback-certificate-pinned-as-trust-anchor",
                    "passed": client.results, "acceptedNewMutations": 3,
                    "protocolRequests": client.requests,
                    "retainedTestDocumentId": prefix,
                    "preflight": preflight,
                    "notVerified": ["selected hosting/managed identity/private image pull",
                                    "measured RU and service-generated 429 under load",
                                    "regional failover and paid point-in-time restore",
                                    "physical Flutter devices and live browser CORS"]}
            if single_account:
                result["notVerified"].extend(["cross-principal real-Entra tenant/personal isolation",
                                              "cross-principal cursor binding and simultaneous distinct-user grants"])
            cleanup_started = time.monotonic()
        result["durationsSeconds"] = {"preparation": round(live_started - preparation_started, 3),
                                      "liveBffPhase": round(live_finished - live_started, 3),
                                      "cleanup": round(time.monotonic() - cleanup_started, 3)}
        return result
    except BaseException as error:
        # Includes interruption and exceptions raised by ExitStack/private-temp
        # cleanup. Never print raw exceptions, JWTs, config or arbitrary logs.
        message = str(error) if isinstance(error, GateError) else (
            "live contract interrupted; inspect the redacted partial evidence" if isinstance(error, KeyboardInterrupt)
            else "local process preparation, execution or cleanup failed; inspect the redacted partial evidence")
        safe = GateError(message)
        safe.exit_code = 130 if isinstance(error, KeyboardInterrupt) else 2
        safe.evidence = {"mode": "incomplete-approved-live-contract",
                         "fixtureMode": fixture_mode(manifest),
                         "targetDigest": manifest_digest(manifest),
                         "retainedTestDocumentId": prefix,
                         "testDataMayBeRetained": bool(client and client.write_attempted),
                         "acceptedNewMutations": "unknown-on-failure" if client and client.write_attempted else 0,
                         "passed": client.results if client else [],
                         "protocolRequests": client.requests if client else 0,
                         "livePhaseStarted": live_started is not None}
        raise safe from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--execute-approved-write-contract", action="store_true",
                        help="contact only the selected target and attempt three retained test mutations after owner approval")
    parser.add_argument("--bff-binary", type=Path, help="existing binary built from the reviewed production CLI")
    args = parser.parse_args()
    try:
        manifest = load_manifest(args.manifest)
        if args.execute_approved_write_contract:
            result = execute(manifest, args.bff_binary)
        else:
            single_account = fixture_mode(manifest) == "single-account"
            result = {"schemaVersion": 1, "mode": "offline-contract-plan",
                      "targetDigest": manifest_digest(manifest), "azureContacted": False,
                      "credentialsRead": False, "resourcesModified": False,
                      "expectedAcceptedMutations": 3,
                      "fixtureMode": fixture_mode(manifest),
                      "plannedProtocolRequests": protocol_request_plan(manifest),
                      "runtimeScope": "BFF startup and contract; read-only/local preparation and cleanup measured separately",
                      "remainingGates": ["owner target selection, credentials, retained writes and cost approval"],
                      "plannedChecks": ["production TLS/OIDC/current grants", "two actual Cosmos-backed local BFF replicas",
                                        "one-principal tenant/personal scope and writer-to-reader grant transition"
                                        if single_account else "distinct-principal shared and personal partition isolation",
                                        "atomic replay and ETag conflict",
                                        "fixed-cutover snapshot and contiguous incremental cursor",
                                        "authenticated SSE and grant revocation", "retained delete tombstone"]}
            if single_account:
                result["evidenceLimitations"] = ["distinct real-Entra principals not exercised",
                                                 "cross-principal cursor binding not exercised",
                                                 "hosted multi-replica managed identity not exercised"]
        print(json.dumps(result, indent=2))
    except GateError as error:
        if hasattr(error, "evidence"):
            print(json.dumps(error.evidence, indent=2))
        print(f"Live contract blocked: {error}", file=sys.stderr)
        return getattr(error, "exit_code", 2)
    except (OSError, subprocess.SubprocessError):
        print("Live contract blocked: local process preparation or cleanup failed", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Live contract interrupted; partial test data may be retained", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
