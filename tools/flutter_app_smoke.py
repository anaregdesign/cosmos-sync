#!/usr/bin/env python3
"""Run the native Flutter UI against a disposable authenticated Go BFF.

Only a loopback control URL is compiled into the test target. Disposable JWTs
remain in a private temporary ready file and the control response, never logs.
The ordinary Flutter main target contains no test authentication path.
"""
import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlsplit

from device_validation import (
    ValidationError, invoke, safe_model, select_physical_device,
    selected_identity,
)


def evidence_destination(output):
    candidate = Path(output)
    destination = candidate.resolve()
    root = Path(__file__).resolve().parents[1]
    if not destination.is_relative_to(root / "artifacts"):
        raise ValidationError("Evidence must be written in the ignored repository artifacts directory.")
    if os.path.lexists(candidate) or destination.exists():
        raise ValidationError("Evidence already exists; choose a fresh ignored destination.")
    return destination


def write_android_evidence(output, evidence):
    destination = evidence_destination(output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=destination.parent, delete=False, encoding="utf-8") as handle:
        temporary = Path(handle.name)
        json.dump(evidence, handle, indent=2, sort_keys=True)
        handle.write("\n")
    try:
        os.chmod(temporary, 0o600)
        # Exclusive link creation avoids a check-then-replace overwrite race.
        os.link(temporary, destination)
    except FileExistsError as error:
        raise ValidationError("Evidence already exists; it was preserved.") from error
    finally:
        temporary.unlink(missing_ok=True)


def private_android_identity(file):
    identity = selected_identity(file)
    path = Path(file).resolve()
    try:
        private_mode = stat.S_IMODE(path.stat().st_mode)
    except OSError as error:
        raise ValidationError("Cannot inspect the private device identity file.") from error
    if private_mode != 0o600:
        raise ValidationError("The ignored device identity file must have mode 0600.")
    return identity


def android_target(arguments, flutter):
    """Resolve an exact authorized physical target without printing its identity."""
    if not arguments.authorize_install:
        raise ValidationError("Android installation and launch require explicit owner authorization.")
    if not arguments.device_id_file:
        raise ValidationError("Android requires a private exact device identity file.")
    identity = private_android_identity(arguments.device_id_file)
    if not arguments.output:
        raise ValidationError("Android requires an ignored evidence destination.")
    evidence_destination(arguments.output)
    result = invoke([flutter, "devices", "--machine"], timeout=45)
    if result.returncode != 0:
        raise ValidationError("Flutter device discovery failed; no app was installed.")
    try:
        device = select_physical_device(json.loads(result.stdout), identity, "android")
    except (ValueError, TypeError) as error:
        raise ValidationError("Flutter device discovery returned invalid data.") from error
    return identity, device


def fixture_port(payload):
    """Do not forward any endpoint except the fixture's bare IPv4 loopback URL."""
    try:
        url = urlsplit(payload["url"])
        if (url.scheme != "http" or url.hostname != "127.0.0.1"
                or url.username is not None or url.password is not None
                or url.path or url.query or url.fragment or url.port is None):
            raise ValueError("Invalid fixture endpoint")
        return url.port
    except (KeyError, TypeError, ValueError) as error:
        raise ValidationError("The Go fixture returned an invalid loopback endpoint.") from error


def android_runtime_status(result):
    marker = ("COSMOS_SYNC_APP_PASS android realHttp=true realSqlite=true "
              "auth=test-adapter nativeSecureStorage=verified")
    output = result.stdout + result.stderr
    seen = marker in output
    return {"exit_code": result.returncode, "expected_runtime_marker_seen": seen,
            "native_secure_storage_verified": seen and result.returncode == 0,
            "controller_state": {name: value == "true" for name, value in re.findall(
                r"\b(settingsSaved|signedIn|authError|appBusy|workspaceBusy|workspaceConnected|appMessage|workspaceMessage)=(true|false)\b",
                output) if "COSMOS_SYNC_APP_STATE" in output},
            "diagnostic_flags": {name: literal in output for name, literal in (
                ("socket_exception", "SocketException"), ("timeout_exception", "TimeoutException"),
                ("expectation_failure", "TestFailure"), ("plugin_exception", "PlatformException"),
                ("missing_plugin", "MissingPluginException"), ("gradle_failed", "Gradle task assembleDebug failed"),
                ("install_failed", "Error: ADB exited"), ("vm_service_failed", "VM Service is not available"),
                ("tap_missed_hit_test", "would not hit test on the specified widget"))},
            "integration_source_lines": sorted({int(line) for line in re.findall(r"app_flow_test\.dart:(\d+):", output)})}


class AndroidReverse:
    """Own only new mappings on the explicitly selected device."""
    def __init__(self, identity):
        self.identity = identity
        self.ports = []

    def add(self, port):
        if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
            raise ValidationError("Invalid loopback forwarding port.")
        # --no-rebind rejects an existing mapping, including one created by a
        # different local tool between discovery and this command.
        result = invoke(["adb", "-s", self.identity, "reverse", "--no-rebind",
                         f"tcp:{port}", f"tcp:{port}"], timeout=15)
        if result.returncode != 0:
            raise ValidationError("A selected-device loopback mapping could not be created safely.")
        self.ports.append(port)

    def close(self):
        success = True
        for port in reversed(self.ports):
            try:
                listed = invoke(["adb", "-s", self.identity, "reverse", "--list"], timeout=15)
                mappings = [line.split() for line in listed.stdout.splitlines()]
                matches = [row for row in mappings if len(row) >= 2 and row[-2] == f"tcp:{port}"]
                if listed.returncode != 0 or len(matches) != 1 or matches[0][-1] != f"tcp:{port}":
                    # A different tool may have replaced our mapping. Never
                    # remove it or any unrelated reverse connection.
                    success = False
                    continue
                result = invoke(["adb", "-s", self.identity, "reverse", "--remove",
                                 f"tcp:{port}"], timeout=15)
                success = result.returncode == 0 and success
            except ValidationError:
                success = False
        self.ports.clear()
        return success


def stop_owned_process(process):
    if process is None or process.poll() is not None:
        return
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
        process.wait(timeout=5)
    except ProcessLookupError:
        process.wait(timeout=5)


def cleanup_fixture(process, control, worker, reverse):
    result = {"owned_process_cleanup_passed": True, "control_cleanup_passed": True,
              "owned_reverse_cleanup_passed": True}
    try:
        stop_owned_process(process)
    except (OSError, subprocess.SubprocessError):
        result["owned_process_cleanup_passed"] = False
    try:
        control.shutdown()
    except OSError:
        result["control_cleanup_passed"] = False
    try:
        control.server_close()
    except OSError:
        result["control_cleanup_passed"] = False
    try:
        worker.join(timeout=5)
        result["control_cleanup_passed"] = not worker.is_alive() and result["control_cleanup_passed"]
    except RuntimeError:
        result["control_cleanup_passed"] = False
    if reverse is not None:
        result["owned_reverse_cleanup_passed"] = reverse.close()
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", choices=("macos", "android"), default="macos")
    parser.add_argument("--device-id-file")
    parser.add_argument("--authorize-install", action="store_true")
    parser.add_argument("--output")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    flutter = os.environ.get("FLUTTER_BIN", "flutter")
    app = root / "examples/flutter_app"
    target = "integration_test/app_flow_test.dart"
    identity, device = android_target(args, flutter) if args.device == "android" else ("macos", None)
    reverse = AndroidReverse(identity) if device is not None else None
    evidence = None
    failure = None
    phase = "preparing"
    if device is not None:
        commit = invoke(["git", "rev-parse", "HEAD"]).stdout.strip()
        status_result = invoke(["git", "status", "--porcelain", "--untracked-files=normal"])
        version_result = invoke([flutter, "--version", "--machine"], timeout=30)
        try:
            version = json.loads(version_result.stdout) if version_result.returncode == 0 else {}
        except ValueError:
            version = {}
        evidence = {
            "schema_version": 1,
            "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
            "commit": commit if re.fullmatch(r"[0-9a-f]{40}", commit) else "unknown",
            "source_tree_dirty": bool(status_result.stdout.strip()) if status_result.returncode == 0 else None,
            "platform": "android", "physical_device": True,
            "device_runtime": safe_model(device.get("sdk", "unknown")),
            "flutter_version": safe_model(version.get("frameworkVersion")),
            "dart_version": safe_model(version.get("dartSdkVersion")),
            "suite": "flutter_app_real_http_signed_fixture",
            "storage": "real_app_private_sqlite", "mode": "debug",
            "auth": "signed_test_issuer_adapter", "live_bff": True,
            "live_oidc": False, "live_azure": False,
            "os_process_death_tested": False, "system_airplane_mode_tested": False,
            "raw_output_retained": False, "device_identity_retained": False,
            "passed": False, "expected_runtime_marker_seen": False,
            "native_secure_storage_verified": False, "go_fixture_passed": False,
            "owned_reverse_cleanup_passed": False,
        }
    with tempfile.TemporaryDirectory(prefix="cosmos-flutter-fixture-") as temporary:
        directory = Path(temporary)
        ready = directory / "ready.json"
        stop = directory / "stop"

        class ControlHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != "/fixture" or not ready.exists():
                    self.send_error(503)
                    return
                payload = ready.read_bytes()
                json.loads(payload)
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *unused):
                pass

        control = ThreadingHTTPServer(("127.0.0.1", 0), ControlHandler)
        worker = threading.Thread(target=control.serve_forever, daemon=True)
        worker.start()
        define = f"--dart-define=COSMOS_SYNC_TEST_FIXTURE_URL=http://127.0.0.1:{control.server_port}/fixture"
        server = None
        try:
            # Prebuild before the bounded Go fixture starts. A normal flutter
            # test invocation then launches the identical already-built target.
            if args.device == "macos":
                subprocess.run([flutter, "build", "macos", "--debug", f"--target={target}", define],
                               cwd=app, check=True, timeout=600)
            else:
                phase = "apk_build"
                print("Android app fixture: preparing the debug APK before starting the bounded BFF.", flush=True)
                built = invoke([flutter, "build", "apk", "--debug", f"--target={target}", define,
                                "--dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false"],
                               cwd=app, timeout=600)
                if built.returncode != 0:
                    raise ValidationError("Android fixture APK build failed; raw tool output was discarded.")
                phase = "control_reverse"
                reverse.add(control.server_port)
                print("Android app fixture: APK prepared; starting the disposable BFF.", flush=True)
            env = dict(os.environ, COSMOS_SYNC_E2E_READY_FILE=str(ready),
                       COSMOS_SYNC_E2E_STOP_FILE=str(stop))
            with (directory / "go-test.log").open("w+") as output:
                os.chmod(directory / "go-test.log", 0o600)
                server = subprocess.Popen(
                    ["go", "test", "./tests", "-run", "^TestDartFixture$", "-count=1", "-v"],
                    cwd=root / "bff", env=env, stdout=output, stderr=subprocess.STDOUT,
                    start_new_session=os.name == "posix",
                )
                phase = "fixture_readiness"
                deadline = time.monotonic() + 60
                while not ready.exists():
                    if server.poll() is not None:
                        raise RuntimeError("Go fixture exited before becoming ready")
                    if time.monotonic() > deadline:
                        raise TimeoutError("Go fixture readiness timeout")
                    time.sleep(0.1)
                payload = json.loads(ready.read_text())
                if reverse is not None:
                    phase = "api_reverse"
                    reverse.add(fixture_port(payload))
                try:
                    if device is None:
                        subprocess.run([flutter, "test", target, "-d", identity, define],
                                       cwd=app, check=True, timeout=80)
                    else:
                        phase = "android_runtime"
                        print("Android app fixture: loopback links ready; running the real app UI.", flush=True)
                        result = invoke([flutter, "test", "--no-pub", target, "-d", identity, define],
                                        cwd=app, timeout=80)
                        evidence.update(android_runtime_status(result))
                        if result.returncode != 0 or not evidence["expected_runtime_marker_seen"]:
                            raise ValidationError("Android fixture did not complete with its expected verified runtime marker.")
                    stop.touch()
                    phase = "go_fixture_exit"
                    if server.wait(timeout=10) != 0:
                        raise RuntimeError("Go fixture failed")
                    if evidence is not None:
                        evidence["go_fixture_passed"] = True
                        evidence["passed"] = True
                finally:
                    stop.touch()
                    stop_owned_process(server)
                    if device is None:
                        output.seek(0)
                        print(output.read(), end="")
        except (ValidationError, RuntimeError, TimeoutError, ValueError, OSError,
                subprocess.SubprocessError, KeyboardInterrupt) as error:
            if device is None:
                raise
            # Do not print exception details from subprocesses, URLs or tools.
            failure = "Android fixture failed or was interrupted; raw output was discarded."
            evidence["failure_category"] = type(error).__name__
            evidence["failure_stage"] = phase
            evidence["bounded_command_interrupted"] = (
                isinstance(error, ValidationError)
                and str(error) == "Command interrupted or timed out; its local process group was stopped.")
        finally:
            stop.touch()
            cleanup = cleanup_fixture(server, control, worker, reverse)
            if reverse is not None:
                evidence.update(cleanup)
                evidence["passed"] = evidence["passed"] and all(cleanup.values())
                write_android_evidence(args.output, evidence)
                print(json.dumps(evidence, indent=2, sort_keys=True), flush=True)
            elif not all(cleanup.values()):
                raise RuntimeError("Native fixture cleanup did not complete.")
    if failure:
        print(failure, flush=True)
    return 0 if evidence is None or evidence["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as error:
        print(str(error))
        raise SystemExit(2)
