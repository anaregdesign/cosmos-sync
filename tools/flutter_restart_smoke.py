#!/usr/bin/env python3
"""Terminate and relaunch one exclusively selected emulator fixture APK."""
import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
import threading
import time

from device_validation import ValidationError, invoke
from flutter_app_smoke import AndroidReverse, android_target, fixture_port, stop_owned_process, write_android_evidence
from native_entra_auth import private_json

APP_ID = "com.anaregdesign.cosmos_sync_example"
ACTIVITY = APP_ID + "/.MainActivity"
REPLAY_FIELDS = {"credentialBindingStable", "operationIdStable", "verifiedSessionStable",
                 "offlineOpenWithoutRefresh", "matchingAckObserved", "localSignoutPurged"}


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def adb(identity, *arguments):
    result = invoke(["adb", "-s", identity, *arguments], timeout=20)
    require(result.returncode == 0, "Selected-emulator command failed; raw output discarded.")
    return result.stdout.strip()


def application_pid(identity):
    result = invoke(["adb", "-s", identity, "shell", "pidof", APP_ID], timeout=10)
    if result.returncode == 1 and not result.stdout.strip():
        return None
    require(result.returncode == 0 and re.fullmatch(r"[1-9][0-9]*", result.stdout.strip()),
            "The selected fixture has an ambiguous process identity.")
    return result.stdout.strip()


def await_value(predicate, seconds, message):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise ValidationError(message)


def terminate_selected_application(identity, old_pid):
    require(isinstance(old_pid, str) and re.fullmatch(r"[1-9][0-9]*", old_pid),
            "A single exact fixture process identity is required.")
    require(application_pid(identity) == old_pid, "Fixture process changed before termination.")
    adb(identity, "shell", "run-as", APP_ID, "kill", "-9", old_pid)
    await_value(lambda: application_pid(identity) is None, 10, "Old fixture process did not terminate.")


class RestartControl:
    def __init__(self, directory):
        self.directory = directory
        self.prefix = "/" + secrets.token_urlsafe(32) + "/"
        self.directory_name = "cosmos-restart-" + secrets.token_hex(16)
        self.store_key = "cosmos_sync_example.restart." + secrets.token_hex(16)
        self.phase = "write"
        self.durable = threading.Event()
        self.replayed = threading.Event()
        self.lock = threading.Lock()
        control = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *unused):
                pass

            def setup(self):
                super().setup()
                self.connection.settimeout(2)

            def reply(self, status, value):
                data = json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def permitted(self, path):
                return (self.path == control.prefix + path and self.headers.get("Origin") is None
                        and self.headers.get("Host") == "127.0.0.1:" + str(control.server.server_port))

            def do_GET(self):
                if not self.permitted("config"):
                    self.reply(404, {"error": "invalid_restart_control"})
                    return
                try:
                    ready = json.loads((control.directory / "ready.json").read_text())
                    self.reply(200, {**ready, "phase": control.phase, "directoryName": control.directory_name,
                                     "storeKey": control.store_key})
                except (OSError, ValueError):
                    self.reply(503, {"error": "fixture_not_ready"})

            def do_POST(self):
                if not (self.permitted("durable") or self.permitted("replayed")):
                    self.reply(404, {"error": "invalid_restart_control"})
                    return
                try:
                    size = int(self.headers.get("Content-Length", "0"))
                    require(0 < size <= 2048, "Invalid restart control size.")
                    value = json.loads(self.rfile.read(size))
                    with control.lock:
                        if self.path.endswith("/durable"):
                            require(control.phase == "write" and not control.durable.is_set()
                                    and isinstance(value, dict) and set(value) == {"operationId", "scopeId"}
                                    and re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value["operationId"])
                                    and re.fullmatch(r"[0-9a-f]{64}", value["scopeId"]),
                                    "Invalid durable restart expectation.")
                            private_json(control.directory / "expected.json", value)
                            control.durable.set()
                        else:
                            require(control.phase == "read" and control.durable.is_set() and not control.replayed.is_set()
                                    and isinstance(value, dict) and set(value) == REPLAY_FIELDS
                                    and all(item is True for item in value.values()), "Invalid replay evidence.")
                            control.replayed.set()
                    self.reply(200, {})
                except (ValueError, TypeError, OSError, ValidationError):
                    self.reply(400, {"error": "invalid_restart_control"})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = False
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self):
        return "http://127.0.0.1:" + str(self.server.server_port) + self.prefix

    def start(self):
        self.worker.start()

    def close(self):
        if self.worker.is_alive():
            self.server.shutdown()
        self.server.server_close()
        if self.worker.ident is not None:
            self.worker.join(timeout=5)


def run(arguments, root):
    require(arguments.exclusive_emulator, "Explicit exclusively owned emulator assertion required.")
    identity, _ = android_target(arguments, arguments.flutter_bin, emulator=True)
    require(adb(identity, "shell", "getprop", "ro.kernel.qemu") == "1", "Physical devices are prohibited.")
    require(not adb(identity, "shell", "pm", "list", "packages", APP_ID),
            "The fixture package already exists; no installation or data clearing is permitted.")
    source = invoke(["git", "rev-parse", "HEAD"], cwd=root)
    dirty = invoke(["git", "status", "--porcelain"], cwd=root)
    require(source.returncode == dirty.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}", source.stdout.strip()),
            "Cannot attribute the restart fixture to its source.")
    evidence = {
        "schemaVersion": 1, "suite": "android_native_os_process_restart_signed_fixture",
        "recordedAtUtc": datetime.now(timezone.utc).isoformat(), "sourceSha": source.stdout.strip(),
        "sourceTreeDirty": bool(dirty.stdout.strip()), "physicalDevice": False, "emulator": True,
        "auth": "signed_test_issuer_adapter", "liveOidc": False, "liveAzure": False,
        "sameInstallationRetained": False, "osProcessDeathVerified": False, "newProcessVerified": False,
        "nativeSecureBindingRestored": False, "offlinePendingOperationRestored": False,
        "exactReplayAckVerified": False, "backendDeduplicationVerified": False,
        "systemAirplaneModeTested": False, "rawOutputRetained": False, "deviceIdentityRetained": False,
        "cleanupComplete": False, "passed": False,
    }
    installed = False
    phase = "apk_build"
    process = control = reverse = None
    try:
        with tempfile.TemporaryDirectory(prefix="cosmos-sync-restart-") as temporary:
            directory = Path(temporary)
            control = RestartControl(directory)
            reverse = AndroidReverse(identity)
            stop = directory / "stop"
            control.start()
            define = "--dart-define=COSMOS_SYNC_RESTART_CONTROL_URL=" + control.url
            app = root / "examples/flutter_app"
            built = invoke(
                [arguments.flutter_bin, "build", "apk", "--debug", "--no-pub",
                 "--target=integration_test/process_restart_test.dart", define,
                 "--dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false"], cwd=app, timeout=600)
            require(built.returncode == 0, "Restart fixture build failed; raw output discarded.")
            reverse.add(control.server.server_port)
            environment = dict(os.environ, COSMOS_SYNC_E2E_READY_FILE=str(directory / "ready.json"),
                               COSMOS_SYNC_E2E_STOP_FILE=str(stop),
                               COSMOS_SYNC_RESTART_EXPECTATION_FILE=str(directory / "expected.json"))
            phase = "fixture_readiness"
            with (directory / "fixture.log").open("w+") as output:
                os.chmod(directory / "fixture.log", 0o600)
                process = subprocess.Popen(
                    [arguments.go_bin, "test", "./tests", "-run", "^TestDartRestartFixture$", "-count=1", "-v"],
                    cwd=root / "bff", env=environment, stdout=output, stderr=subprocess.STDOUT,
                    start_new_session=os.name == "posix")
                await_value(lambda: (directory / "ready.json").exists() or process.poll() is not None,
                            45, "Restart backend was not ready.")
                require(process.poll() is None, "Restart backend exited before readiness.")
                ready = json.loads((directory / "ready.json").read_text())
                reverse.add(fixture_port(ready))
                phase = "fixture_install"
                apk = app / "build/app/outputs/flutter-apk/app-debug.apk"
                adb(identity, "install", "-t", str(apk))
                installed = True
                phase = "durable_write"
                adb(identity, "shell", "am", "start", "-W", "-n", ACTIVITY)
                await_value(control.durable.is_set, 45, "Durable operation was not committed before termination.")
                old_pid = application_pid(identity)
                require(old_pid is not None, "Durable fixture process missing.")
                phase = "os_termination"
                terminate_selected_application(identity, old_pid)
                evidence["osProcessDeathVerified"] = True
                with control.lock:
                    control.phase = "read"
                phase = "same_installation_relaunch"
                adb(identity, "shell", "am", "start", "-W", "-n", ACTIVITY)
                new_pid = await_value(lambda: application_pid(identity), 10, "New fixture process missing.")
                require(old_pid != new_pid, "The old process was not replaced.")
                evidence["sameInstallationRetained"] = evidence["newProcessVerified"] = True
                phase = "durable_restore_and_replay"
                await_value(control.replayed.is_set, 45, "Restored binding/operation did not receive its matching ACK.")
                evidence["nativeSecureBindingRestored"] = evidence["offlinePendingOperationRestored"] = True
                evidence["exactReplayAckVerified"] = True
                phase = "backend_replay_confirmation"
                stop.touch()
                require(process.wait(timeout=15) == 0, "Backend exact-operation or deduplication check failed.")
                evidence["backendDeduplicationVerified"] = True
                evidence["passed"] = True
    except (ValidationError, ValueError, OSError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        evidence.update({"failureStage": phase, "failureCategory": type(error).__name__})
    finally:
        cleaned = True
        try:
            stop_owned_process(process)
            if installed:
                pid = application_pid(identity)
                if pid is not None:
                    terminate_selected_application(identity, pid)
                require(adb(identity, "uninstall", APP_ID) == "Success", "Owned fixture uninstall failed.")
        except (ValidationError, OSError, subprocess.SubprocessError):
            cleaned = False
        try:
            if control is not None:
                control.close()
        except OSError:
            cleaned = False
        if reverse is not None:
            cleaned = reverse.close() and cleaned
        evidence["cleanupComplete"] = cleaned
        evidence["passed"] = evidence["passed"] and cleaned
        write_android_evidence(arguments.output, evidence)
    print(json.dumps(evidence, indent=2))
    return 0 if evidence["passed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", choices=("android-emulator",), default="android-emulator")
    parser.add_argument("--device-id-file", required=True)
    parser.add_argument("--authorize-install", action="store_true")
    parser.add_argument("--exclusive-emulator", action="store_true")
    parser.add_argument("--output", required=True)
    parser.add_argument("--flutter-bin", default=os.environ.get("FLUTTER_BIN", "flutter"))
    parser.add_argument("--go-bin", default=os.environ.get("GO_BIN", "go"))
    return run(parser.parse_args(), Path(__file__).resolve().parents[1])


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError:
        print("Restart fixture preflight rejected; no physical-device fallback.")
        raise SystemExit(2)
