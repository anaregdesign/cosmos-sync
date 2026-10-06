from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import directory_azure_live as directory
from directory_hosting_contract import UNSUPPORTED_DIGESTS, UNSUPPORTED_SOURCES, assess_readback, config_digest, validate_hosting, verify_hosting
from directory_request_ledger import endpoint_digest, initialize
from hosted_azure_live import HostedControl
from live_azure_preflight import GateError
from native_entra_auth import private_input, private_json
import urllib.error
import urllib.request


class DirectoryHostingTests(unittest.TestCase):
    def setUp(self):
        self.config = {"development": False, "storage": "cosmos",
                       "authorization": {"mode": "directory", "directory": {"namespace": "approved-fixture"}}}
        self.hosting = {
            "appResourceId": "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/fixture/providers/Microsoft.App/containerApps/fixture-app",
            "image": "ghcr.io/anaregdesign/cosmos-sync-bff@sha256:" + "a" * 64,
            "sourceCommit": "a" * 40, "reviewedConfigurationSha256": config_digest(self.config),
        }
        self.app = {"id": self.hosting["appResourceId"], "state": "Succeeded", "mode": "Single",
                    "ready": "fixture-app--ready", "latest": "fixture-app--ready", "fqdn": "fixture.example",
                    "traffic": [{"latestRevision": True, "weight": 100}], "image": self.hosting["image"],
                    "environment": [{"name": "COSMOS_SYNC_CONFIG_JSON", "value": json.dumps(self.config)}]}
        self.revision = {"active": True, "state": "Provisioned", "health": "Healthy",
                         "image": self.hosting["image"], "environment": self.app["environment"]}

    def test_exact_compatible_healthy_readback_is_not_registry_or_graph_evidence(self):
        assess_readback(self.hosting, "https://fixture.example", self.config, self.app, self.revision)
        with patch("directory_hosting_contract.az_json", side_effect=[self.app, self.revision]) as azure:
            proof = verify_hosting(self.hosting, "https://fixture.example", self.config)
        self.assertTrue(proof["imageReadBack"])
        self.assertFalse(proof["registrySourceLabelsInspected"])
        self.assertFalse(proof["hostedGraphExecuted"])
        self.assertEqual(azure.call_count, 2)
        self.assertTrue(all(call.args[0][:4] == ["rest", "--method", "get", "--url"] for call in azure.call_args_list))

    def test_known_old_artifacts_cannot_be_relabeled_directory_capable(self):
        for source in UNSUPPORTED_SOURCES:
            with self.assertRaises(GateError):
                validate_hosting({**self.hosting, "sourceCommit": source})
        for digest in UNSUPPORTED_DIGESTS:
            with self.assertRaises(GateError):
                validate_hosting({**self.hosting, "image": "ghcr.io/anaregdesign/cosmos-sync-bff@" + digest})
        with self.assertRaises(GateError):
            validate_hosting({**self.hosting, "image": "ghcr.io/anaregdesign/cosmos-sync-bff:latest"})

    def test_different_environment_image_ready_revision_or_target_is_not_accepted(self):
        for change in ({"state": "Failed"}, {"mode": "Multiple"}, {"image": "other-image"},
                       {"id": None}, {"fqdn": None}, {"ready": None},
                       {"latest": "not-ready"}, {"fqdn": "other.example"}, {"traffic": []},
                       {"traffic": [None]}, {"environment": []},
                       {"environment": [{"name": "COSMOS_SYNC_CONFIG_JSON", "value": "{}"}]}):
            with self.subTest(change=change), self.assertRaises(GateError):
                assess_readback(self.hosting, "https://fixture.example", self.config,
                                {**self.app, **change}, self.revision)
        for value in ("invalid-json", "[]", '{"private":NaN}'):
            with self.subTest(environment=value), self.assertRaises((GateError, ValueError)):
                assess_readback(self.hosting, "https://fixture.example", self.config, self.app,
                                {**self.revision, "environment": [
                                    {"name": "COSMOS_SYNC_CONFIG_JSON", "value": value}]})
        with self.assertRaises(GateError):
            assess_readback(self.hosting, "https://fixture.example", self.config, self.app,
                            {**self.revision, "active": False})


class DirectoryManifestTests(unittest.TestCase):
    def manifest(self):
        path = Path(__file__).resolve().parents[1] / "ops/azure/directory-validation.example.json"
        value = json.loads(path.read_text())
        value.update(targetApprovalReference="synthetic-target", liveWriteApprovalReference="synthetic-write",
                     testDataRetentionAcknowledged=True)
        return value

    def test_explicit_directory_mode_and_separated_budget_never_accept_builtin(self):
        value = self.manifest()
        directory.validate_manifest(value)
        for key, field in (("authorizationMode", "builtin"), ("authenticationMode", "fresh-login"),
                           ("schemaVersion", True), ("replicas", 2), ("liveWriteApprovalReference", "")):
            with self.subTest(key=key), self.assertRaises(GateError):
                directory.validate_manifest({**value, key: field})
        for key, field in (("maxDirectoryMetadataOperations", 1), ("maxFreshProofChecks", 1),
                           ("maxMutationAttempts", 5), ("maxAcceptedAppMutations", 4),
                           ("maxProtocolRequests", 24),
                           ("maxProtocolRequests", True)):
            with self.subTest(key=key), self.assertRaises(GateError):
                directory.validate_manifest({**value, "budget": {**value["budget"], key: field}})

    def test_previous_api_only_or_dirty_fixture_receipt_cannot_become_fresh_directory_proof(self):
        manifest = self.manifest()
        manifest["accessTokenFile"] = "/absolute/private/native-directory-run/initial.jwt"
        proof = {
            "schemaVersion": 2, "status": "passed", "cleanupComplete": True, "actualNativeAppAuth": True,
            "ownerInitiatedForegroundSignIn": True,
            "sourceSha": manifest["hosting"]["sourceCommit"], "sourceTreeDirty": False,
            "serverChallengeProvenanceVerified": True, "freshIdentityProofVerified": True,
            "directoryRegistrationVerified": True, "rawFreshProofPersisted": False,
            "directoryWriteOutcomeUnknown": False,
            "directoryConfigurationSha256": manifest["hosting"]["reviewedConfigurationSha256"],
            "directoryEndpointSha256": endpoint_digest(manifest["endpoint"]),
            "directoryHostingCandidateSha256": config_digest(manifest["hosting"]),
            "aggregateProtocolRequestsObservedAtLastReservation": 11,
            "completedAtUtc": datetime.now(timezone.utc).isoformat(),
        }
        directory.validate_prior_proof(manifest, proof)
        for key, value in (("sourceTreeDirty", True), ("freshIdentityProofVerified", False),
                           ("directoryRegistrationVerified", False), ("rawFreshProofPersisted", True),
                           ("ownerInitiatedForegroundSignIn", False),
                           ("aggregateProtocolRequestsObservedAtLastReservation", 0),
                           ("directoryEndpointSha256", "b" * 64),
                           ("directoryHostingCandidateSha256", "b" * 64),
                           ("sourceSha", "b" * 40), ("serverChallengeProvenanceVerified", False)):
            with self.subTest(key=key), self.assertRaises(GateError):
                directory.validate_prior_proof(manifest, {**proof, key: value})
        for value in (None, [], "invalid", {**proof, "schemaVersion": 2.0}):
            with self.subTest(shape=value), self.assertRaises(GateError):
                directory.validate_prior_proof(manifest, value)
        for stamp in (None, 123, "invalid", "2020-01-01T00:00:00Z"):
            with self.subTest(stamp=stamp), self.assertRaises(GateError):
                directory.validate_prior_proof(manifest, {**proof, "completedAtUtc": stamp})

    def test_early_manifest_failure_creates_new_redacted_receipt_without_azure_or_token_reads(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bad = root / "invalid.json"
            private_json(bad, {"SECRET_SHOULD_NOT_APPEAR": "PRIVATE_INPUT"})
            with patch.object(directory, "ROOT", root), patch.object(directory, "verify_hosting") as hosting:
                with self.assertRaises(GateError):
                    directory.execute(bad)
            hosting.assert_not_called()
            latest = private_input(root / ".cache/directory-azure-live/latest.local.json")
            report = private_input(Path(latest["runDirectory"]) / "proof.json")
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["failureStage"], "manifest_preflight")
            self.assertEqual(report["protocolRequests"], 0)
            self.assertTrue(report["cleanupComplete"])
            self.assertNotIn("SECRET", json.dumps(report))

    def test_directory_gets_are_counted_but_identity_writes_are_not_hidden_in_data_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            ledger_path = Path(temporary) / "ledger.json"
            initialize(ledger_path, "https://fixture.example", 39)
            ledger = directory.DirectoryRequestLedger(ledger_path, "https://fixture.example")
            control = HostedControl({"endpoint": "https://fixture.example"}, stages=directory.DIRECTORY_STAGES,
                                    get_paths=directory.DIRECTORY_GET_PATHS, request_ledger=ledger)
            control.start()
            try:
                def permit(method, path):
                    body = {"method": method, "path": path, "origin": "https://fixture.example"}
                    request = urllib.request.Request(control.url + "permit", data=json.dumps(body).encode())
                    try:
                        with urllib.request.urlopen(request, timeout=2) as response:
                            return response.status
                    except urllib.error.HTTPError as error:
                        with error:
                            return error.code

                self.assertEqual(permit("POST", "/v1/identity/register"), 400)
                self.assertEqual(permit("POST", "/v1/identity/challenges"), 400)
                self.assertEqual(permit("GET", "/v1/identity/capabilities"), 200)
                self.assertEqual(permit("GET", "/v1/identities"), 429)
                self.assertEqual(control.requests, 1)
                self.assertEqual(ledger.read()["protocolRequests"], 40)
            finally:
                control.close()

    def execution_inputs(self, root, *, ledger_history=11):
        manifest = self.manifest()
        for key, name in (("runtimeConfigFile", "runtime.json"), ("aggregateLedgerFile", "ledger.json"),
                          ("nativeProofFile", "native-proof.json"), ("ownerFile", "owner.json"),
                          ("receiptFile", "receipt.json")):
            manifest[key] = str(root / name)
        manifest["accessTokenFile"] = str(root / "initial.jwt")
        config = {
            "storage": "cosmos", "development": False,
            "oidc": {"issuer": "https://fixture.ciamlogin.com/fixture/v2.0", "audience": "api-client",
                     "allowedClientIds": ["public-client"]},
            "authorization": {"mode": "directory", "directory": {
                "namespace": "approved-fixture", "callbacks": ["com.example.app://auth/callback"]}},
        }
        manifest["hosting"]["reviewedConfigurationSha256"] = config_digest(config)
        private_json(Path(manifest["runtimeConfigFile"]), config)
        private_json(Path(manifest["receiptFile"]), {
            "oidc": config["oidc"], "native": {"appId": "public-client"},
            "nativeConfig": {"redirectUrl": "com.example.app://auth/callback"}})
        private_json(Path(manifest["nativeProofFile"]), {
            "schemaVersion": 2, "status": "passed", "cleanupComplete": True, "actualNativeAppAuth": True,
            "ownerInitiatedForegroundSignIn": True, "sourceSha": manifest["hosting"]["sourceCommit"],
            "sourceTreeDirty": False, "serverChallengeProvenanceVerified": True,
            "freshIdentityProofVerified": True, "directoryRegistrationVerified": True,
            "rawFreshProofPersisted": False, "directoryWriteOutcomeUnknown": False,
            "directoryConfigurationSha256": config_digest(config),
            "directoryEndpointSha256": endpoint_digest(manifest["endpoint"]),
            "directoryHostingCandidateSha256": config_digest(manifest["hosting"]),
            "aggregateProtocolRequestsObservedAtLastReservation": 11,
            "completedAtUtc": datetime.now(timezone.utc).isoformat(),
        })
        initialize(Path(manifest["aggregateLedgerFile"]), manifest["endpoint"], ledger_history)
        path = root / "manifest.json"
        private_json(path, manifest)
        return path, manifest

    def test_aggregate_history_cannot_be_reset_after_the_attended_proof(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path, manifest = self.execution_inputs(root, ledger_history=7)
            with patch.object(directory, "ROOT", root), patch.object(
                    directory, "source_state", return_value={
                        "sourceSha": manifest["hosting"]["sourceCommit"], "sourceTreeDirty": False}), patch.object(
                    directory, "verify_hosting") as hosting, patch.object(directory, "verify_token") as token:
                with self.assertRaises(GateError):
                    directory.execute(path)
            hosting.assert_not_called()
            token.assert_not_called()
            latest = private_input(root / ".cache/directory-azure-live/latest.local.json")
            report = private_input(Path(latest["runDirectory"]) / "proof.json")
            self.assertEqual(report["failureStage"], "aggregate_budget_preflight")
            self.assertEqual(report["protocolRequests"], 0)
            self.assertTrue(report["cleanupComplete"])

    def test_success_and_ambiguous_partial_receipts_preserve_counts_and_owned_cleanup(self):
        for complete in (True, False):
            with self.subTest(complete=complete), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                path, manifest = self.execution_inputs(root)
                control = Mock(requests=0, accepted=0, conflicts=0, mutation_attempts=0,
                               pending_attempt=None, unknown_outcome=False, aggregate_requests=11, stages=[])

                def run_sdk(timeout):
                    self.assertEqual(timeout, 120)
                    control.requests = 25 if complete else 10
                    ledger = directory.DirectoryRequestLedger(manifest["aggregateLedgerFile"], manifest["endpoint"])
                    for _ in range(control.requests):
                        control.aggregate_requests = ledger.reserve()["protocolRequests"]
                    control.accepted = 3 if complete else 1
                    control.conflicts = int(complete)
                    control.mutation_attempts = 4 if complete else 2
                    control.stages = list(directory.DIRECTORY_STAGES if complete else directory.DIRECTORY_STAGES[:6])
                    control.unknown_outcome = not complete
                    control.pending_attempt = None if complete else 2

                process = Mock(returncode=0 if complete else 1)
                process.wait.side_effect = run_sdk
                with patch.object(directory, "ROOT", root), patch.object(
                        directory, "source_state", return_value={
                            "sourceSha": manifest["hosting"]["sourceCommit"], "sourceTreeDirty": False}), patch.object(
                        directory, "verify_hosting", return_value={"hostedGraphExecuted": False}), patch.object(
                        directory, "verify_token", return_value="RECORDED.API.FIXTURE"), patch.object(
                        directory, "HostedControl", return_value=control), patch.object(
                        directory.subprocess, "Popen", return_value=process), patch.object(
                        directory, "stop_owned_process") as stop:
                    if complete:
                        report = directory.execute(path)
                        self.assertEqual(report["status"], "passed")
                    else:
                        with self.assertRaises(GateError):
                            directory.execute(path)
                stop.assert_called_once_with(process)
                control.close.assert_called_once_with()
                latest = private_input(root / ".cache/directory-azure-live/latest.local.json")
                report = private_input(Path(latest["runDirectory"]) / "proof.json")
                self.assertEqual(report["status"], "passed" if complete else "failed")
                self.assertEqual(report["knownAcceptedMutationResponses"], 3 if complete else 1)
                self.assertEqual(report["mutationAttempts"], 4 if complete else 2)
                self.assertEqual(report["unknownOutcome"], not complete)
                self.assertEqual(report["hostedGraphExecuted"], complete)
                self.assertTrue(report["cleanupComplete"])
                self.assertNotIn("RECORDED", json.dumps(report))

    def test_sdk_timeout_records_partial_failure_and_closes_owned_control(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path, manifest = self.execution_inputs(root)
            control = Mock(requests=3, accepted=0, conflicts=0, mutation_attempts=0,
                           pending_attempt=None, unknown_outcome=False, aggregate_requests=14, stages=[])
            process = Mock()
            process.wait.side_effect = subprocess.TimeoutExpired("dart", 120)
            with patch.object(directory, "ROOT", root), patch.object(
                    directory, "source_state", return_value={
                        "sourceSha": manifest["hosting"]["sourceCommit"], "sourceTreeDirty": False}), patch.object(
                    directory, "verify_hosting", return_value={"hostedGraphExecuted": False}), patch.object(
                    directory, "verify_token", return_value="RECORDED.API.FIXTURE"), patch.object(
                    directory, "HostedControl", return_value=control), patch.object(
                    directory.subprocess, "Popen", return_value=process), patch.object(
                    directory, "stop_owned_process") as stop:
                with self.assertRaises(subprocess.TimeoutExpired):
                    directory.execute(path)
            stop.assert_called_once_with(process)
            control.close.assert_called_once_with()
            latest = private_input(root / ".cache/directory-azure-live/latest.local.json")
            report = private_input(Path(latest["runDirectory"]) / "proof.json")
            self.assertEqual(report["failureStage"], "sdk_runtime")
            self.assertEqual(report["protocolRequests"], 3)
            self.assertTrue(report["cleanupComplete"])


if __name__ == "__main__":
    unittest.main()
