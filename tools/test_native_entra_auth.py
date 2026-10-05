import argparse
import contextlib
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
