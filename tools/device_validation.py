#!/usr/bin/env python3
"""Redacted inventory and an explicitly authorized physical SDK fixture run.

Inventory never pairs, installs, signs, launches, changes connectivity, or selects
a target. A run requires a local ignored identity file and an install grant.
Raw device discovery and Flutter output are neither printed nor persisted.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
SDK_PROJECT = REPO / "examples" / "flutter_smoke"
SAFE_MODEL = re.compile(r"^[A-Za-z0-9 ._()+,-]{1,100}$")


class ValidationError(Exception):
    """An operator-safe error without raw device or credential details."""


def invoke(command: list[str], *, cwd: Path = REPO, timeout: int = 30):
    try:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            errors="replace",
            start_new_session=os.name == "posix",
        )
    except OSError as error:
        raise ValidationError("Tool unavailable or command timed out.") from error
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        # Stop only this invocation's process group, never unrelated devices/tools.
        try:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGTERM)
            else:
                process.terminate()
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            process.communicate()
        except ProcessLookupError:
            process.communicate()
        raise ValidationError("Command interrupted or timed out; its local process group was stopped.") from error


def safe_model(value):
    # Personal device names, hostnames, serials, UUIDs and raw errors are omitted.
    return value if isinstance(value, str) and SAFE_MODEL.fullmatch(value) else "unknown"


def parse_android_inventory(output: str) -> list[dict]:
    devices = []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 2 or line.startswith("List of devices") or fields[0] == "*":
            continue
        properties = dict(field.split(":", 1) for field in fields[2:] if ":" in field)
        devices.append(
            {
                "platform": "android",
                "physical": not fields[0].startswith("emulator-"),
                "model": safe_model(properties.get("model")),
                "connection_state": fields[1] if fields[1] in {
                    "device", "unauthorized", "offline", "recovery", "sideload", "bootloader"
                } else "unknown",
            }
        )
    return devices


def parse_apple_inventory(data: dict) -> list[dict]:
    devices = []
    for item in data.get("result", {}).get("devices", []):
        properties = item.get("properties", {})
        hardware = properties.get("hardware", item.get("hardwareProperties", {}))
        connection = properties.get("connection", item.get("connectionProperties", {}))
        legacy_connection = item.get("connectionProperties", {})
        state = properties.get("state", {})
        legacy_device = item.get("deviceProperties", {})
        visibility = state.get("visibilityClass", item.get("visibilityClass"))
        device_type = hardware.get("deviceType")
        platform = hardware.get("platform")
        physical = visibility is not None and visibility != "simulators" and platform == "iOS" and device_type in {
            "iPhone", "iPad", "iPod"
        }
        devices.append(
            {
                "platform": "ios" if platform == "iOS" else "other",
                "physical": physical,
                "model": safe_model(hardware.get("marketingName", hardware.get("productType"))),
                "os_version": safe_model(legacy_device.get("osVersionNumber")),
                "connection_state": safe_model(legacy_connection.get("tunnelState", "unknown")),
                "pairing_state": safe_model(connection.get("pairingState", "unknown")),
                "developer_mode": safe_model(legacy_device.get("developerModeStatus", "unknown")),
            }
        )
    return devices


def inventory():
    report = {"android": {"status": "unavailable"}, "apple": {"status": "unavailable"}}
    for name, command, parser in (
        ("android", ["adb", "devices", "-l"], parse_android_inventory),
        ("apple", ["xcrun", "devicectl", "list", "devices", "--timeout", "20", "--json-output", "-"],
         lambda output: parse_apple_inventory(json.loads(output))),
    ):
        if not shutil.which(command[0]):
            continue
        try:
            result = invoke(command, timeout=25)
            if result.returncode != 0:
                report[name] = {"status": "discovery_failed"}
                continue
            report[name] = {"status": "ok", "devices": parser(result.stdout)}
        except (ValidationError, ValueError, TypeError, AttributeError):
            report[name] = {"status": "discovery_failed"}
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if all(section["status"] == "ok" for section in report.values()) else 2


def selected_identity(path: str) -> str:
    identity_path = Path(path).resolve()
    if not identity_path.is_relative_to(REPO / ".cache"):
        raise ValidationError("Device identity must be stored in the ignored repository .cache directory.")
    try:
        identity = identity_path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError) as error:
        raise ValidationError("Cannot read the private device identity file.") from error
    if not identity or len(identity) > 200 or any(character.isspace() for character in identity):
        raise ValidationError("Invalid private device identity file.")
    return identity


def select_physical_device(data: list, identity: str, platform: str) -> dict:
    matches = [item for item in data if isinstance(item, dict) and item.get("id") == identity]
    if len(matches) != 1:
        raise ValidationError("The explicitly selected device is not uniquely available to Flutter.")
    device = matches[0]
    target = device.get("targetPlatform", "")
    if not isinstance(target, str):
        raise ValidationError("Flutter returned an invalid target platform; no fixture was launched.")
    platform_matches = target == "ios" if platform == "ios" else target.startswith("android-")
    if device.get("emulator") is not False or device.get("isSupported") is not True or not platform_matches:
        raise ValidationError("The selected target is not a supported physical device of the requested platform.")
    return device


def require_ios_team(team: str | None):
    if not team or not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValidationError("iOS requires the owner's explicitly approved Apple development team.")
    # Resolve the actual Runner Debug settings rather than accepting an unrelated
    # literal team in Release, an xcconfig, or an unresolved build variable.
    result = invoke(["xcodebuild", "-project", str(SDK_PROJECT / "ios" / "Runner.xcodeproj"),
                     "-scheme", "Runner", "-configuration", "Debug", "-sdk", "iphoneos",
                     "-showBuildSettings", "-json"],
                    timeout=60)
    if result.returncode != 0:
        raise ValidationError("Cannot resolve Runner Debug signing settings; no fixture was launched.")
    try:
        rows = json.loads(result.stdout)
        if not isinstance(rows, list):
            raise ValueError("Invalid build-settings result.")
        targets = [row for row in rows if isinstance(row, dict) and row.get("target") == "Runner"]
        settings = targets[0].get("buildSettings", {}) if len(targets) == 1 else {}
        sdk_name = settings.get("SDK_NAME", "")
        matches = (settings.get("CONFIGURATION") == "Debug" and settings.get("DEVELOPMENT_TEAM") == team
                   and settings.get("PLATFORM_NAME") == "iphoneos"
                   and isinstance(sdk_name, str) and sdk_name.startswith("iphoneos"))
    except (ValueError, TypeError, AttributeError) as error:
        raise ValidationError("Cannot resolve Runner Debug signing settings; no fixture was launched.") from error
    if not matches:
        raise ValidationError("Runner Debug must resolve to exactly the approved development team before running.")


def write_evidence(output: str, evidence: dict):
    destination = Path(output).resolve()
    if not destination.is_relative_to(REPO / "artifacts"):
        raise ValidationError("Evidence must be written in the ignored repository artifacts directory.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=destination.parent, delete=False, encoding="utf-8") as handle:
        temporary = Path(handle.name)
        json.dump(evidence, handle, indent=2, sort_keys=True)
        handle.write("\n")
    try:
        os.chmod(temporary, 0o600)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def run_fixture(arguments):
    if not arguments.authorize_install:
        raise ValidationError("Stop: the owner must identify the physical target and authorize app installation and launch.")
    if arguments.platform == "ios" and not arguments.authorize_apple_provisioning:
        raise ValidationError("Stop: Flutter iOS signing can create/update Apple profiles, app IDs and certificates and register this device. Explicit owner authorization is required.")
    identity = selected_identity(arguments.device_id_file)
    # Validate destination before any device mutation.
    destination = Path(arguments.output).resolve()
    if not destination.is_relative_to(REPO / "artifacts"):
        raise ValidationError("Evidence must be written in the ignored repository artifacts directory.")
    if arguments.platform == "ios":
        require_ios_team(arguments.signing_team)
    result = invoke(["flutter", "devices", "--machine"], timeout=45)
    if result.returncode != 0:
        raise ValidationError("Flutter device discovery failed; no fixture was launched.")
    try:
        device = select_physical_device(json.loads(result.stdout), identity, arguments.platform)
    except (ValueError, TypeError) as error:
        raise ValidationError("Flutter device discovery returned invalid data; no fixture was launched.") from error
    version_result = invoke(["flutter", "--version", "--machine"], timeout=30)
    try:
        version = json.loads(version_result.stdout) if version_result.returncode == 0 else {}
    except ValueError:
        version = {}
    commit_result = invoke(["git", "rev-parse", "HEAD"])
    commit = commit_result.stdout.strip() if commit_result.returncode == 0 else "unknown"
    status_result = invoke(["git", "status", "--porcelain", "--untracked-files=normal"])
    source_dirty = bool(status_result.stdout.strip()) if status_result.returncode == 0 else None
    command = ["flutter", "test", "--no-pub", "integration_test/offline_sync_test.dart", "-d", identity]
    fixture = invoke(command, cwd=SDK_PROJECT, timeout=arguments.timeout_seconds)
    expected_marker = f"COSMOS_SYNC_NATIVE_PASS {arguments.platform}"
    passed = fixture.returncode == 0 and expected_marker in fixture.stdout + fixture.stderr
    evidence = {
        "schema_version": 1,
        "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "commit": commit if re.fullmatch(r"[0-9a-f]{40}", commit) else "unknown",
        "source_tree_dirty": source_dirty,
        "platform": arguments.platform,
        "physical_device": True,
        "device_runtime": safe_model(device.get("sdk", "unknown")),
        "flutter_version": safe_model(version.get("frameworkVersion")),
        "dart_version": safe_model(version.get("dartSdkVersion")),
        "suite": "sdk_native_deterministic_transport",
        "storage": "real_app_private_sqlite",
        "mode": "debug",
        "live_bff": False,
        "live_oidc": False,
        "live_azure": False,
        "passed": passed,
        "expected_runtime_marker_seen": expected_marker in fixture.stdout + fixture.stderr,
        "exit_code": fixture.returncode,
        "raw_output_retained": False,
        "device_identity_retained": False,
        "apple_provisioning_authorized": arguments.platform == "ios",
    }
    write_evidence(arguments.output, evidence)
    print(json.dumps(evidence, indent=2, sort_keys=True))
    return 0 if passed else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("inventory", help="Read-only inventory with identifiers and device names omitted.")
    run = subcommands.add_parser("run-sdk", help="Install and run only the native SDK fixture on an approved physical target.")
    run.add_argument("--platform", choices=("android", "ios"), required=True)
    run.add_argument("--device-id-file", required=True)
    run.add_argument("--authorize-install", action="store_true")
    run.add_argument("--authorize-apple-provisioning", action="store_true",
                     help="iOS only: owner explicitly permits Apple's profile/app-ID/certificate updates and selected-device registration.")
    run.add_argument("--signing-team", help="Owner-approved existing Apple development team; iOS only.")
    run.add_argument("--output", required=True)
    run.add_argument("--timeout-seconds", type=int, default=1200)
    arguments = parser.parse_args()
    try:
        if arguments.command == "inventory":
            return inventory()
        if not 60 <= arguments.timeout_seconds <= 3600:
            raise ValidationError("Fixture timeout must be between 60 and 3600 seconds.")
        return run_fixture(arguments)
    except ValidationError as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
