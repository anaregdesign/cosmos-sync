from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import urllib.error
from unittest.mock import Mock, patch

from directory_proof_control import DirectoryProofSession, PROOF_FIELDS, validate_manifest
from directory_request_ledger import initialize
from directory_hosting_contract import config_digest
from live_azure_preflight import GateError


class DirectoryProofControlTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.now = datetime.now(timezone.utc)
        self.config = {"issuer": "https://fixture.ciamlogin.com/fixture/v2.0",
                       "clientId": "public-client", "redirectUrl": "com.example.app://auth/callback"}
        self.manifest = {
            "schemaVersion": 1, "authorizationMode": "directory", "endpoint": "https://fixture.example",
            "runtimeConfigFile": str(self.directory / "runtime.json"),
            "aggregateLedgerFile": str(self.directory / "aggregate.json"),
            "targetApprovalReference": "synthetic-target", "directoryWriteApprovalReference": "synthetic-write",
            "retainedDirectoryStateAcknowledged": True,
            "budget": {"maxProtocolRequests": 4, "maxDirectoryMetadataOperations": 2,
                       "maxAuthorizationInitializations": 1, "maxFreshProofChecks": 1},
        }
        initialize(Path(self.manifest["aggregateLedgerFile"]), self.manifest["endpoint"], 0)
        runtime = {"storage": "cosmos", "development": False, "grants": [],
                   "oidc": {"issuer": self.config["issuer"], "allowedClientIds": [self.config["clientId"]]},
                   "authorization": {"mode": "directory", "directory": {
                       "callbacks": [self.config["redirectUrl"]], "namespace": "signed-control-fixture"}}}
        self.manifest["hosting"] = {
            "appResourceId": "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/fixture/providers/Microsoft.App/containerApps/fixture-app",
            "image": "ghcr.io/anaregdesign/cosmos-sync-bff@sha256:" + "a" * 64,
            "sourceCommit": "a" * 40, "reviewedConfigurationSha256": config_digest(runtime),
        }
        hosting = patch("directory_proof_control.verify_hosting")
        hosting.start()
        self.addCleanup(hosting.stop)
        self.session = DirectoryProofSession(
            self.manifest, self.config, self.directory, self.directory / "receipt.json",
            self.directory / "owner.json", runtime, self.directory, "go", now=lambda: self.now)
        self.addCleanup(self.session.close)
        self.proof = {"accessToken": "AAA.FRESH_API_SIGNATURE.BBB", "idToken": "CCC.FRESH_ID_SIGNATURE.DDD"}
        self.authentication = {**dict.fromkeys(PROOF_FIELDS, True), "rawProofPersisted": False,
                               "grantsApplied": False, "brokerProfileVerified": False,
                               "directoryOwnershipRegistered": False}
        self.calls = []
        self.responses = [
            {"version": 1, "targets": [self.session.target], "freshAuthenticationSeconds": 300,
             "maximumIdentities": 8, "recovery": "remaining-identity-only",
             "deletion": "operator-review-required", "migration": "operator-review-required"},
            {"operation": "register", "target": self.session.target, "challenge": "a" * 64,
             "expiresAt": (self.now + timedelta(seconds=290)).isoformat()},
            {"accountId": "b" * 64, "personalScopeId": "c" * 64, "identityGeneration": 1,
             "currentIdentityId": "d" * 64},
            {"principalId": "b" * 64, "scopeId": "c" * 64, "identityGeneration": 1,
             "identityId": "d" * 64, "scopeMode": "user"},
        ]
        self.opener = Mock()
        self.opener.open.side_effect = self.open
        self.patch_opener = patch("directory_proof_control.urllib.request.build_opener", return_value=self.opener)
        self.patch_opener.start()
        self.addCleanup(self.patch_opener.stop)
        self.process = patch("directory_proof_control.subprocess.run", return_value=Mock(
            returncode=0, stdout=json.dumps(self.authentication), stderr=""))
        self.verifier = self.process.start()
        self.addCleanup(self.process.stop)
        self.token_path = self.directory / "initial.jwt"
        self.token_path.write_text("AAA.INITIAL_API_SIGNATURE.BBB")
        self.session.verify_initial(self.token_path)

    def open(self, request, timeout):
        self.calls.append(request)
        self.assertLessEqual(timeout, 15)
        response = Mock(status=200)
        response.read.return_value = json.dumps(self.responses[len(self.calls) - 1]).encode()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        return response

    def test_signed_verifier_contract_and_exact_challenge_registration_budget(self):
        challenge = self.session.challenge()
        self.assertEqual(challenge["challenge"], "a" * 64)
        self.assertEqual(self.session.accept(self.proof),
                         {"freshAuthenticationVerified": True, "directoryRegistrationVerified": True})
        evidence = self.session.evidence()
        self.assertTrue(evidence["freshIdentityProofVerified"])
        self.assertTrue(evidence["directoryRegistrationVerified"])
        self.assertFalse(evidence["directoryWriteOutcomeUnknown"])
        self.assertEqual(evidence["directoryProofProtocolRequests"], 4)
        self.assertEqual(evidence["directoryMetadataOperationsReserved"], 2)
        self.assertEqual(evidence["directoryMetadataOperationsAcknowledged"], 2)
        self.assertEqual(evidence["authorizationInitializationsReserved"], 1)
        self.assertEqual(evidence["acceptedAppDocumentMutations"], 0)
        self.assertEqual([call.full_url for call in self.calls],
                         ["https://fixture.example" + path for path in
                          ("/v1/identity/capabilities", "/v1/identity/challenges",
                           "/v1/identity/register", "/v1/session")])
        command = self.verifier.call_args.args[0]
        self.assertIn("--fresh-proof-stdin", command)
        self.assertNotIn("--token-file", command)
        self.assertNotIn("--output-dir", command)
        self.assertNotIn(self.proof["idToken"], " ".join(command))
        transient = json.loads(self.verifier.call_args.kwargs["input"])
        self.assertEqual(transient, {"challenge": challenge["challenge"], **self.proof})
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()),
                         ["aggregate.json", "initial.jwt", "selected-api-proof"])
        self.assertNotIn("SIGNATURE", json.dumps(evidence))
        with self.assertRaises(GateError):
            self.session.accept(self.proof)
        with self.assertRaises(GateError):
            self.session.challenge()
        self.assertEqual(len(self.calls), 4)

    def test_manifest_requires_separate_write_acknowledgment_and_exact_budget(self):
        for key, value in (("authorizationMode", "builtin"), ("schemaVersion", True),
                           ("directoryWriteApprovalReference", ""),
                           ("retainedDirectoryStateAcknowledged", False),
                           ("endpoint", "http://localhost"), ("runtimeConfigFile", "relative.json")):
            with self.subTest(key=key), self.assertRaises(GateError):
                validate_manifest({**self.manifest, key: value})
        with self.assertRaises(GateError):
            validate_manifest({**self.manifest, "extra": "never-trust"})
        for key in self.manifest["budget"]:
            with self.subTest(budget=key), self.assertRaises(GateError):
                validate_manifest({**self.manifest, "budget": {**self.manifest["budget"], key: True}})

    def test_wrong_callback_target_or_expired_challenge_never_requests_fresh_proof(self):
        for change in ({"operation": "link"}, {"target": {**self.session.target, "callback": "com.wrong://auth"}},
                       {"challenge": "not-a-server-nonce"},
                       {"expiresAt": (self.now - timedelta(seconds=1)).isoformat()},
                       {"expiresAt": (self.now + timedelta(seconds=301)).isoformat()},
                       {"expiresAt": None}, {"expiresAt": 123},
                       {"expiresAt": "invalid-time"}):
            self.session.state = "selected"
            self.calls.clear()
            self.responses[1] = {**self.responses[1], **change}
            with self.subTest(change=change), self.assertRaises(GateError):
                self.session.challenge()
            self.assertEqual(self.verifier.call_count, 1)
            self.session.requests = self.session.metadata_reserved = self.session.metadata_acknowledged = 0
            self.responses[1] = {"operation": "register", "target": self.session.target, "challenge": "a" * 64,
                                 "expiresAt": (self.now + timedelta(seconds=290)).isoformat()}

    def test_wrong_selected_api_and_duplicate_initial_stop_before_directory_writes(self):
        with self.assertRaises(GateError):
            self.session.verify_initial(self.token_path)
        self.assertEqual(self.calls, [])

    def test_fresh_failure_preserves_acknowledged_challenge_and_never_registers(self):
        self.session.challenge()
        self.verifier.return_value.returncode = 1
        with self.assertRaises(GateError):
            self.session.accept(self.proof)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(self.session.evidence()["directoryMetadataOperationsAcknowledged"], 1)
        self.assertFalse(self.session.fresh_verified)
        self.assertFalse(self.session.registration_verified)
        with self.assertRaises(GateError):
            self.session.accept(self.proof)

    def test_ambiguous_registration_outcome_stops_without_retry_or_claiming_rollback(self):
        self.session.challenge()
        self.opener.open.side_effect = urllib.error.URLError("PRIVATE_RESPONSE_MUST_NOT_LEAK")
        with self.assertRaises(GateError) as failure:
            self.session.accept(self.proof)
        self.assertNotIn("PRIVATE_RESPONSE", str(failure.exception))
        self.assertTrue(self.session.unknown_outcome)
        self.assertTrue(self.session.fresh_verified)
        self.assertFalse(self.session.registration_verified)
        self.assertEqual(self.session.evidence()["directoryMetadataOperationsReserved"], 2)
        self.assertEqual(self.session.evidence()["directoryMetadataOperationsAcknowledged"], 1)
        with self.assertRaises(GateError):
            self.session.accept(self.proof)

    def test_cancel_during_verification_rejects_late_completion_without_registration(self):
        self.session.challenge()

        def cancel(*args, **kwargs):
            self.session.close()
            return Mock(returncode=0, stdout=json.dumps(self.authentication))

        self.verifier.side_effect = cancel
        with self.assertRaises(GateError):
            self.session.accept(self.proof)
        self.assertEqual(len(self.calls), 2)
        self.assertFalse(self.session.registration_verified)
        self.assertIsNone(self.session.token)

    def test_timeout_is_single_attempt_and_no_proof_file(self):
        self.session.challenge()
        self.verifier.side_effect = subprocess.TimeoutExpired("go", 60)
        with self.assertRaises(subprocess.TimeoutExpired):
            self.session.accept(self.proof)
        with self.assertRaises(GateError):
            self.session.accept(self.proof)
        self.assertEqual(len(self.calls), 2)
        self.assertFalse(self.session.registration_verified)

    def test_expired_proof_or_unexpected_raw_refresh_token_never_reaches_verifier(self):
        self.session.challenge()
        with self.assertRaises(GateError):
            self.session.accept({**self.proof, "refreshToken": "NEVER_PERSIST"})
        self.now += timedelta(seconds=300)
        with self.assertRaises(GateError):
            self.session.accept(self.proof)
        self.assertEqual(self.verifier.call_count, 1)

    def test_session_identity_mismatch_does_not_turn_registration_into_acceptance(self):
        self.session.challenge()
        self.responses[3]["principalId"] = "e" * 64
        with self.assertRaises(GateError):
            self.session.accept(self.proof)
        self.assertFalse(self.session.registration_verified)
        self.assertEqual(self.session.metadata_acknowledged, 2)

    def test_existing_registered_generation_is_correlated_without_resetting_ownership(self):
        self.session.challenge()
        self.responses[2]["identityGeneration"] = self.responses[3]["identityGeneration"] = 3
        self.session.accept(self.proof)
        self.assertTrue(self.session.registration_verified)
        self.assertEqual(len(self.calls), 4)

    def test_missing_identity_or_invalid_generation_never_passes_registration(self):
        for key, value in (("personalScopeId", None), ("currentIdentityId", ""),
                           ("identityGeneration", True), ("identityGeneration", 0),
                           ("identityGeneration", 10001)):
            self.session.state = "challenged"
            self.session.proof_checks = 0
            self.session.challenge_value = "a" * 64
            self.session.expires = self.now + timedelta(seconds=290)
            self.calls = [None, None]
            self.responses[2][key] = value
            self.responses[3][{"personalScopeId": "scopeId", "currentIdentityId": "identityId",
                               "identityGeneration": "identityGeneration"}[key]] = value
            with self.subTest(key=key, value=value), self.assertRaises(GateError):
                self.session.accept(self.proof)
            self.assertFalse(self.session.registration_verified)
            self.session.requests = self.session.metadata_reserved = self.session.metadata_acknowledged = 0
            self.responses[2] = {"accountId": "b" * 64, "personalScopeId": "c" * 64,
                                 "identityGeneration": 1, "currentIdentityId": "d" * 64}
            self.responses[3] = {"principalId": "b" * 64, "scopeId": "c" * 64, "identityGeneration": 1,
                                 "identityId": "d" * 64, "scopeMode": "user"}


if __name__ == "__main__":
    unittest.main()
