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

from native_entra_auth import NativeControl, private_input, private_json


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


if __name__ == "__main__":
    unittest.main()
