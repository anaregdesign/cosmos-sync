#!/usr/bin/env python3
"""Actual Code/S256 browser OIDC, Go JWTs and Flutter cache/reload acceptance.

Only an owned fresh Chromium profile trusts the ephemeral test certificate SPKI.
No JWT/refresh token is supplied to an authentication adapter or readiness file.
Production browser bundles, callbacks and the normal WebOidcClient are exercised.
"""
import argparse
from datetime import datetime, timezone
import functools
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import ssl
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit
from urllib.request import urlopen

from flutter_app_smoke import stop_owned_process, write_android_evidence as write_evidence
from flutter_web_smoke import chrome_path, valid_checkpoint


PROTOCOL_CHECKS = (
    "code_s256_nonce_signed_id", "api_jwt_bff_authority", "memory_refresh_no_id",
    "no_persistent_credentials", "denied_id_issuer", "denied_id_audience",
    "denied_id_signature", "denied_id_nonce", "denied_state",
    "denied_api_issuer", "denied_api_audience", "denied_api_scope",
    "no_refresh_no_iframe", "refresh_subject_switch", "invalid_refresh",
    "popup_cancel_fenced", "token_cancel_fenced", "callback_adapter_pinning",
    "independent_subject_sessions", "provider_logout",
)
APP_FLAGS = (
    "passed", "real_http", "real_indexeddb", "document_reload",
    "offline_rebind_refused", "exact_operation_retained", "server_ack",
    "logout_purge", "different_identity_isolated",
)
APP_STAGES = {
    "startup", "configure-generic-ui", "real-popup-api-bind", "reload-signed-out",
    "different-identity-isolated", "reload-original-identity", "retained-operation",
    "server-ack", "logout",
}
PROTOCOL_STAGES = set(PROTOCOL_CHECKS) | {
    "startup", "normal", "refresh-no-id", "bad-id-issuer", "bad-id-audience",
    "bad-id-signature", "bad-id-nonce", "bad-state", "bad-api-issuer",
    "bad-api-audience", "bad-api-scope", "no-refresh", "refresh-subject-switch",
    "invalid-refresh", "slow-authorization", "slow-token",
}
PUBLIC_FIELDS = {"url", "issuer", "clientId", "redirectUrl", "scopes", "discoveryUrl"}
COUNTERS = {
    "authorization_requests", "code_exchanges", "code_replays_denied", "callback_denied",
    "pkce_verified", "pkce_denied", "refresh_exchanges", "jwks_requests",
}


def loopback_url(value, scheme):
    if not isinstance(value, str):
        return False
    try:
        parsed = urlsplit(value)
        return (parsed.scheme == scheme and parsed.hostname == "127.0.0.1"
                and parsed.port is not None and 1 <= parsed.port <= 65535
                and not parsed.username and not parsed.password
                and not parsed.path and not parsed.query and not parsed.fragment)
    except ValueError:
        return False


def valid_ready(value, origin):
    return (isinstance(value, dict)
            and set(value) == PUBLIC_FIELDS | {"certificate", "spki"}
            and loopback_url(value.get("url"), "http")
            and loopback_url(value.get("issuer"), "https")
            and value.get("clientId") == "non-uuid-browser-public-client"
            and value.get("redirectUrl") == origin + "/oidc-redirect.html"
            and value.get("scopes") == ["openid", "offline_access", "cosmos_sync"]
            and value.get("discoveryUrl") == value["issuer"] + "/.well-known/openid-configuration"
            and isinstance(value.get("certificate"), str)
            and 1 <= len(value["certificate"]) <= 8192
            and value["certificate"].startswith("-----BEGIN CERTIFICATE-----\n")
            and isinstance(value.get("spki"), str)
            and re.fullmatch(r"[A-Za-z0-9+/]{43}=", value["spki"]) is not None)


def valid_protocol(value):
    return (isinstance(value, dict)
            and set(value) == {"passed", "checks", "auth"}
            and value.get("passed") is True
            and value.get("checks") == list(PROTOCOL_CHECKS)
            and value.get("auth") == "actual_generic_oidc_popup")


def valid_app(value, reload_seen):
    return (isinstance(value, dict)
            and set(value) == set(APP_FLAGS) | {"auth"}
            and all(value.get(flag) is True for flag in APP_FLAGS)
            and value.get("auth") == "actual_generic_oidc_popup"
            and reload_seen is True)


def valid_counters(value):
    if not isinstance(value, dict) or not set(value).issubset(COUNTERS) or any(
            type(count) is not int or not 0 <= count <= 1000 for count in value.values()):
        return False
    return (value.get("authorization_requests", 0) >= 15
            and value.get("code_exchanges", 0) >= 13
            and value.get("pkce_verified", 0) >= 10
            and value.get("refresh_exchanges", 0) >= 3
            and value.get("jwks_requests", 0) >= 10)


class FixtureHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path == "/fixture":
            ready = self.server.ready
            if ready is None:
                self.send_error(503)
                return
            value = {key: ready[key] for key in PUBLIC_FIELDS}
            value["namespace"] = self.server.namespace
            if self.server.checkpoint is not None:
                value.update(self.server.checkpoint)
            payload = json.dumps(value).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if parsed.path == "/" and parse_qs(parsed.query).get("phase") == ["reloaded"]:
            if self.server.checkpoint is None:
                self.send_error(409)
                return
            self.server.reload_seen = True
        super().do_GET()

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 1 <= length <= 4096:
                self.send_error(413)
                return
            value = json.loads(self.rfile.read(length))
        except (TypeError, ValueError):
            self.send_error(400)
            return
        if self.path == "/protocol-result":
            if self.server.protocol is not None:
                self.send_error(409)
                return
            self.server.protocol = value
            if not valid_protocol(value):
                self.server.finished.set()
        elif self.path == "/checkpoint":
            if not valid_checkpoint(value) or self.server.checkpoint is not None:
                self.send_error(409)
                return
            self.server.checkpoint = value
        elif self.path == "/result":
            self.server.result = value
            self.server.finished.set()
        else:
            self.send_error(404)
            return
        self.send_response(204)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def log_message(self, *unused):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    app = root / "examples/flutter_app"
    evidence = {
        "schema_version": 1, "suite": "actual_generic_browser_oidc",
        "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "source_tree_dirty": bool(subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=normal"], cwd=root, text=True).strip()),
        "platform": "web", "physical_device": False, "live_oidc": False, "live_azure": False,
        "auth": "actual_generic_oidc_popup", "production_browser_adapter": True,
        "ephemeral_https_test_issuer": True, "injected_access_token": False,
        "global_tls_bypass": False, "fresh_owned_chromium_profile": True,
        "raw_output_retained": False, "passed": False, "owned_process_cleanup_passed": False,
    }
    with tempfile.TemporaryDirectory(prefix="cosmos-browser-oidc-") as temporary:
        directory = Path(temporary)
        web_root = directory / "web"
        web_root.mkdir()
        handler = functools.partial(FixtureHandler, directory=str(web_root))
        control = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        origin = f"http://127.0.0.1:{control.server_port}"
        control.ready = None
        control.namespace = "cosmos-web-oidc-" + secrets.token_hex(8)
        control.checkpoint = control.protocol = control.result = None
        control.reload_seen = False
        control.finished = threading.Event()
        worker = threading.Thread(target=control.serve_forever, daemon=True)
        worker.start()
        ready_file = directory / "ready.private.json"
        stop_file = directory / "stop"
        browser = server = None
        try:
            chrome = chrome_path()
            subprocess.run(["npm", "run", "build:auth"], cwd=app, check=True, timeout=60,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(
                [os.environ.get("FLUTTER_BIN", "flutter"), "build", "web", "--no-pub", "--debug",
                 "--no-wasm-dry-run", "--no-web-resources-cdn",
                 "--target=integration_test/web_generic_oidc_test.dart", "--output=" + str(web_root)],
                cwd=app, check=True, timeout=300, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            shutil.copyfile(
                app / "integration_test/support/browser_oidc_acceptance.js", web_root / "protocol.js",
            )
            (web_root / "protocol.html").write_text(
                '<!doctype html><meta name="referrer" content="no-referrer">'
                '<title>Disposable OIDC acceptance</title><script src="auth.js"></script>'
                '<script src="protocol.js"></script>', encoding="utf-8",
            )
            with (directory / "go.private.log").open("w+") as output:
                os.chmod(output.name, 0o600)
                env = dict(os.environ, COSMOS_SYNC_BROWSER_OIDC_READY_FILE=str(ready_file),
                           COSMOS_SYNC_BROWSER_OIDC_STOP_FILE=str(stop_file),
                           COSMOS_SYNC_BROWSER_OIDC_ORIGIN=origin)
                server = subprocess.Popen(
                    ["go", "test", "-race", "./tests", "-run", "^TestBrowserOIDCFixture$", "-count=1"],
                    cwd=root / "bff", env=env, stdout=output, stderr=subprocess.STDOUT,
                    start_new_session=os.name == "posix",
                )
                deadline = time.monotonic() + 45
                while not ready_file.exists():
                    if server.poll() is not None:
                        raise RuntimeError("Go browser OIDC fixture exited before readiness.")
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Go browser OIDC fixture readiness timed out.")
                    time.sleep(0.1)
                ready = json.loads(ready_file.read_text())
                if not valid_ready(ready, origin):
                    raise RuntimeError("Browser OIDC readiness does not match the owned fixture.")
                control.ready = ready
                tls = ssl.create_default_context(cadata=ready["certificate"])
                with urlopen(ready["issuer"] + "/_fixture/receipt", context=tls, timeout=10) as response:
                    json.load(response)
                browser = subprocess.Popen(
                    [chrome, "--headless=new", "--no-sandbox", "--disable-gpu", "--no-first-run",
                     "--no-default-browser-check", "--disable-popup-blocking", "--window-size=1280,1000",
                     "--ignore-certificate-errors-spki-list=" + ready["spki"],
                     "--user-data-dir=" + str(directory / "chrome-profile"), origin + "/protocol.html"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    start_new_session=os.name == "posix",
                )
                if browser.poll() is not None or not control.finished.wait(140):
                    raise TimeoutError("Actual browser OIDC/Flutter acceptance did not finish.")
                evidence["protocol_checks_passed"] = valid_protocol(control.protocol)
                evidence["actual_reload_request_seen"] = control.reload_seen
                evidence["reported_runtime_flags"] = {
                    flag: isinstance(control.result, dict) and control.result.get(flag) is True
                    for flag in APP_FLAGS
                }
                for result, stages in [(control.protocol, PROTOCOL_STAGES), (control.result, APP_STAGES)]:
                    if isinstance(result, dict) and isinstance(result.get("failure_stage"), str) \
                            and result["failure_stage"] in stages:
                        evidence["failure_stage"] = result["failure_stage"]
                if isinstance(control.protocol, dict):
                    checks = control.protocol.get("checks")
                    evidence["completed_protocol_checks"] = [
                        check for check in checks if check in PROTOCOL_CHECKS
                    ] if isinstance(checks, list) else []
                if isinstance(control.result, dict):
                    lines = control.result.get("failure_source_lines", [])
                    evidence["failure_source_lines"] = [
                        line for line in lines if type(line) is int and 1 <= line <= 1000
                    ] if isinstance(lines, list) else []
                with urlopen(ready["issuer"] + "/_fixture/receipt", context=tls, timeout=10) as response:
                    counters = json.load(response)
                evidence["actual_protocol_counters"] = {
                    key: value for key, value in counters.items()
                    if key in COUNTERS and type(value) is int and 0 <= value <= 1000
                } if isinstance(counters, dict) else {}
                if not valid_protocol(control.protocol) or not valid_app(control.result, control.reload_seen) \
                        or not valid_counters(counters):
                    raise RuntimeError("Actual browser OIDC/Flutter acceptance failed.")
                stop_file.touch()
                if server.wait(timeout=10) != 0:
                    raise RuntimeError("The Go browser OIDC fixture failed.")
                evidence.update({flag: True for flag in APP_FLAGS})
                evidence["protocol_checks"] = list(PROTOCOL_CHECKS)
                evidence["go_fixture_passed"] = True
        except (OSError, ValueError, RuntimeError, TimeoutError, subprocess.SubprocessError) as error:
            evidence["passed"] = False
            evidence["failure_category"] = type(error).__name__
        finally:
            stop_file.touch()
            try:
                stop_owned_process(browser)
                stop_owned_process(server)
                control.shutdown()
                control.server_close()
                worker.join(timeout=5)
                evidence["owned_process_cleanup_passed"] = not worker.is_alive()
            except (OSError, subprocess.SubprocessError, RuntimeError):
                evidence["owned_process_cleanup_passed"] = False
            evidence["passed"] = evidence["passed"] and evidence["owned_process_cleanup_passed"]
        if args.output:
            write_evidence(args.output, evidence)
        print(json.dumps(evidence, indent=2, sort_keys=True))
        if not evidence["passed"]:
            raise RuntimeError("Browser OIDC acceptance failed; only sanitized evidence was retained.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
