"""Hosted validation authorization/budget/privacy gates; no Azure connections."""
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import hosted_azure_live as hosted
from native_entra_auth import private_json


def manifest():
    return {"schemaVersion": 1, "authorizationMode": "builtin", "replicas": 1,
            "endpoint": "https://fixture-hosted.example/", "targetApprovalReference": "fixture-target-approved",
            "liveWriteApprovalReference": "fixture-three-mutations-approved", "testDataRetentionAcknowledged": True,
            "accessTokenFile": "/private/fixture-token", "ownerFile": "/private/fixture-owner",
            "receiptFile": "/private/fixture-receipt",
            "budget": {"maxRuntimeSeconds": 120, "maxProtocolRequests": 40, "maxAcceptedAppMutations": 3}}


class HostedManifestTests(unittest.TestCase):
    def test_offline_plan_does_not_load_token_or_contact_provider_or_bff(self):
        with tempfile.TemporaryDirectory() as temp:
            file = Path(temp) / "manifest.json"
            private_json(file, manifest())
            output = io.StringIO()
            with patch.object(hosted.sys, "argv", ["hosted_azure_live.py", "--manifest", str(file)]), \
                    patch.object(hosted, "verify_token") as token, \
                    patch.object(hosted.subprocess, "Popen") as process, redirect_stdout(output):
                hosted.main()
            result = json.loads(output.getvalue())
            self.assertEqual(result["mode"], "offline-hosted-plan")
            self.assertFalse(result["azureContacted"])
            self.assertFalse(result["tokensLoaded"])
            token.assert_not_called()
            process.assert_not_called()

    def test_invalid_approval_budget_target_never_loads_token_or_starts_process(self):
        for change in ({"targetApprovalReference": ""}, {"liveWriteApprovalReference": ""},
                       {"testDataRetentionAcknowledged": False}, {"authorizationMode": "legacy-grants"},
                       {"replicas": 2}, {"endpoint": "http://fixture-hosted.example/"},
                       {"endpoint": "https://fixture-hosted.example/path"}, {"accessTokenFile": "relative.jwt"},
                       {"budget": {"maxRuntimeSeconds": 121, "maxProtocolRequests": 40, "maxAcceptedAppMutations": 3}},
                       {"budget": {"maxRuntimeSeconds": 120, "maxProtocolRequests": 41, "maxAcceptedAppMutations": 3}},
                       {"budget": {"maxRuntimeSeconds": 120, "maxProtocolRequests": 40, "maxAcceptedAppMutations": 4}}):
            selected = {**manifest(), **change}
            with self.subTest(change=change), patch.object(hosted, "verify_token") as token, \
                    patch.object(hosted.subprocess, "Popen") as process, self.assertRaises(hosted.GateError):
                hosted.execute(selected, "unused-dart")
            token.assert_not_called()
            process.assert_not_called()

    def test_private_inputs_refuse_symlinks_public_files_and_excess_size(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            file = root / "manifest.json"
            private_json(file, manifest())
            self.assertEqual(hosted.load_manifest(file), manifest())
            link = root / "link.json"
            link.symlink_to(file)
            with self.assertRaises(hosted.GateError):
                hosted.load_manifest(link)
            file.chmod(0o644)
            with self.assertRaises(hosted.GateError):
                hosted.load_manifest(file)
            file.chmod(0o600)
            file.write_bytes(b"x" * 65537)
            with self.assertRaises(hosted.GateError):
                hosted.load_manifest(file)

    def test_private_fifo_input_is_refused_without_waiting_for_a_writer(self):
        with tempfile.TemporaryDirectory() as temp:
            fifo = Path(temp) / "not-a-regular-input"
            os.mkfifo(fifo, 0o600)
            started = time.monotonic()
            with self.assertRaises(hosted.GateError):
                hosted.private_bytes(fifo, 16384)
            self.assertLess(time.monotonic() - started, 1)

    def test_failure_preserves_partial_evidence_and_removes_copied_jwt(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)

            def fail_after_copy(_manifest, directory, **_kwargs):
                fd = os.open(directory / "api-access.jwt", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, "w") as output:
                    output.write("private.fixture.jwt")
                raise hosted.GateError("private proof failed")

            with patch.object(hosted, "ROOT", root), patch.object(hosted, "verify_token", side_effect=fail_after_copy):
                with self.assertRaises(hosted.GateError):
                    hosted.execute(manifest(), "unused-dart")
            proof = next((root / ".cache/hosted-azure-live").glob("*/proof.json"))
            value = hosted.private_input(proof)
            self.assertFalse(value["livePhaseStarted"])
            self.assertEqual(value["acceptedNewAppMutations"], 0)
            self.assertTrue(value["cleanup"]["copiedApiJwtRemoved"])
            self.assertFalse((proof.parent / "api-access.jwt").exists())
            self.assertNotIn("private.fixture.jwt", proof.read_text())

    def test_partial_unknown_write_and_cleanup_failure_preserve_private_proof(self):
        class Control:
            requests, mutation_attempts = 8, 1
            accepted, conflicts = 0, 0
            unknown_outcome, pending_attempt = True, None
            stages = [hosted.STAGES[0]]
            url = "http://127.0.0.1:12345/private-capability/"
            stopped = False

            def start(self):
                pass

            def close(self):
                self.stopped = True

        class Process:
            returncode = 1

            def poll(self):
                return 1

        class Window:
            expired = threading.Event()
            deadline = float("inf")
            stopped = False

            def add_process(self, _):
                pass

            def close(self):
                self.stopped = True

        control, window = Control(), Window()
        token = "private.fixture.jwt"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "packages/cosmos_sync").mkdir(parents=True)
            with patch.object(hosted, "ROOT", root), patch.object(hosted, "verify_token", return_value=token), \
                    patch.object(hosted, "HostedControl", return_value=control), \
                    patch.object(hosted, "LiveWindow", return_value=window), \
                    patch.object(hosted.subprocess, "Popen", return_value=Process()) as process, \
                    patch.object(hosted, "stop_process", side_effect=RuntimeError("cleanup failed")):
                with self.assertRaises(hosted.GateError):
                    hosted.execute(manifest(), "fixture-dart")
            self.assertNotIn(token, str(process.call_args))
            proof = next((root / ".cache/hosted-azure-live").glob("*/proof.json"))
            value = hosted.private_input(proof)
            self.assertEqual(value["acceptedNewAppMutations"], "unknown-on-failure")
            self.assertTrue(value["testDataMayBeRetained"])
            self.assertFalse(value["cleanup"]["ownedProcessStopped"])
            self.assertTrue(value["cleanup"]["watchdogStopped"])
            self.assertTrue(value["cleanup"]["ownedControlStopped"])
            self.assertTrue(control.stopped and window.stopped)
            self.assertNotIn(token, proof.read_text())


class HostedControlTests(unittest.TestCase):
    def setUp(self):
        self.now = [0]
        self.token = "private.token.must-not-leak"
        self.control = hosted.HostedControl({"endpoint": "https://fixture-hosted.example/", "accessToken": self.token},
                                            clock=lambda: self.now[0])
        self.logs = io.StringIO()
        self.redirect = redirect_stdout(self.logs)
        self.redirect.__enter__()
        self.control.start()

    def tearDown(self):
        self.control.close()
        self.redirect.__exit__(None, None, None)

    def request(self, path, value=None, *, base=None, headers=None):
        data = json.dumps(value).encode() if value is not None else None
        request = Request((base or self.control.url) + path, data=data,
                          headers={"Content-Type": "application/json", **(headers or {})})
        try:
            with urlopen(request, timeout=3) as response:
                return response.status, response.read().decode()
        except HTTPError as error:
            with error:
                return error.code, error.read().decode()

    def permit(self, method="GET", path="/v1/session", origin="https://fixture-hosted.example"):
        return self.request("permit", {"method": method, "path": path, "origin": origin})

    def outcome(self, attempt, value):
        return self.request("result", {"mutationAttempt": attempt, "outcome": value})

    def test_fixture_is_disclosed_only_to_exact_capability_local_peer(self):
        self.assertEqual(self.request("config")[0], 200)
        wrong = self.control.url.replace(self.control.prefix, "/wrong/")
        for path, options in (("config", {"base": wrong}), ("config?extra=1", {}), ("token", {}),
                              ("config", {"headers": {"Origin": "https://attacker.example"}}),
                              ("config", {"headers": {"Host": "attacker.example"}})):
            status, body = self.request(path, **options)
            self.assertEqual(status, 404)
            self.assertNotIn(self.token, body)
        self.assertNotIn(self.token, self.logs.getvalue())

    def test_protocol_and_mutation_attempt_limits_block_before_another_call(self):
        self.control.max_requests = 5
        for attempt in range(1, 5):
            self.assertEqual(self.permit("POST", "/v1/mutations")[0], 200)
            self.assertEqual(self.outcome(attempt, "conflict")[0], 200)
        self.assertEqual(self.permit("POST", "/v1/mutations")[0], 429)
        self.assertEqual(self.permit()[0], 200)
        self.assertEqual(self.permit()[0], 429)
        self.assertEqual((self.control.requests, self.control.mutation_attempts), (5, 4))

    def test_three_accepted_outcomes_block_another_mutation_even_with_attempt_budget(self):
        for attempt in range(1, 4):
            self.assertEqual(self.permit("POST", "/v1/mutations")[0], 200)
            self.assertEqual(self.outcome(attempt, "accepted")[0], 200)
        self.assertEqual(self.permit("POST", "/v1/mutations")[0], 429)
        self.assertEqual(self.permit()[0], 200)
        self.assertEqual(self.control.accepted, 3)

    def test_unknown_or_unresolved_outcome_blocks_another_mutation(self):
        self.assertEqual(self.permit("POST", "/v1/mutations")[0], 200)
        self.assertEqual(self.permit("POST", "/v1/mutations")[0], 429)
        self.assertEqual(self.outcome(2, "accepted")[0], 400)
        self.assertEqual(self.outcome(1, "unknown")[0], 200)
        self.assertEqual(self.permit("POST", "/v1/mutations")[0], 429)
        self.assertEqual(self.permit()[0], 429)
        self.assertEqual(self.outcome(1, "accepted")[0], 400)
        self.assertEqual(self.control.accepted, 0)

    def test_policy_management_other_origin_and_unknown_fields_are_refused(self):
        for method, path, origin in (("POST", "/v1/scopes", "https://fixture-hosted.example"),
                                     ("POST", "/v1/scopes/example/members", "https://fixture-hosted.example"),
                                     ("DELETE", "/v1/mutations", "https://fixture-hosted.example"),
                                     ("GET", "/v1/session", "https://other.example"),
                                     ("GET", "/v1/session", "https://fixture-hosted.example:444"),
                                     ("GET", "/secret-reflection", "https://fixture-hosted.example")):
            status, body = self.permit(method, path, origin)
            self.assertEqual(status, 400)
            self.assertNotIn("secret-reflection", body)
        status, body = self.request("permit", {"method": "GET", "path": "/v1/session",
                                               "origin": "https://fixture-hosted.example", "token": self.token})
        self.assertEqual(status, 400)
        self.assertNotIn(self.token, body)
        self.assertEqual(self.control.requests, 0)

    def test_absolute_deadline_blocks_token_delivery_requests_and_stages(self):
        self.now[0] = 120
        self.assertEqual(self.request("config")[0], 429)
        self.assertEqual(self.permit()[0], 429)
        self.assertEqual(self.request("stage", {"stage": hosted.STAGES[0]})[0], 429)
        self.assertEqual(self.control.requests, 0)
        self.assertEqual(self.control.stages, [])

    def test_only_complete_ordered_stages_can_produce_success(self):
        self.assertEqual(self.request("stage", {"stage": hosted.STAGES[-1]})[0], 400)
        self.assertEqual(self.request("stage", {"stage": hosted.STAGES[0]})[0], 200)
        self.assertEqual(self.request("stage", {"stage": hosted.STAGES[0]})[0], 400)
        self.assertEqual(self.request("stage", {"stage": self.token})[0], 400)
        self.assertNotIn(self.token, self.logs.getvalue())
        for stage in hosted.STAGES[1:]:
            self.assertEqual(self.request("stage", {"stage": stage})[0], 200)
        self.assertEqual(tuple(self.control.stages), hosted.STAGES)


if __name__ == "__main__":
    unittest.main()
