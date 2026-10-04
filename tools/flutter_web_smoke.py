#!/usr/bin/env python3
"""Run the ordinary Web UI/controllers with real IndexedDB and signed Go HTTP.

The adapter is test-target-only. Tokens stay in the private Go ready file and
loopback control response. An actual page reload must be observed separately
from the browser's reported assertions. This does not perform live OIDC/Azure.
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
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit

from flutter_app_smoke import stop_owned_process, write_android_evidence as write_evidence


EXPECTED_FLAGS = (
    "passed", "real_http", "real_indexeddb", "document_reload",
    "offline_rebind_refused", "exact_operation_retained", "server_ack", "logout_purge",
)


def valid_checkpoint(value):
    return (isinstance(value, dict) and set(value) == {"operation"}
            and isinstance(value["operation"], str)
            and re.fullmatch(r"[A-Za-z0-9_-]{16,128}", value["operation"]) is not None)


def valid_result(value, reload_seen):
    return (isinstance(value, dict)
            and set(value) == set(EXPECTED_FLAGS) | {"auth"}
            and all(value.get(flag) is True for flag in EXPECTED_FLAGS)
            and value.get("auth") == "signed_test_issuer_adapter"
            and reload_seen is True)


class FixtureHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == "/fixture":
            if not self.server.ready_file.exists():
                self.send_error(503)
                return
            value = json.loads(self.server.ready_file.read_text())
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
        if url.path == "/" and parse_qs(url.query).get("phase") == ["reloaded"]:
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
        except (ValueError, TypeError):
            self.send_error(400)
            return
        if self.path == "/checkpoint":
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


def chrome_path():
    value = os.environ.get("CHROME_EXECUTABLE") or shutil.which("google-chrome")
    if not value and os.name == "posix":
        candidate = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        if candidate.is_file():
            value = str(candidate)
    if not value or not Path(value).is_file():
        raise RuntimeError("Set CHROME_EXECUTABLE to the installed Chromium executable.")
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    app = root / "examples/flutter_app"
    chrome = chrome_path()
    flutter = os.environ.get("FLUTTER_BIN", "flutter")
    evidence = {
        "schema_version": 1,
        "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "source_tree_dirty": bool(subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=normal"], cwd=root, text=True).strip()),
        "platform": "web", "physical_device": False, "emulator": False,
        "suite": "flutter_web_real_http_signed_fixture",
        "auth": "signed_test_issuer_adapter", "live_oidc": False, "live_azure": False,
        "live_bff": True, "raw_output_retained": False,
        "passed": False, "owned_process_cleanup_passed": False,
    }
    with tempfile.TemporaryDirectory(prefix="cosmos-flutter-web-") as temporary:
        directory = Path(temporary)
        web_root = directory / "web"
        web_root.mkdir()
        ready = directory / "ready.private.json"
        stop = directory / "stop"
        handler = functools.partial(FixtureHandler, directory=str(web_root))
        control = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        control.ready_file = ready
        control.namespace = "cosmos-web-ui-" + secrets.token_hex(8)
        control.checkpoint = None
        control.reload_seen = False
        control.result = None
        control.finished = threading.Event()
        origin = f"http://127.0.0.1:{control.server_port}"
        worker = threading.Thread(target=control.serve_forever, daemon=True)
        worker.start()
        server = browser = None
        failure = None
        try:
            subprocess.run(
                [flutter, "build", "web", "--no-pub", "--debug", "--no-wasm-dry-run",
                 "--no-web-resources-cdn", "--target=integration_test/web_app_flow_test.dart",
                 "--output=" + str(web_root)],
                cwd=app, check=True, timeout=300, stdout=subprocess.DEVNULL,
                stderr=subprocess.STDOUT,
            )
            with (directory / "go.private.log").open("w+") as output:
                os.chmod(output.name, 0o600)
                env = dict(os.environ, COSMOS_SYNC_E2E_READY_FILE=str(ready),
                           COSMOS_SYNC_E2E_STOP_FILE=str(stop), COSMOS_SYNC_E2E_ORIGIN=origin)
                server = subprocess.Popen(
                    ["go", "test", "./tests", "-run", "^TestDartFixture$", "-count=1"],
                    cwd=root / "bff", env=env, stdout=output, stderr=subprocess.STDOUT,
                    start_new_session=os.name == "posix",
                )
                deadline = time.monotonic() + 45
                while not ready.exists():
                    if server.poll() is not None:
                        raise RuntimeError("Signed Go fixture exited before readiness.")
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Signed Go fixture readiness timed out.")
                    time.sleep(0.1)
                browser = subprocess.Popen(
                    [chrome, "--headless=new", "--no-sandbox", "--disable-gpu", "--no-first-run",
                     "--no-default-browser-check", "--window-size=1280,1000",
                     "--user-data-dir=" + str(directory / "chrome-profile"), origin],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    start_new_session=os.name == "posix",
                )
                if not control.finished.wait(70):
                    raise TimeoutError("Flutter Web UI did not report within its live window.")
                evidence["actual_reload_request_seen"] = control.reload_seen
                if isinstance(control.result, dict):
                    evidence["reported_runtime_flags"] = {
                        flag: control.result.get(flag) is True for flag in EXPECTED_FLAGS
                    }
                    lines = control.result.get("failure_source_lines", [])
                    evidence["failure_source_lines"] = [
                        line for line in lines if isinstance(line, int) and 1 <= line <= 1000
                    ] if isinstance(lines, list) else []
                    stage = control.result.get("failure_stage")
                    if stage in {
                        "startup", "reload-signed-out", "reload-interactive-sign-in",
                        "online-rebind", "retained-operation", "online-connect",
                        "server-ack", "logout",
                    }:
                        evidence["failure_stage"] = stage
                if not valid_result(control.result, control.reload_seen):
                    raise RuntimeError("Flutter Web UI acceptance failed.")
                evidence.update({flag: True for flag in EXPECTED_FLAGS})
                evidence["actual_reload_request_seen"] = control.reload_seen
                stop.touch()
                if server.wait(timeout=10) != 0:
                    raise RuntimeError("Signed Go fixture did not exit successfully.")
                evidence["go_fixture_passed"] = True
        except (OSError, ValueError, RuntimeError, TimeoutError, subprocess.SubprocessError) as error:
            failure = type(error).__name__
            evidence["passed"] = False
            evidence["failure_category"] = failure
        finally:
            stop.touch()
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
            raise RuntimeError("Web fixture failed; no raw credentials or browser output were retained.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
