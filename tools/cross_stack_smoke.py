#!/usr/bin/env python3
"""Run Dart against a disposable Go BFF with a real local JWT issuer."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="cosmos-sync-fixture-") as temporary:
        directory = Path(temporary)
        ready = directory / "ready.json"
        stop = directory / "stop"
        log = directory / "go-test.log"
        env = dict(os.environ, COSMOS_SYNC_E2E_READY_FILE=str(ready),
                   COSMOS_SYNC_E2E_STOP_FILE=str(stop))
        with log.open("w+") as output:
            server = subprocess.Popen(
                ["go", "test", "./tests", "-run", "^TestDartFixture$", "-count=1", "-v"],
                cwd=root / "bff", env=env, stdout=output, stderr=subprocess.STDOUT,
            )
            try:
                deadline = time.monotonic() + 60
                while not ready.exists():
                    if server.poll() is not None:
                        raise RuntimeError("Go fixture exited before becoming ready")
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Go fixture did not become ready in 60 seconds")
                    time.sleep(0.1)
                # Confirm complete JSON without printing the disposable token.
                json.loads(ready.read_text())
                subprocess.run(
                    [os.environ.get("DART_BIN", "dart"), "run", "tool/cross_stack_smoke.dart", str(ready)],
                    cwd=root / "packages/cosmos_sync", check=True, timeout=45,
                )
                stop.touch()
                if server.wait(timeout=10) != 0:
                    raise RuntimeError("Go fixture test failed")
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


if __name__ == "__main__":
    main()
