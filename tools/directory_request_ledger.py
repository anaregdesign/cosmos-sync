"""A private, process-locked aggregate BFF request budget, never an RU meter."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat

from live_azure_preflight import GateError, account_https_origin, require
from native_entra_auth import private_json


def endpoint_digest(endpoint):
    return hashlib.sha256(json.dumps(
        account_https_origin(endpoint), separators=(",", ":")).encode()).hexdigest()


class DirectoryRequestLedger:
    def __init__(self, path, endpoint):
        self.path = Path(path)
        require(self.path.is_absolute(), "aggregate request ledger must have an absolute private path")
        self.endpoint_hash = endpoint_digest(endpoint)
        self.read()

    def _access(self, reserve):
        try:
            fd = os.open(self.path, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | os.O_NONBLOCK)
            with os.fdopen(fd, "r+", encoding="utf-8") as stream:
                info = os.fstat(stream.fileno())
                require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()
                        and stat.S_IMODE(info.st_mode) == 0o600, "aggregate ledger must be current-owner and private")
                fcntl.flock(stream, fcntl.LOCK_EX)
                data = stream.read(4097)
                require(len(data) <= 4096, "aggregate request ledger exceeds its bound")
                value = json.loads(data)
                require(isinstance(value, dict)
                        and set(value) == {"schemaVersion", "endpointSha256", "maxProtocolRequests", "protocolRequests"}
                        and type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
                        and value["endpointSha256"] == self.endpoint_hash
                        and type(value["maxProtocolRequests"]) is int and value["maxProtocolRequests"] == 40
                        and type(value["protocolRequests"]) is int
                        and 0 <= value["protocolRequests"] <= value["maxProtocolRequests"],
                        "aggregate ledger does not match the exact approved target and cap")
                current = self.path.stat(follow_symlinks=False)
                require((current.st_dev, current.st_ino) == (info.st_dev, info.st_ino),
                        "aggregate ledger changed during budget reservation")
                if reserve:
                    require(value["protocolRequests"] < value["maxProtocolRequests"], "aggregate request budget exhausted")
                    value["protocolRequests"] += 1
                    stream.seek(0)
                    json.dump(value, stream, separators=(",", ":"))
                    stream.truncate()
                    stream.flush()
                    os.fsync(stream.fileno())
                return value
        except (OSError, ValueError, UnicodeError, TypeError):
            raise GateError("aggregate request ledger rejected") from None

    def reserve(self):
        return self._access(True)

    def read(self):
        return self._access(False)


def initialize(path, endpoint, observed_prior_attempts):
    require(type(observed_prior_attempts) is int and 0 <= observed_prior_attempts <= 40,
            "explicit measured prior attempts required")
    private_json(path, {"schemaVersion": 1, "endpointSha256": endpoint_digest(endpoint),
                        "maxProtocolRequests": 40, "protocolRequests": observed_prior_attempts})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, required=True)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--initialize-offline", action="store_true")
    parser.add_argument("--observed-prior-attempts", type=int)
    args = parser.parse_args()
    if args.initialize_offline:
        initialize(args.ledger, args.endpoint, args.observed_prior_attempts)
    else:
        require(args.observed_prior_attempts is None, "initialization must be explicit")
    print(json.dumps(DirectoryRequestLedger(args.ledger.absolute(), args.endpoint).read()))


if __name__ == "__main__":
    try:
        main()
    except (GateError, OSError):
        raise SystemExit("Private aggregate ledger rejected; no target request was made.")
