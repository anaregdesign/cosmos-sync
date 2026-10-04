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

    def test_android_reuses_exact_physical_target_and_install_boundary(self):
        args = self.arguments(device="android", device_id_file=".cache/device.txt",
                              authorize_install=True, output="artifacts/native.json")
        with patch.object(native, "android_target", return_value=("private-device", {})) as resolve:
            self.assertEqual(native_target(args), "private-device")
            resolve.assert_called_once_with(args, "flutter")

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
