#!/usr/bin/env python3
"""Run the native Flutter UI against a disposable authenticated Go BFF.

Only a loopback control URL is compiled into the test target. Disposable JWTs
remain in a private temporary ready file and the control response, never logs.
The ordinary Flutter main target contains no test authentication path.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", default="macos")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    flutter = os.environ.get("FLUTTER_BIN", "flutter")
    app = root / "examples/flutter_app"
    target = "integration_test/app_flow_test.dart"
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
            env = dict(os.environ, COSMOS_SYNC_E2E_READY_FILE=str(ready),
                       COSMOS_SYNC_E2E_STOP_FILE=str(stop))
            with (directory / "go-test.log").open("w+") as output:
                server = subprocess.Popen(
                    ["go", "test", "./tests", "-run", "^TestDartFixture$", "-count=1", "-v"],
                    cwd=root / "bff", env=env, stdout=output, stderr=subprocess.STDOUT,
                )
                deadline = time.monotonic() + 60
                while not ready.exists():
                    if server.poll() is not None:
                        raise RuntimeError("Go fixture exited before becoming ready")
                    if time.monotonic() > deadline:
                        raise TimeoutError("Go fixture readiness timeout")
                    time.sleep(0.1)
                json.loads(ready.read_text())
                try:
                    subprocess.run([flutter, "test", target, "-d", args.device, define],
                                   cwd=app, check=True, timeout=80)
                    stop.touch()
                    if server.wait(timeout=10) != 0:
                        raise RuntimeError("Go fixture failed")
                finally:
                    stop.touch()
                    if server.poll() is None:
                        server.terminate()
                        try:
                            server.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            server.kill()
                            server.wait()
                    output.seek(0)
                    print(output.read(), end="")
        finally:
            stop.touch()
            if server is not None and server.poll() is None:
                server.terminate()
                server.wait(timeout=10)
            control.shutdown()
            control.server_close()
            worker.join(timeout=5)


if __name__ == "__main__":
    main()
