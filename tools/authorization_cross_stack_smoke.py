#!/usr/bin/env python3
"""Verify typed Dart authorization against a disposable signed-JWT Go TLS BFF.

The complete run is bounded to 60 seconds. No Azure calls or real credentials
are used. Ready JSON and its disposable tokens remain in a private temp folder.
"""
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import tempfile
import time
from urllib.parse import urlsplit


def _remaining(deadline, reserve=0):
    seconds = deadline - time.monotonic() - reserve
    if seconds <= 0:
        raise TimeoutError("Authorization cross-stack run exceeded 60 seconds")
    return seconds


def _stop_group(process):
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=1)


def main():
    root = Path(__file__).resolve().parents[1]
    deadline = time.monotonic() + 60
    with tempfile.TemporaryDirectory(prefix="cosmos-sync-authorization-") as temporary:
        directory = Path(temporary)
        ready = directory / "ready.json"
        stop = directory / "stop"
        log = directory / "go-test.log"
        environment = dict(
            os.environ,
            COSMOS_SYNC_AUTHORIZATION_READY_FILE=str(ready),
            COSMOS_SYNC_AUTHORIZATION_STOP_FILE=str(stop),
        )
        with log.open("w+") as output:
            server = subprocess.Popen(
                ["go", "test", "./tests", "-run", "^TestDartAuthorizationFixture$",
                 "-count=1", "-timeout=55s", "-v"],
                cwd=root / "bff", env=environment, stdout=output,
                stderr=subprocess.STDOUT, start_new_session=True,
            )
            probe = None
            try:
                while not ready.exists():
                    if server.poll() is not None:
                        raise RuntimeError("Go authorization fixture exited before readiness")
                    _remaining(deadline, reserve=5)
                    time.sleep(0.05)
                if stat.S_IMODE(ready.stat().st_mode) != 0o600:
                    raise RuntimeError("Disposable token file must have mode 0600")
                fixture = json.loads(ready.read_text())
                endpoint = urlsplit(fixture["url"])
                if endpoint.scheme != "https" or endpoint.hostname not in {"127.0.0.1", "::1", "localhost"}:
                    raise RuntimeError("Authorization fixture must use loopback HTTPS")
                if Path(fixture["certificate"]).parent != directory:
                    raise RuntimeError("Fixture certificate escaped its private temporary folder")
                probe = subprocess.Popen(
                    [os.environ.get("DART_BIN", "dart"), "run",
                     "tool/authorization_probe.dart", str(ready)],
                    cwd=root / "packages/cosmos_sync", start_new_session=True,
                )
                if probe.wait(timeout=_remaining(deadline, reserve=5)) != 0:
                    raise RuntimeError("Dart authorization probe failed")
                stop.touch(mode=0o600)
                if server.wait(timeout=_remaining(deadline, reserve=2)) != 0:
                    raise RuntimeError("Go authorization fixture failed")
            finally:
                stop.touch(mode=0o600)
                if probe is not None:
                    _stop_group(probe)
                _stop_group(server)
                output.seek(0)
                print(output.read(), end="")


if __name__ == "__main__":
    main()
