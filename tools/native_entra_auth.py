#!/usr/bin/env python3
"""Owner-assisted actual AppAuth validation, with private API-JWT proof files.

The native test uses the real provider and native secure storage. API-only mode
changes no server state. Explicit directory-proof mode permits one approved
retained registration; it changes no Entra configuration or core auth.
"""
import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import subprocess
import threading
import time

from flutter_app_smoke import (
    AndroidReverse, android_target, stop_owned_process, write_android_evidence,
)

STAGES = frozenset({"browser_request_started", "native_callback_received",
                    "secure_restore_complete", "refresh_complete", "local_signout_complete"})
MANUAL_STAGES = frozenset({"owner_start_ready"})
FRESH_STAGES = frozenset({"directory_challenge_received", "fresh_browser_request_started",
                         "fresh_callback_received", "fresh_proof_verified"})
PHASES = frozenset({"initial", "refresh"})
GUID = re.compile(r"^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")
DEFAULT_TIMEOUT_SECONDS = 600
MIN_TIMEOUT_SECONDS = 60
MAX_TIMEOUT_SECONDS = 900


def private_json(path, value):
    data = json.dumps(value, indent=2).encode()
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def replace_private_json(path, value):
    temporary = path.parent / (".native-" + secrets.token_hex(12) + ".tmp")
    try:
        private_json(temporary, value)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def begin_native_run(root, device):
    run_parent = root / ".cache/entra-live-native"
    run_parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = run_parent.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        raise ValueError("private_run_directory_required")
    run_parent.chmod(0o700)
    directory = run_parent / secrets.token_hex(12)
    directory.mkdir(mode=0o700)
    started_at = datetime.now(timezone.utc).isoformat()
    report = {
        "schemaVersion": 2, "status": "incomplete", "failureStage": "argument_preflight",
        "recordedAtUtc": started_at, "startedAtUtc": started_at, "finishedAtUtc": None,
        "failureReason": None, "platform": ("macos" if device == "macos"
                                          else "android" if device in ("android", "android-emulator")
                                          else "unsupported"),
        "physicalDevice": device == "android", "emulator": device == "android-emulator",
        "stages": [], "stageRecordedAtUtc": {}, "capturedApiPhases": [], "cleanupComplete": False,
        "actualNativeAppAuth": False, "actualSecureRestore": False, "actualRefresh": False,
        "localSignout": False, "verifiedApiSignatureIssuerAudienceScopeTenantOwner": False,
        "apiSubjectStableAcrossRefresh": False, "proposedSingleUserGrant": False,
        "processRestartVerified": False, "cosmosConnectionVerified": False,
        "freshIdentityProofVerified": False, "grantsApplied": False,
        "sourceSha": None, "sourceTreeDirty": None,
    }
    private_json(directory / "proof.json", report)
    replace_private_json(run_parent / "latest.local.json", {"runDirectory": str(directory), "storeKey": None})
    return directory, report


def private_input(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.geteuid():
        raise ValueError("private_input_rejected")
    if info.st_size > 65536:
        raise ValueError("private_input_rejected")
    return json.loads(path.read_text())


def approved_registration(directory):
    receipt_path = directory / "registration-receipt.local.json"
    owner_path = directory / "approved-owner.local.json"
    receipt = private_input(receipt_path)
    owner = private_input(owner_path)
    if not isinstance(receipt, dict) or not isinstance(owner, dict):
        raise ValueError("approved_registration_configuration_required")
    tenant = owner.get("tenantId")
    owner_id = owner.get("ownerObjectId")
    if not all(isinstance(value, str) and GUID.fullmatch(value) for value in (tenant, owner_id)):
        raise ValueError("approved_registration_configuration_required")
    if (receipt.get("configurationVerified") is not True or
            receipt.get("nativeCallbackConfigured") is not True or
            receipt.get("tenantId") != tenant or receipt.get("ownerObjectId") != owner_id):
        raise ValueError("approved_registration_configuration_required")
    config = receipt.get("nativeConfig")
    oidc = receipt.get("oidc")
    api = receipt.get("api")
    native = receipt.get("native")
    if not all(isinstance(value, dict) for value in (config, oidc, api, native)):
        raise ValueError("approved_registration_configuration_required")
    api_id, native_id = api.get("appId"), native.get("appId")
    if not all(isinstance(value, str) and GUID.fullmatch(value) for value in (api_id, native_id)) or api_id == native_id:
        raise ValueError("approved_registration_configuration_required")
    tenant = tenant.lower()
    issuers = {
        "https://login.microsoftonline.com/" + tenant + "/v2.0",
        "https://" + tenant + ".ciamlogin.com/" + tenant + "/v2.0",
    }
    issuer = oidc.get("issuer")
    if (issuer not in issuers or config.get("issuer") != issuer or
            config.get("clientId") != native_id or oidc.get("audience") != api_id or
            oidc.get("tenantClaim") != "tid" or oidc.get("requiredScope") != "Cosmos.Sync" or
            oidc.get("tokenUse", "") != "" or
            oidc.get("allowedClientIds", []) not in ([], [native_id])):
        raise ValueError("approved_registration_configuration_required")
    if config.get("redirectUrl") != "com.anaregdesign.cosmossync://auth/oauthredirect":
        raise ValueError("approved_callback_required")
    scopes = config.get("scopes")
    if (not isinstance(scopes, list) or any(not isinstance(scope, str) for scope in scopes) or
            len(set(scopes)) != len(scopes) or
            set(scopes) != {"openid", "profile", "offline_access", "api://" + api_id + "/Cosmos.Sync"} or
            config.get("discoveryUrl") not in (None, issuer + "/.well-known/openid-configuration")):
        raise ValueError("approved_registration_configuration_required")
    return receipt_path, owner_path, config


def registration_directory(root, selected):
    return (selected if selected is not None else root / ".cache/entra-azure").absolute()


def source_state(root):
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True, timeout=10)
    dirty = subprocess.run(["git", "status", "--porcelain"], cwd=root, capture_output=True, text=True, timeout=10)
    if revision.returncode != 0 or dirty.returncode != 0 or re.fullmatch(r"[0-9a-f]{40}", revision.stdout.strip()) is None:
        raise ValueError("native_source_attribution_failed")
    return {"sourceSha": revision.stdout.strip(), "sourceTreeDirty": bool(dirty.stdout.strip())}


def native_command(flutter, target, url, isolated_sign_in=False, manual_start=False,
                   *, timeout=DEFAULT_TIMEOUT_SECONDS):
    if type(timeout) is not int or not MIN_TIMEOUT_SECONDS <= timeout <= MAX_TIMEOUT_SECONDS:
        raise ValueError("bounded_native_auth_timeout_required")
    command = [
        flutter, "test", "integration_test/entra_auth_live_test.dart", "-d", target,
        "--dart-define=COSMOS_SYNC_ENTRA_CONTROL_URL=" + url, "--reporter", "expanded",
        "--dart-define=COSMOS_SYNC_ENTRA_TIMEOUT_SECONDS=" + str(timeout),
    ]
    if isolated_sign_in:
        command.append("--dart-define=COSMOS_SYNC_ENTRA_ISOLATED_SIGN_IN=true")
    if manual_start:
        command.append("--dart-define=COSMOS_SYNC_ENTRA_MANUAL_START=true")
    return command


def expected_stages(manual_start=False, directory_proof=False):
    return STAGES | (MANUAL_STAGES if manual_start else frozenset()) | (FRESH_STAGES if directory_proof else frozenset())


class NativeControl:
    def __init__(self, directory, native_config, *, proof_session=None):
        self.directory = directory
        self.config = dict(native_config)
        self.proof_session = proof_session
        self.capability = secrets.token_urlsafe(32)
        self.prefix = "/" + self.capability + "/"
        self.store_key = "cosmos_sync_example.auth_live." + secrets.token_hex(16)
        self.stages = []
        self.stage_recorded_at = {}
        self.captured = set()
        self.lock = threading.Lock()
        control = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *unused):
                pass

            def setup(self):
                super().setup()
                self.connection.settimeout(2)

            def permitted_peer(self):
                return (self.headers.get("Host") == "127.0.0.1:" + str(control.server.server_port)
                        and self.headers.get("Origin") is None)

            def reply(self, status, value):
                payload = json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_GET(self):
                if not self.permitted_peer() or self.path != control.prefix + "config":
                    self.reply(404, {"error": "invalid_control_path"})
                    return
                self.reply(200, {"protocolVersion": 2 if control.proof_session is not None else 1,
                                 "nativeConfig": control.config, "storeKey": control.store_key,
                                 **({"proofMode": "directory-register-v1"} if control.proof_session is not None else {})})

            def do_POST(self):
                paths = {control.prefix + "stage", control.prefix + "token"}
                if control.proof_session is not None:
                    paths |= {control.prefix + "challenge", control.prefix + "proof"}
                if not self.permitted_peer() or self.path not in paths:
                    self.reply(404, {"error": "invalid_control_path"})
                    return
                try:
                    size = int(self.headers.get("Content-Length", "0"))
                    if size <= 0 or size > 80 * 1024:
                        raise ValueError()
                    value = json.loads(self.rfile.read(size))
                    if not isinstance(value, dict):
                        raise ValueError()
                    if self.path.endswith("/challenge") or self.path.endswith("/proof"):
                        with control.lock:
                            if self.path.endswith("/challenge"):
                                if value != {}:
                                    raise ValueError()
                                result = control.proof_session.challenge()
                            else:
                                result = control.proof_session.accept(value)
                        self.reply(200, result)
                        return
                    if self.path.endswith("/stage"):
                        if set(value) != {"stage"} or value["stage"] not in (
                                STAGES | MANUAL_STAGES | (FRESH_STAGES if control.proof_session is not None else frozenset())):
                            raise ValueError()
                        with control.lock:
                            if value["stage"] not in control.stages:
                                control.stages.append(value["stage"])
                                control.stage_recorded_at[value["stage"]] = datetime.now(timezone.utc).isoformat()
                                print("NATIVE_ENTRA_STAGE_" + value["stage"].upper(), flush=True)
                    else:
                        if set(value) != {"phase", "accessToken"} or value["phase"] not in PHASES:
                            raise ValueError()
                        token = value["accessToken"]
                        if not isinstance(token, str) or not 8 <= len(token) <= 65536 or token.count(".") != 2 or any(c.isspace() for c in token):
                            raise ValueError()
                        with control.lock:
                            if value["phase"] in control.captured:
                                self.reply(409, {"error": "phase_already_captured"})
                                return
                            path = control.directory / (value["phase"] + ".jwt")
                            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
                            fd = os.open(path, flags, 0o600)
                            with os.fdopen(fd, "w") as stream:
                                stream.write(token)
                                stream.flush()
                                os.fsync(stream.fileno())
                            if value["phase"] == "initial" and control.proof_session is not None:
                                control.proof_session.verify_initial(path)
                            control.captured.add(value["phase"])
                            print("NATIVE_ENTRA_API_TOKEN_CAPTURED_" + value["phase"].upper(), flush=True)
                    self.reply(200, {})
                except Exception:
                    # Never reflect request bodies, credentials, paths or errors.
                    self.reply(400, {"error": "invalid_control_request"})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = False
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self):
        return "http://127.0.0.1:" + str(self.server.server_port) + self.prefix

    def start(self):
        self.thread.start()

    def close(self):
        if self.proof_session is not None:
            self.proof_session.close()
        if self.thread.is_alive():
            self.server.shutdown()
        self.server.server_close()
        if self.thread.ident is not None:
            self.thread.join(timeout=5)


def native_target(arguments):
    if arguments.device in ("android", "android-emulator"):
        return android_target(
            arguments, arguments.flutter_bin, emulator=arguments.device == "android-emulator",
        )[0]
    if arguments.device != "macos":
        raise ValueError("unsupported_native_auth_target")
    if arguments.device_id_file or arguments.authorize_install:
        raise ValueError("android_options_require_android_target")
    return "macos"


def successful_native_evidence(device):
    if device not in ("macos", "android", "android-emulator"):
        raise ValueError("unsupported_native_auth_target")
    return {
        "platform": "macos" if device == "macos" else "android",
        "physicalDevice": device == "android", "emulator": device == "android-emulator",
        "actualNativeAppAuth": True, "actualSecureRestore": True, "actualRefresh": True,
        "localSignout": True, "verifiedApiSignatureIssuerAudienceScopeTenantOwner": True,
        "apiSubjectStableAcrossRefresh": True, "proposedSingleUserGrant": True,
        "grantsApplied": False, "processRestartVerified": False,
        "multiPrincipalRealProviderVerified": False, "cosmosConnectionVerified": False,
    }


def cleanup_native_run(process, control, reverse):
    try:
        stop_owned_process(process)
    finally:
        try:
            if control is not None:
                control.close()
        finally:
            if reverse is not None and not reverse.close():
                raise RuntimeError("owned_android_reverse_cleanup_failed")


def interrupt_native_run(unused_signal, unused_frame):
    raise InterruptedError("native_auth_interrupted")


def run_native(args, root):
    directory, report = begin_native_run(root, args.device)
    control = None
    proof_session = None
    flutter_process = None
    reverse = None
    stage = "argument_preflight"
    output_permitted = False
    try:
        if type(args.timeout) is not int or not MIN_TIMEOUT_SECONDS <= args.timeout <= MAX_TIMEOUT_SECONDS:
            raise ValueError("bounded_native_auth_timeout_required")
        if args.device == "macos" and args.output:
            raise ValueError("android_evidence_output_requires_android_target")
        if args.output:
            if not Path(args.output).resolve().is_relative_to(root / "artifacts"):
                raise ValueError("private_evidence_destination_required")
            output_permitted = True
        stage = "target_preflight"
        target = native_target(args)
        stage = "registration_preflight"
        input_directory = registration_directory(root, args.input_dir)
        receipt_path, owner_path, config = approved_registration(input_directory)
        stage = "source_preflight"
        report.update(source_state(root))
        stage = "registration_preflight"
        if getattr(args, "directory_manifest", None) is not None:
            stage = "directory_manifest_preflight"
            if not args.manual_start:
                raise ValueError("directory_proof_requires_foreground_owner_start")
            from directory_proof_control import DirectoryProofSession, validate_manifest
            manifest = validate_manifest(private_input(args.directory_manifest))
            stage = "source_preflight"
            if report["sourceTreeDirty"] or report["sourceSha"] != manifest["hosting"]["sourceCommit"]:
                raise ValueError("exact_clean_native_candidate_required")
            stage = "directory_configuration_and_hosting_preflight"
            runtime_config = private_input(Path(manifest["runtimeConfigFile"]))
            proof_session = DirectoryProofSession(
                manifest, config, directory, receipt_path, owner_path, runtime_config, root, args.go_bin)
        stage = "control_start"
        control = (NativeControl(directory, config) if proof_session is None
                   else NativeControl(directory, config, proof_session=proof_session))
        control.start()
        reverse = AndroidReverse(target) if args.device in ("android", "android-emulator") else None
        private_json(directory / "run.local.json", {"controlUrl": control.url, "storeKey": control.store_key})
        if reverse is not None:
            reverse.add(control.server.server_port)
        log_fd = os.open(directory / "flutter-private.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        stage = "native_run"
        print("NATIVE_ENTRA_OWNER_ASSISTED_RUN_STARTED", flush=True)
        with os.fdopen(log_fd, "w") as output:
            command = native_command(args.flutter_bin, target, control.url, args.isolated_sign_in,
                                     args.manual_start, timeout=args.timeout)
            flutter_process = subprocess.Popen(command, cwd=root / "examples/flutter_app", stdout=output,
                                               stderr=subprocess.STDOUT, start_new_session=os.name == "posix")
            deadline = time.monotonic() + args.timeout
            pending_since = None
            owner_notice = False
            while flutter_process.poll() is None:
                if time.monotonic() > deadline:
                    raise TimeoutError("native_auth_timeout")
                with control.lock:
                    waiting = "browser_request_started" in control.stages and "native_callback_received" not in control.stages
                if waiting:
                    pending_since = pending_since or time.monotonic()
                    if not owner_notice and time.monotonic() - pending_since >= 10:
                        # Pending AppAuth call, not a screenshot/browser inspection.
                        print("NATIVE_ENTRA_OWNER_ACTION_PENDING", flush=True)
                        owner_notice = True
                time.sleep(0.2)
            if flutter_process.returncode != 0:
                raise RuntimeError("native_auth_target_failed")
        if control.captured != PHASES or set(control.stages) != expected_stages(args.manual_start, proof_session is not None):
            raise RuntimeError("native_auth_evidence_incomplete")
        stage = "api_verification"
        env = dict(os.environ)
        env.setdefault("GOCACHE", str(root / ".cache/go-build"))
        for phase in ("initial", "refresh"):
            proof_directory = directory / (phase + "-proof")
            proof_directory.mkdir(mode=0o700)
            command = [args.go_bin, "run", "./cmd/verify-entra-principal", "--owner-file", str(owner_path),
                       "--receipt-file", str(receipt_path), "--token-file", str(directory / (phase + ".jwt")),
                       "--output-dir", str(proof_directory), "--permission-version", "native-entra-live-v1"]
            result = subprocess.run(command, cwd=root / "bff", env=env, capture_output=True, text=True, timeout=60)
            if result.returncode != 0:
                raise RuntimeError("api_jwt_proof_failed")
            value = json.loads(result.stdout)
            if not value.get("subjectFromApiToken") or value.get("grantsApplied"):
                raise RuntimeError("api_jwt_proof_failed")
            print("NATIVE_ENTRA_VERIFIED_API_PROOF_" + phase.upper(), flush=True)
        before = private_input(directory / "initial-proof/identity.local.json")
        after = private_input(directory / "refresh-proof/identity.local.json")
        stage = "principal_correlation"
        if any(before[key] != after[key] for key in ("tenantId", "ownerObjectId", "subject")):
            raise RuntimeError("refresh_principal_changed")
        if proof_session is not None:
            if not proof_session.registration_verified:
                raise RuntimeError("directory_proof_evidence_incomplete")
            report.update(proof_session.evidence())
        report.update(successful_native_evidence(args.device))
        report.update({"status": "passed", "failureStage": None, "failureReason": None})
        report["completedAtUtc"] = datetime.now(timezone.utc).isoformat()
        report["isolatedInteractiveSessionRequested"] = args.isolated_sign_in
        report["ownerInitiatedForegroundSignIn"] = args.manual_start
    except (Exception, KeyboardInterrupt) as error:
        reason = ("interrupted" if isinstance(error, (InterruptedError, KeyboardInterrupt))
                  else "timeout" if isinstance(error, (TimeoutError, subprocess.TimeoutExpired))
                  else "stage_failed")
        report.update({"status": "failed", "failureStage": stage, "failureReason": reason})
        raise
    finally:
        try:
            cleanup_native_run(flutter_process, control, reverse)
            report["cleanupComplete"] = True
        except (Exception, KeyboardInterrupt):
            report.update({"status": "failed", "failureStage": "cleanup", "failureReason": "cleanup_failed"})
            raise
        finally:
            if control is not None:
                report.update({"stages": list(control.stages),
                               "stageRecordedAtUtc": dict(control.stage_recorded_at),
                               "capturedApiPhases": sorted(control.captured)})
            if proof_session is not None:
                report.update(proof_session.evidence())
                proof_session.close()
            report["finishedAtUtc"] = datetime.now(timezone.utc).isoformat()
            replace_private_json(directory / "proof.json", report)
            if output_permitted:
                write_android_evidence(args.output, report)
    print(json.dumps(report), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owner-assisted", action="store_true", required=True)
    parser.add_argument("--device", choices=("macos", "android", "android-emulator"), default="macos")
    parser.add_argument("--device-id-file")
    parser.add_argument("--authorize-install", action="store_true")
    parser.add_argument("--input-dir", type=Path,
                        help="Explicit private approved receipt/owner directory; default retains workforce setup")
    parser.add_argument("--directory-manifest", type=Path,
                        help="Separately approved private directory registration/write budget; enables fresh API/ID proof without persistent proof tokens")
    parser.add_argument("--isolated-sign-in", action="store_true",
                        help="Request prompt=login and supported Apple ephemeral browser, not token/account authority")
    parser.add_argument("--manual-start", action="store_true",
                        help="Wait for the owner to tap Start while the selected app is foreground/resumed")
    parser.add_argument("--output")
    parser.add_argument("--flutter-bin", default=os.environ.get("FLUTTER_BIN", "flutter"))
    parser.add_argument("--go-bin", default=os.environ.get("GO_BIN", "go"))
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_SECONDS,
                        help="Bounded native run/test timeout in seconds (60-900; default 600)")
    run_native(parser.parse_args(), Path(__file__).resolve().parents[1])


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupt_native_run)
    try:
        main()
    except (Exception, KeyboardInterrupt):
        # Private logs are for local inspection; no provider/filesystem message
        # can leak tokens, account names, authorization codes or callback URLs.
        print("NATIVE_ENTRA_RUN_FAILED_CHECK_PRIVATE_EVIDENCE", flush=True)
        raise SystemExit(1)
