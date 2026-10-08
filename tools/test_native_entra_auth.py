import argparse
import contextlib
from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
import urllib.error
import urllib.request
from unittest.mock import Mock, patch

from device_validation import ValidationError
import native_entra_auth as native
from native_entra_auth import NativeControl, native_target, private_input, private_json


class NativeEntraControlTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.control = NativeControl(self.directory, {
            "issuer": "https://login.microsoftonline.com/example/v2.0",
            "clientId": "public-client", "redirectUrl": "com.example.app://auth/callback",
            "scopes": ["openid", "offline_access", "api://example/Cosmos.Sync"],
        })
        self.output = io.StringIO()
        self.redirect = contextlib.redirect_stdout(self.output)
        self.redirect.__enter__()
        self.control.start()

    def tearDown(self):
        self.control.close()
        self.redirect.__exit__(None, None, None)
        self.temporary.cleanup()

    def request(self, path, value=None):
        body = None if value is None else json.dumps(value).encode()
        request = urllib.request.Request(path, data=body, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                return response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:
            with error:
                return error.code, error.headers, error.read()

    def test_wrong_capability_and_token_get_reveal_nothing(self):
        for path in (self.control.url.replace(self.control.capability, "wrong") + "config",
                     self.control.url + "token", self.control.url + "config?extra=1"):
            status, _, body = self.request(path)
            self.assertEqual(status, 404)
            self.assertNotIn(b"public-client", body)

    def test_configuration_contains_no_token_or_owner_information(self):
        status, headers, body = self.request(self.control.url + "config")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        value = json.loads(body)
        self.assertEqual(value["protocolVersion"], 1)
        self.assertTrue(value["storeKey"].startswith("cosmos_sync_example.auth_live."))
        self.assertNotIn("accessToken", value)
        self.assertNotIn("ownerObjectId", value)

    def test_api_token_capture_is_private_exclusive_and_never_reflected(self):
        sentinel = "HEADER.SECRET_API_TOKEN.SIGNATURE"
        status, headers, body = self.request(self.control.url + "token", {"phase": "initial", "accessToken": sentinel})
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertNotIn(sentinel.encode(), body)
        path = self.directory / "initial.jwt"
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(path.read_text(), sentinel)
        status, _, body = self.request(self.control.url + "token", {"phase": "initial", "accessToken": "NEW.VALUE.SIGNATURE"})
        self.assertEqual(status, 409)
        self.assertEqual(path.read_text(), sentinel)
        self.assertNotIn(sentinel, self.output.getvalue())
        self.assertNotIn(sentinel.encode(), body)

    def test_unapproved_fields_and_phases_are_rejected_without_reflection(self):
        sentinel = "TOKEN_MUST_NOT_LEAK"
        for value in ({"phase": "../../escape", "accessToken": sentinel},
                      {"phase": "initial", "accessToken": "A.B.C", "refreshToken": sentinel},
                      {"phase": "initial", "accessToken": "Bearer A.B.C"}):
            status, _, body = self.request(self.control.url + "token", value)
            self.assertEqual(status, 400)
            self.assertNotIn(sentinel.encode(), body)
        self.assertEqual(self.control.captured, set())
        self.assertNotIn(sentinel, self.output.getvalue())

    def test_arbitrary_stage_is_never_logged(self):
        sentinel = "AUTH_CODE_MUST_NOT_LEAK"
        status, _, body = self.request(self.control.url + "stage", {"stage": sentinel})
        self.assertEqual(status, 400)
        self.assertNotIn(sentinel.encode(), body)
        self.assertNotIn(sentinel, self.output.getvalue())
        status, _, _ = self.request(self.control.url + "stage", {"stage": "browser_request_started"})
        self.assertEqual(status, 200)
        self.assertEqual(self.control.stages, ["browser_request_started"])

    def test_manual_readiness_stage_is_fixed_and_does_not_capture_a_token(self):
        status, _, body = self.request(self.control.url + "stage", {"stage": "owner_start_ready"})
        self.assertEqual(status, 200)
        self.assertEqual(self.control.stages, ["owner_start_ready"])
        self.assertEqual(self.control.captured, set())
        self.assertEqual(json.loads(body), {})
        self.assertIn("NATIVE_ENTRA_STAGE_OWNER_START_READY", self.output.getvalue())

    def test_stage_timestamp_is_first_observation_not_duplicate_request_time(self):
        observed = datetime(2030, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
        with patch.object(native, "datetime") as clock:
            clock.now.return_value = observed
            for _ in range(2):
                status, _, _ = self.request(
                    self.control.url + "stage", {"stage": "browser_request_started"})
                self.assertEqual(status, 200)
            clock.now.assert_called_once_with(timezone.utc)
        self.assertEqual(self.control.stages, ["browser_request_started"])
        self.assertEqual(self.control.stage_recorded_at,
                         {"browser_request_started": observed.isoformat()})
        self.assertEqual(self.control.captured, set())

    def test_invalid_stage_cannot_record_a_timestamp(self):
        status, _, _ = self.request(self.control.url + "stage", {"stage": "AUTH_CODE_MUST_NOT_LEAK"})
        self.assertEqual(status, 400)
        self.assertEqual(self.control.stage_recorded_at, {})

    def test_symlink_capture_does_not_overwrite_any_target(self):
        target = self.directory / "unrelated"
        target.write_text("unchanged")
        (self.directory / "initial.jwt").symlink_to(target)
        status, _, _ = self.request(self.control.url + "token", {"phase": "initial", "accessToken": "A.B.CCCC"})
        self.assertEqual(status, 400)
        self.assertEqual(target.read_text(), "unchanged")


class PrivateInputTests(unittest.TestCase):
    def test_private_json_is_exclusive_and_input_rejects_public_mode_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "private.json"
            private_json(path, {"ok": True})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(private_input(path), {"ok": True})
            with self.assertRaises(FileExistsError):
                private_json(path, {"ok": False})
            os.chmod(path, 0o644)
            with self.assertRaises(ValueError):
                private_input(path)
            os.chmod(path, 0o600)
            link = root / "link.json"
            link.symlink_to(path)
            with self.assertRaises(ValueError):
                private_input(link)

    def test_atomic_replacement_never_follows_a_destination_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "unrelated"
            target.write_text("unchanged")
            destination = root / "latest.local.json"
            destination.symlink_to(target)
            native.replace_private_json(destination, {"new": True})
            self.assertFalse(destination.is_symlink())
            self.assertEqual(private_input(destination), {"new": True})
            self.assertEqual(target.read_text(), "unchanged")
            self.assertEqual(list(root.glob(".native-*.tmp")), [])


class NativeRunFailureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.args = argparse.Namespace(
            device="macos", output=None, timeout=60, flutter_bin="flutter", go_bin="go",
            input_dir=None, isolated_sign_in=False, manual_start=False,
            device_id_file=None, authorize_install=False,
        )
        source = patch.object(native, "source_state", return_value={"sourceSha": "a" * 40, "sourceTreeDirty": False})
        source.start()
        self.addCleanup(source.stop)

    def tearDown(self):
        self.temporary.cleanup()

    def report(self):
        latest = private_input(self.root / ".cache/entra-live-native/latest.local.json")
        directory = Path(latest["runDirectory"])
        self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        return private_input(directory / "proof.json")

    def test_target_preflight_creates_fresh_redacted_receipt_not_stale_latest(self):
        parent = self.root / ".cache/entra-live-native"
        parent.mkdir(parents=True)
        private_json(parent / "latest.local.json", {"runDirectory": "old_completed_attempt"})
        sentinel = "SECRET_ACCOUNT_OR_DEVICE_MUST_NOT_LEAK"
        with patch.object(native, "native_target", side_effect=ValueError(sentinel)), \
                patch.object(native, "approved_registration") as registration, \
                patch.object(native, "NativeControl") as control:
            with self.assertRaises(ValueError):
                native.run_native(self.args, self.root)
        report = self.report()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["failureStage"], "target_preflight")
        self.assertEqual(report["failureReason"], "stage_failed")
        self.assertTrue(report["cleanupComplete"])
        self.assertFalse(report["actualNativeAppAuth"])
        self.assertFalse(report["verifiedApiSignatureIssuerAudienceScopeTenantOwner"])
        self.assertEqual(report["stages"], [])
        self.assertNotIn(sentinel, json.dumps(report))
        registration.assert_not_called()
        control.assert_not_called()

    def test_registration_preflight_failure_is_attributed_without_starting_auth(self):
        with patch.object(native, "native_target", return_value="macos"), \
                patch.object(native, "approved_registration", side_effect=OSError("PRIVATE_PATH")), \
                patch.object(native, "NativeControl") as control:
            with self.assertRaises(OSError):
                native.run_native(self.args, self.root)
        self.assertEqual(self.report()["failureStage"], "registration_preflight")
        self.assertNotIn("PRIVATE_PATH", json.dumps(self.report()))
        control.assert_not_called()

    def test_failure_records_start_and_finish_separately_after_cleanup(self):
        started = datetime(2030, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
        finished = datetime(2030, 1, 2, 3, 5, 6, tzinfo=timezone.utc)
        with patch.object(native, "datetime") as clock, \
                patch.object(native, "native_target", side_effect=ValueError("PRIVATE_VALUE")), \
                patch.object(native, "cleanup_native_run") as cleanup:
            clock.now.side_effect = [started, finished]
            with self.assertRaises(ValueError):
                native.run_native(self.args, self.root)
        report = self.report()
        self.assertEqual(report["recordedAtUtc"], started.isoformat())
        self.assertEqual(report["startedAtUtc"], started.isoformat())
        self.assertEqual(report["finishedAtUtc"], finished.isoformat())
        self.assertEqual(report["stageRecordedAtUtc"], {})
        self.assertTrue(report["cleanupComplete"])
        self.assertNotIn("completedAtUtc", report)
        self.assertNotIn("PRIVATE_VALUE", json.dumps(report))
        cleanup.assert_called_once_with(None, None, None)

    def test_argument_denial_is_recorded_before_target_discovery(self):
        self.args.timeout = 901
        with patch.object(native, "native_target") as target:
            with self.assertRaises(ValueError):
                native.run_native(self.args, self.root)
        self.assertEqual(self.report()["failureStage"], "argument_preflight")
        target.assert_not_called()

    def test_interrupt_is_distinct_and_preserves_partial_stages(self):
        stage_time = datetime(2030, 1, 2, tzinfo=timezone.utc).isoformat()
        control = Mock(stages=["browser_request_started"], captured=set(),
                       stage_recorded_at={"browser_request_started": stage_time},
                       url="http://127.0.0.1:1234/capability/", store_key="isolated")
        process = Mock(returncode=None)
        process.poll.side_effect = KeyboardInterrupt()
        with patch.object(native, "native_target", return_value="macos"), \
                patch.object(native, "approved_registration", return_value=(Path("receipt"), Path("owner"), {})), \
                patch.object(native, "NativeControl", return_value=control), \
                patch.object(native.subprocess, "Popen", return_value=process), \
                patch.object(native, "stop_owned_process") as stop, \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(KeyboardInterrupt):
                native.run_native(self.args, self.root)
        report = self.report()
        self.assertEqual(report["failureReason"], "interrupted")
        self.assertEqual(report["failureStage"], "native_run")
        self.assertEqual(report["stages"], ["browser_request_started"])
        self.assertFalse(report["actualNativeAppAuth"])
        self.assertEqual(report["capturedApiPhases"], [])
        self.assertEqual(report["stageRecordedAtUtc"],
                         {"browser_request_started": stage_time})
        self.assertIsNotNone(report["finishedAtUtc"])
        stop.assert_called_once_with(process)
        control.close.assert_called_once_with()

    def test_cleanup_failure_records_no_success(self):
        control = Mock(stages=[], captured=set(), stage_recorded_at={},
                       url="http://127.0.0.1:1234/capability/", store_key="isolated")
        process = Mock(returncode=1)
        process.poll.return_value = 1
        control.close.side_effect = RuntimeError("PRIVATE_CLEANUP_FAILURE")
        with patch.object(native, "native_target", return_value="macos"), \
                patch.object(native, "approved_registration", return_value=(Path("receipt"), Path("owner"), {})), \
                patch.object(native, "NativeControl", return_value=control), \
                patch.object(native.subprocess, "Popen", return_value=process), \
                patch.object(native, "stop_owned_process"), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(RuntimeError):
                native.run_native(self.args, self.root)
        report = self.report()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["failureStage"], "cleanup")
        self.assertFalse(report["cleanupComplete"])
        self.assertIsNotNone(report["finishedAtUtc"])
        self.assertEqual(report["stageRecordedAtUtc"], {})
        self.assertNotIn("PRIVATE_CLEANUP_FAILURE", json.dumps(report))

    def test_unstarted_control_cleanup_does_not_wait_for_shutdown(self):
        directory = self.root / "control"
        directory.mkdir()
        control = NativeControl(directory, {})
        control.close()
        self.assertFalse(control.thread.is_alive())

    def test_success_records_terminal_time_and_does_not_claim_cloud_or_restart(self):
        stages = list(native.expected_stages())
        stage_times = {stage: datetime(2030, 1, 2, tzinfo=timezone.utc).isoformat()
                       for stage in stages}
        control = Mock(stages=stages, captured=set(native.PHASES),
                       stage_recorded_at=stage_times,
                       url="http://127.0.0.1:1234/capability/", store_key="isolated")
        process = Mock(returncode=0)
        process.poll.return_value = 0

        def verify(command, **unused):
            output = Path(command[command.index("--output-dir") + 1])
            private_json(output / "identity.local.json",
                         {"tenantId": "selected", "ownerObjectId": "approved", "subject": "same"})
            return Mock(returncode=0, stdout=json.dumps({
                "subjectFromApiToken": True, "grantsApplied": False}))

        with patch.object(native, "native_target", return_value="macos"), \
                patch.object(native, "approved_registration", return_value=(Path("receipt"), Path("owner"), {})), \
                patch.object(native, "NativeControl", return_value=control), \
                patch.object(native.subprocess, "Popen", return_value=process) as launch, \
                patch.object(native.subprocess, "run", side_effect=verify), \
                patch.object(native, "stop_owned_process"), \
                contextlib.redirect_stdout(io.StringIO()):
            result = native.run_native(self.args, self.root)
        self.assertEqual(result, self.report())
        self.assertEqual(result["status"], "passed")
        self.assertTrue(result["cleanupComplete"])
        self.assertEqual(result["recordedAtUtc"], result["startedAtUtc"])
        self.assertLessEqual(result["startedAtUtc"], result["completedAtUtc"])
        self.assertLessEqual(result["completedAtUtc"], result["finishedAtUtc"])
        self.assertEqual(result["stageRecordedAtUtc"], stage_times)
        self.assertFalse(result["processRestartVerified"])
        self.assertFalse(result["cosmosConnectionVerified"])
        self.assertFalse(result["freshIdentityProofVerified"])
        self.assertIn("--dart-define=COSMOS_SYNC_ENTRA_TIMEOUT_SECONDS=60",
                      launch.call_args.args[0])
        control.close.assert_called_once_with()


class ApprovedRegistrationTests(unittest.TestCase):
    tenant = "11111111-1111-4111-8111-111111111111"
    owner = "22222222-2222-4222-8222-222222222222"
    api = "33333333-3333-4333-8333-333333333333"
    client = "44444444-4444-4444-8444-444444444444"

    def receipts(self, customer=False):
        issuer = ("https://" + self.tenant + ".ciamlogin.com/" + self.tenant + "/v2.0" if customer
                  else "https://login.microsoftonline.com/" + self.tenant + "/v2.0")
        owner = {"tenantId": self.tenant, "ownerObjectId": self.owner}
        receipt = {
            **owner, "configurationVerified": True, "nativeCallbackConfigured": True,
            "api": {"appId": self.api}, "native": {"appId": self.client},
            "oidc": {"issuer": issuer, "audience": self.api, "tenantClaim": "tid",
                     "requiredScope": "Cosmos.Sync", "allowedClientIds": [self.client]},
            "nativeConfig": {
                "issuer": issuer, "clientId": self.client,
                "redirectUrl": "com.anaregdesign.cosmossync://auth/oauthredirect",
                "discoveryUrl": issuer + "/.well-known/openid-configuration",
                "scopes": ["openid", "profile", "offline_access", "api://" + self.api + "/Cosmos.Sync"],
            },
        }
        return receipt, owner

    def check(self, receipt, owner):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            private_json(directory / "registration-receipt.local.json", receipt)
            private_json(directory / "approved-owner.local.json", owner)
            return native.approved_registration(directory)[2]

    def test_exact_workforce_and_customer_pin_without_changing_legacy_inputs(self):
        for customer in (False, True):
            with self.subTest(customer=customer):
                receipt, owner = self.receipts(customer)
                self.assertEqual(self.check(receipt, owner), receipt["nativeConfig"])

    def test_relative_selection_is_absolute_before_the_go_subprocess_changes_cwd(self):
        selection = Path(".cache/separate-approved-customer")
        directory = native.registration_directory(Path.cwd(), selection)
        self.assertTrue(directory.is_absolute())
        self.assertEqual(directory, Path.cwd() / selection)
        self.assertEqual(native.registration_directory(Path.cwd(), None),
                         Path.cwd() / ".cache/entra-azure")

    def test_issuer_pin_rejects_friendly_common_other_tenant_suffix_and_http(self):
        for issuer in (
            "https://friendly.ciamlogin.com/" + self.tenant + "/v2.0",
            "https://" + self.client + ".ciamlogin.com/" + self.tenant + "/v2.0",
            "https://" + self.tenant + ".ciamlogin.com/common/v2.0",
            "https://" + self.tenant + ".ciamlogin.com.attacker.invalid/" + self.tenant + "/v2.0",
            "http://" + self.tenant + ".ciamlogin.com/" + self.tenant + "/v2.0",
        ):
            with self.subTest(issuer=issuer):
                receipt, owner = self.receipts(True)
                receipt["oidc"]["issuer"] = receipt["nativeConfig"]["issuer"] = issuer
                receipt["nativeConfig"]["discoveryUrl"] = issuer + "/.well-known/openid-configuration"
                with self.assertRaisesRegex(ValueError, "approved_registration_configuration_required"):
                    self.check(receipt, owner)

    def test_owner_receipt_config_native_client_and_discovery_mismatch_are_denied(self):
        changes = (
            lambda receipt: receipt.update(ownerObjectId=self.client),
            lambda receipt: receipt.update(configurationVerified=False),
            lambda receipt: receipt.update(nativeCallbackConfigured="true"),
            lambda receipt: receipt["nativeConfig"].update(clientId=self.api),
            lambda receipt: receipt["oidc"].update(audience=self.client),
            lambda receipt: receipt["oidc"].update(tenantClaim="sub"),
            lambda receipt: receipt["oidc"].update(allowedClientIds=[self.client, self.api]),
            lambda receipt: receipt["nativeConfig"].update(discoveryUrl="https://attacker.invalid/config"),
        )
        for change in changes:
            with self.subTest(change=change):
                receipt, owner = self.receipts(True)
                change(receipt)
                with self.assertRaisesRegex(ValueError, "approved_registration_configuration_required"):
                    self.check(receipt, owner)

    def test_api_only_scope_contract_rejects_graph_raw_duplicate_and_missing_scope(self):
        for scopes in (
            ["openid", "profile", "offline_access"],
            ["openid", "profile", "offline_access", "User.Read"],
            ["openid", "profile", "offline_access", "api://" + self.client + "/Cosmos.Sync"],
            ["openid", "profile", "offline_access", "api://" + self.api + "/Cosmos.Sync", "openid"],
            "openid profile offline_access",
        ):
            with self.subTest(scopes=scopes):
                receipt, owner = self.receipts(True)
                receipt["nativeConfig"]["scopes"] = scopes
                with self.assertRaisesRegex(ValueError, "approved_registration_configuration_required"):
                    self.check(receipt, owner)

    def test_exact_native_callback_is_required(self):
        receipt, owner = self.receipts(True)
        receipt["nativeConfig"]["redirectUrl"] = "com.unreviewed.app://callback"
        with self.assertRaisesRegex(ValueError, "approved_callback_required"):
            self.check(receipt, owner)


class NativeTargetTests(unittest.TestCase):
    def arguments(self, **overrides):
        values = {"device": "macos", "flutter_bin": "flutter", "device_id_file": None,
                  "authorize_install": False, "output": None}
        values.update(overrides)
        return argparse.Namespace(**values)

    def test_default_target_remains_macos_without_device_discovery(self):
        with patch.object(native, "android_target") as resolve:
            self.assertEqual(native_target(self.arguments()), "macos")
            resolve.assert_not_called()

    def test_isolated_sign_in_is_explicit_public_flag_not_a_token_or_identity_override(self):
        default = native.native_command("flutter", "macos", "http://127.0.0.1:1234/capability/")
        self.assertNotIn("--dart-define=COSMOS_SYNC_ENTRA_ISOLATED_SIGN_IN=true", default)
        isolated = native.native_command("flutter", "macos", "http://127.0.0.1:1234/capability/", True)
        self.assertEqual(isolated[:-1], default)
        self.assertEqual(isolated[-1], "--dart-define=COSMOS_SYNC_ENTRA_ISOLATED_SIGN_IN=true")
        self.assertFalse(any("accessToken" in argument or "ownerObjectId" in argument
                             for argument in isolated))

    def test_manual_start_is_explicit_and_preserves_native_trust_and_target(self):
        default = native.native_command("flutter", "selected-device", "http://127.0.0.1:1234/capability/")
        manual = native.native_command("flutter", "selected-device", "http://127.0.0.1:1234/capability/",
                                       manual_start=True)
        self.assertEqual(manual[:-1], default)
        self.assertEqual(manual[-1], "--dart-define=COSMOS_SYNC_ENTRA_MANUAL_START=true")
        self.assertFalse(any("accessToken" in argument or "ownerObjectId" in argument
                             for argument in manual))

    def test_native_test_receives_exact_bounded_timeout_not_fixed_eight_minutes(self):
        for seconds in (60, 480, 600, 900):
            with self.subTest(seconds=seconds):
                command = native.native_command(
                    "flutter", "macos", "http://127.0.0.1:1234/capability/",
                    manual_start=True, timeout=seconds)
                self.assertIn("--dart-define=COSMOS_SYNC_ENTRA_TIMEOUT_SECONDS=" + str(seconds),
                              command)
                self.assertIn("--dart-define=COSMOS_SYNC_ENTRA_MANUAL_START=true", command)
        default = native.native_command("flutter", "macos", "http://127.0.0.1:1234/capability/")
        self.assertIn("--dart-define=COSMOS_SYNC_ENTRA_TIMEOUT_SECONDS=600", default)

    def test_native_command_rejects_invalid_timeout_before_any_process(self):
        for seconds in (59, 901, "600", 600.0, True, None):
            with self.subTest(seconds=seconds):
                with self.assertRaisesRegex(ValueError, "bounded_native_auth_timeout_required"):
                    native.native_command(
                        "flutter", "macos", "http://127.0.0.1:1234/capability/",
                        timeout=seconds)

    def test_manual_success_requires_readiness_in_addition_to_every_original_stage(self):
        self.assertEqual(native.expected_stages(), native.STAGES)
        self.assertEqual(native.expected_stages(True), native.STAGES | {"owner_start_ready"})
        self.assertNotEqual(native.STAGES, native.expected_stages(True))

    def test_android_reuses_exact_physical_target_and_install_boundary(self):
        args = self.arguments(device="android", device_id_file=".cache/device.txt",
                              authorize_install=True, output="artifacts/native.json")
        with patch.object(native, "android_target", return_value=("private-device", {})) as resolve:
            self.assertEqual(native_target(args), "private-device")
            resolve.assert_called_once_with(args, "flutter", emulator=False)

    def test_emulator_reuses_exact_target_without_physical_fallback(self):
        args = self.arguments(device="android-emulator", device_id_file=".cache/emulator.txt",
                              authorize_install=True)
        with patch.object(native, "android_target", return_value=("emulator-5562", {})) as resolve:
            self.assertEqual(native_target(args), "emulator-5562")
            resolve.assert_called_once_with(args, "flutter", emulator=True)

    def test_emulator_denial_precedes_receipt_or_cloud_access(self):
        args = self.arguments(device="android-emulator")
        with patch.object(native, "private_input") as read:
            with self.assertRaises(ValidationError):
                native_target(args)
            read.assert_not_called()

    def test_emulator_resolution_failure_cannot_retry_a_physical_target(self):
        args = self.arguments(device="android-emulator", device_id_file=".cache/emulator.txt",
                              authorize_install=True)
        with patch.object(native, "android_target", side_effect=ValidationError("not_an_emulator")) as resolve:
            with self.assertRaisesRegex(ValidationError, "not_an_emulator"):
                native_target(args)
            resolve.assert_called_once_with(args, "flutter", emulator=True)

    def test_success_evidence_keeps_target_kinds_and_cloud_gaps_distinct(self):
        for device in ("macos", "android", "android-emulator"):
            with self.subTest(device=device):
                proof = native.successful_native_evidence(device)
                self.assertEqual(proof["platform"], "macos" if device == "macos" else "android")
                self.assertEqual(proof["physicalDevice"], device == "android")
                self.assertEqual(proof["emulator"], device == "android-emulator")
                self.assertFalse(proof["processRestartVerified"])
                self.assertFalse(proof["cosmosConnectionVerified"])
                self.assertFalse(proof["multiPrincipalRealProviderVerified"])
                self.assertFalse(proof["grantsApplied"])

    def test_unknown_target_cannot_silently_select_macos_or_claim_success(self):
        with patch.object(native, "android_target") as resolve:
            for operation in (lambda: native_target(self.arguments(device="ios")),
                              lambda: native.successful_native_evidence("ios")):
                with self.assertRaisesRegex(ValueError, "unsupported_native_auth_target"):
                    operation()
            resolve.assert_not_called()

    def test_android_install_denial_precedes_receipt_or_cloud_access(self):
        args = self.arguments(device="android")
        with patch.object(native, "private_input") as read:
            with self.assertRaises(ValidationError):
                native_target(args)
            read.assert_not_called()

    def test_android_flags_cannot_select_an_unrelated_macos_target(self):
        for args in (self.arguments(device_id_file=".cache/device.txt"),
                     self.arguments(authorize_install=True)):
            with self.subTest(args=args):
                with patch.object(native, "android_target") as resolve:
                    with self.assertRaisesRegex(ValueError, "android_options_require_android_target"):
                        native_target(args)
                    resolve.assert_not_called()

    def test_cleanup_always_closes_control_and_only_owned_reverse(self):
        process, control, reverse = Mock(), Mock(), Mock()
        reverse.close.return_value = True
        with patch.object(native, "stop_owned_process") as stop:
            native.cleanup_native_run(process, control, reverse)
            stop.assert_called_once_with(process)
        control.close.assert_called_once_with()
        reverse.close.assert_called_once_with()

    def test_process_cleanup_failure_still_closes_control_and_reverse(self):
        control, reverse = Mock(), Mock()
        reverse.close.return_value = True
        with patch.object(native, "stop_owned_process", side_effect=RuntimeError("process_cleanup_failed")):
            with self.assertRaisesRegex(RuntimeError, "process_cleanup_failed"):
                native.cleanup_native_run(Mock(), control, reverse)
        control.close.assert_called_once_with()
        reverse.close.assert_called_once_with()

    def test_control_cleanup_failure_still_closes_reverse(self):
        control, reverse = Mock(), Mock()
        control.close.side_effect = RuntimeError("control_cleanup_failed")
        reverse.close.return_value = True
        with patch.object(native, "stop_owned_process"):
            with self.assertRaisesRegex(RuntimeError, "control_cleanup_failed"):
                native.cleanup_native_run(None, control, reverse)
        reverse.close.assert_called_once_with()

    def test_reverse_cleanup_failure_cannot_report_success(self):
        control, reverse = Mock(), Mock()
        reverse.close.return_value = False
        with patch.object(native, "stop_owned_process"):
            with self.assertRaisesRegex(RuntimeError, "owned_android_reverse_cleanup_failed"):
                native.cleanup_native_run(None, control, reverse)

    def test_operator_interrupt_uses_the_finally_cleanup_path(self):
        with self.assertRaisesRegex(InterruptedError, "native_auth_interrupted"):
            native.interrupt_native_run(None, None)


if __name__ == "__main__":
    unittest.main()
