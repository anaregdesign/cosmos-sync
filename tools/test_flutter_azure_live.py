#!/usr/bin/env python3
"""Security/budget checks of the manual live-UI control; never contacts Azure."""
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import tempfile
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from flutter_azure_live import STAGES, UIControl
from native_entra_auth import private_json


class UIControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.grants = [{"tenant": "fixture-tenant", "subject": "fixture-subject", "scopeMode": "user",
                        "permissionVersion": "writer", "canRead": True, "canWrite": True, "active": True}]
        self.path = self.directory / "grants.json"
        private_json(self.path, self.grants)
        self.logs = io.StringIO()
        self.redirect = redirect_stdout(self.logs)
        self.redirect.__enter__()
        self.control = UIControl({"accessToken": "fixture-api-proof-never-log", "documentId": "fixture-document"},
                                 self.grants, self.path)
        self.control.start()

    def tearDown(self):
        self.control.close()
        self.redirect.__exit__(None, None, None)
        self.temp.cleanup()

    def request(self, path, value=None, *, url=None):
        data = json.dumps(value).encode() if value is not None else None
        request = Request((url or self.control.url) + path, data=data,
                          headers={"Content-Type": "application/json"})
        try:
            with urlopen(request, timeout=3) as response:
                return response.status, response.read().decode()
        except HTTPError as error:
            with error:
                return error.code, error.read().decode()

    def stages_until(self, last):
        for stage in STAGES[:STAGES.index(last) + 1]:
            self.assertEqual(self.request("stage", {"stage": stage})[0], 200)

    def test_only_exact_capability_config_can_disclose_fixture(self):
        self.assertEqual(self.request("config")[0], 200)
        origin = self.control.url.split(self.control.prefix)[0] + "/wrong-capability/"
        for path, url in (("config", origin), ("token", None), ("config?copy=1", None), ("config/", None)):
            status, body = self.request(path, url=url)
            self.assertEqual(status, 404)
            self.assertNotIn("fixture-api-proof-never-log", body)
        self.assertNotIn("fixture-api-proof-never-log", self.logs.getvalue())

    def test_hard_protocol_and_mutation_attempt_bounds(self):
        self.control.max_requests = 4
        for unused in range(3):
            self.assertEqual(self.request("permit", {"method": "POST", "path": "/v1/mutations"})[0], 200)
        self.assertEqual(self.request("permit", {"method": "POST", "path": "/v1/mutations"})[0], 429)
        self.assertEqual(self.request("permit", {"method": "GET", "path": "/v1/session"})[0], 200)
        self.assertEqual(self.request("permit", {"method": "GET", "path": "/v1/sync"})[0], 429)
        self.assertEqual(self.control.requests, 4)
        self.assertEqual(self.control.mutation_attempts, 3)

    def test_unknown_fields_methods_routes_and_stage_strings_never_reflected(self):
        for path, body in (("permit", {"method": "DELETE", "path": "/v1/mutations"}),
                           ("permit", {"method": "GET", "path": "/arbitrary-secret-value"}),
                           ("permit", {"method": "GET", "path": "/v1/session", "token": "secret-value"}),
                           ("stage", {"stage": "arbitrary-secret-value"}),
                           ("action", {"action": "arbitrary-secret-value"})):
            status, result = self.request(path, body)
            self.assertEqual(status, 400)
            self.assertNotIn("secret-value", result)
        self.assertEqual(self.control.requests, 0)
        self.assertEqual(self.control.stages, [])
        self.assertNotIn("secret-value", self.logs.getvalue())

    def test_permission_change_requires_success_stages_and_only_owned_grant(self):
        self.assertEqual(self.request("action", {"action": "downgrade"})[0], 400)
        self.stages_until("cross_replica_document_verified")
        self.assertEqual(self.request("action", {"action": "downgrade"})[0], 200)
        updated = json.loads(self.path.read_text())
        self.assertEqual(updated[0]["subject"], "fixture-subject")
        self.assertEqual(updated[0]["scopeMode"], "user")
        self.assertFalse(updated[0]["canWrite"])
        self.assertTrue(updated[0]["active"])
        self.assertNotEqual(updated[0]["permissionVersion"], "writer")
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.request("action", {"action": "downgrade"})[0], 400)
        self.assertEqual(self.request("action", {"action": "revoke"})[0], 400)
        self.assertEqual(self.request("stage", {"stage": "permission_generation_purged"})[0], 200)
        self.assertEqual(self.request("action", {"action": "revoke"})[0], 200)
        self.assertFalse(json.loads(self.path.read_text())[0]["active"])
        self.assertEqual(self.control.actions, ["downgrade", "revoke"])

    def test_out_of_order_or_repeated_stage_cannot_produce_success_evidence(self):
        self.assertEqual(self.request("stage", {"stage": "local_signout_complete"})[0], 400)
        self.assertEqual(self.request("stage", {"stage": STAGES[0]})[0], 200)
        self.assertEqual(self.request("stage", {"stage": STAGES[0]})[0], 400)
        self.assertEqual(self.control.stages, [STAGES[0]])


if __name__ == "__main__":
    unittest.main()
