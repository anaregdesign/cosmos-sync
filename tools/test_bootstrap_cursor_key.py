"""Offline target, durability and secret-leakage tests; never contact Azure."""

import base64
import contextlib
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import bootstrap_cursor_key as m

SID = "11111111-1111-1111-1111-111111111111"
TID = "22222222-2222-2222-2222-222222222222"
VID = f"/subscriptions/{SID}/resourceGroups/example-validation/providers/Microsoft.KeyVault/vaults/example-cursor-vault"
SECRET_ID = VID + "/secrets/" + m.SECRET_NAME
URI = "https://example-cursor-vault.vault.azure.net/secrets/" + m.SECRET_NAME + "/" + "a" * 32
KEY = b"OFFLINE_ONLY_32_BYTE_CANARY_KEY".ljust(32, b"!")
ENCODED = base64.b64encode(KEY).decode()
TOKEN = "OFFLINE_ONLY_BEARER_CANARY." + "x" * 160


def inputs():
    attrs = {"id": VID, "name": "example-cursor-vault", "tenant_id": TID, "location": "westus2",
             "public_network_access_enabled": False, "rbac_authorization_enabled": True,
             "purge_protection_enabled": True, "sku_name": "standard", "soft_delete_retention_days": 90,
             "enabled_for_deployment": False, "enabled_for_disk_encryption": False,
             "enabled_for_template_deployment": False, "tags": dict(m.OWNER_TAGS)}
    state = {"version": 4, "resources": [{"mode": "managed", "type": "azurerm_key_vault", "name": "cursor",
              "instances": [{"attributes": attrs}]}]}
    state_digest = hashlib.sha256(json.dumps(state).encode()).hexdigest()
    config = {"schemaVersion": 1, "vault": {"resourceId": VID, "tenantId": TID, "location": "westus2"},
              "terraformState": {"resourceAddress": m.RESOURCE_ADDRESS, "sha256": state_digest,
                                 "provenance": "immutable-copy-after-reviewed-prerequisite-apply"}}
    live = {"id": VID, "name": "example-cursor-vault", "location": "westus2", "tags": dict(m.OWNER_TAGS),
            "properties": {"tenantId": TID, "provisioningState": "Succeeded", "publicNetworkAccess": "Disabled",
                           "enableRbacAuthorization": True, "enablePurgeProtection": True,
                           "sku": {"family": "A", "name": "standard"}, "softDeleteRetentionInDays": 90,
                           "enableSoftDelete": True, "enabledForDeployment": False,
                           "enabledForDiskEncryption": False, "enabledForTemplateDeployment": False,
                           "networkAcls": {"bypass": "None", "defaultAction": "Deny", "ipRules": [], "virtualNetworkRules": []},
                           "vaultUri": "https://example-cursor-vault.vault.azure.net/"}}
    return config, state, state_digest, live


class FakeTransport:
    def __init__(self, responses):
        self.responses, self.calls = list(responses), []

    def request(self, method, resource_id, token, payload=None):
        self.calls.append((method, resource_id, token, payload))
        result = self.responses.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.root_patch = patch.object(m, "ATTEMPT_ROOT", self.folder / "receipts")
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.config, self.state, self.state_digest, self.live = inputs()
        self.target = m.target_from_inputs(self.config, self.state, self.state_digest)
        self.random_calls = 0

    def random(self, count):
        self.random_calls += 1
        self.assertEqual(count, 32)
        return KEY

    def initialize(self, transport):
        return m.initialize(self.target, "owner-approved-bootstrap", "0" * 64, self.state_digest,
                            transport, lambda target: TOKEN, self.random, sole_writer=True)

    def responses(self, final=None):
        return [(200, self.live), (404, {"error": {"code": "SecretNotFound"}}),
                final or (201, {"id": SECRET_ID, "properties": {"secretUriWithVersion": URI, "value": ENCODED}})]

    def receipt(self):
        return json.loads(m.metadata_path(self.target).read_text())

    def assert_no_leak(self):
        for path in m.ATTEMPT_ROOT.glob("*"):
            if path.is_file():
                contents = path.read_text()
                for value in (TOKEN, ENCODED, KEY.decode(), '"value"', '"accessToken"'):
                    self.assertNotIn(value, contents)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_default_is_offline_without_cli_network_randomness_or_files(self):
        with patch.object(m, "ArmTransport") as transport, patch.object(m, "ExistingCliToken") as token, \
                patch.object(m, "private_json") as reading, patch.object(m.secrets, "token_bytes") as random:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(m.main([]), 0)
            self.assertEqual(json.loads(output.getvalue())["mode"], "offline")
            for mocked in (transport, token, reading, random):
                mocked.assert_not_called()
        self.assertFalse(m.ATTEMPT_ROOT.exists())

    def test_offline_plan_hashes_exact_raw_state_and_does_not_write(self):
        config_path, state_path = self.folder / "config.json", self.folder / "state.json"
        for path, value in ((config_path, self.config), (state_path, self.state)):
            path.write_text(json.dumps(value))
            path.chmod(0o600)
        with patch.object(m, "ArmTransport") as transport, patch.object(m, "ExistingCliToken") as token:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(m.main(["--plan", "--config", str(config_path), "--state", str(state_path)]), 0)
            self.assertTrue(json.loads(output.getvalue())["reviewedStateMatched"])
            transport.assert_not_called()
            token.assert_not_called()
        self.assertFalse(m.ATTEMPT_ROOT.exists())

    def test_example_placeholders_cannot_initialize_a_real_target(self):
        config = json.loads((m.ROOT / "ops/azure/cursor-bootstrap.example.json").read_text())
        with self.assertRaises(m.GateError):
            m.target_from_inputs(config, self.state, self.state_digest)

    def test_reviewed_immutable_hash_and_raw_state_provenance_are_required(self):
        for key, value in (("sha256", "f" * 64), ("resourceAddress", "module.other.azurerm_key_vault.cursor"),
                           ("provenance", "unreviewed-import")):
            with self.subTest(key=key):
                changed = copy.deepcopy(self.config)
                changed["terraformState"][key] = value
                with self.assertRaises(m.GateError):
                    m.target_from_inputs(changed, self.state, self.state_digest)
        with self.assertRaises(m.GateError):
            m.target_from_inputs(self.config, {"format_version": "1.0", "values": {}}, self.state_digest)

    def test_other_vault_tenant_location_and_subscription_are_rejected(self):
        for key, value in (("resourceId", VID.replace(SID, TID)), ("resourceId", VID.replace("example-validation", "unrelated")),
                           ("tenantId", SID), ("location", "eastus")):
            with self.subTest(key=key):
                changed = copy.deepcopy(self.config)
                changed["vault"][key] = value
                with self.assertRaises(m.GateError):
                    m.target_from_inputs(changed, self.state, self.state_digest)

    def test_unrelated_multiple_tainted_or_indexed_state_is_rejected(self):
        for mutate in (lambda r: r.update(name="other"), lambda r: r.update(module="module.other"),
                       lambda r: r["instances"].append(copy.deepcopy(r["instances"][0])),
                       lambda r: r["instances"][0].update(status="tainted"),
                       lambda r: r["instances"][0].update(index_key="other")):
            changed = copy.deepcopy(self.state)
            mutate(changed["resources"][0])
            with self.assertRaises(m.GateError):
                m.target_from_inputs(self.config, changed, self.state_digest)

    def test_state_security_envelope_and_tags_are_required(self):
        for key, value in (("public_network_access_enabled", True), ("rbac_authorization_enabled", False),
                           ("purge_protection_enabled", False), ("sku_name", "premium"),
                           ("soft_delete_retention_days", 7), ("enabled_for_template_deployment", True),
                           ("tags", {"managed_by": "unrelated"})):
            changed = copy.deepcopy(self.state)
            changed["resources"][0]["instances"][0]["attributes"][key] = value
            with self.assertRaises(m.GateError):
                m.target_from_inputs(self.config, changed, self.state_digest)

    def test_private_input_rejects_public_mode_symlinks_and_oversize(self):
        path = self.folder / "private.json"
        path.write_text("{}")
        path.chmod(0o644)
        with self.assertRaises(m.GateError):
            m.private_json(path)
        path.chmod(0o600)
        self.assertEqual(m.private_json(path)[0], {})
        link = self.folder / "link.json"
        link.symlink_to(path)
        with self.assertRaises(OSError):
            m.private_json(link)
        with path.open("wb") as stream:
            stream.truncate(20 * m.MAX_RESPONSE + 1)
        with self.assertRaises(m.GateError):
            m.private_json(path)

    def test_duplicate_keys_and_nonfinite_json_are_rejected(self):
        for raw in ('{"vault":1,"vault":2}', '{"nested":{"tenant":1,"tenant":2}}',
                    '{"value":NaN}', '{"value":Infinity}', '{"value":-Infinity}', '{"value":1e400}', '{"value":-1e400}'):
            with self.subTest(raw=raw):
                with self.assertRaises(m.GateError):
                    m.decode_json(raw)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO boundary applies to Unix platforms")
    def test_fifo_input_and_lock_are_rejected_without_waiting_for_a_writer(self):
        fifo = self.folder / "input.fifo"
        os.mkfifo(fifo, 0o600)
        with self.assertRaisesRegex(m.GateError, "private_input_required"):
            m.private_json(fifo)
        m.ensure_receipt_directory()
        lock_fifo = m.metadata_path(self.target).with_suffix(".lock")
        os.mkfifo(lock_fifo, 0o600)
        with self.assertRaisesRegex(m.GateError, "private_lock_required"):
            with m.target_lock(self.target):
                self.fail("A FIFO cannot be used as the target lock")

    def test_boolean_schema_and_raw_state_versions_are_not_integer_versions(self):
        changed = copy.deepcopy(self.config)
        changed["schemaVersion"] = True
        with self.assertRaises(m.GateError):
            m.target_from_inputs(changed, self.state, self.state_digest)
        changed_state = copy.deepcopy(self.state)
        changed_state["version"] = True
        with self.assertRaises(m.GateError):
            m.target_from_inputs(self.config, changed_state, self.state_digest)

    def test_config_cannot_accept_secret_value_or_unreviewed_fields(self):
        for section, field in ((None, "accessToken"), ("vault", "value"), ("terraformState", "secretValue")):
            changed = copy.deepcopy(self.config)
            (changed[section] if section else changed)[field] = ENCODED
            with self.assertRaises(m.GateError):
                m.target_from_inputs(changed, self.state, self.state_digest)

    def test_success_is_one_exact_put_without_persisting_key_token_or_response(self):
        transport = FakeTransport(self.responses())
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = self.initialize(transport)
        self.assertEqual(result["mode"], "bootstrap-complete")
        self.assertEqual(output.getvalue(), "")
        self.assertEqual([(c[0], c[1]) for c in transport.calls], [("GET", VID), ("GET", SECRET_ID), ("PUT", SECRET_ID)])
        self.assertEqual(json.loads(transport.calls[2][3]), {"properties": {"value": ENCODED}})
        self.assertEqual(self.receipt()["versionedSecretUri"], URI)
        self.assertEqual(self.receipt()["keySha256"], hashlib.sha256(KEY).hexdigest())
        self.assertEqual(self.random_calls, 1)
        self.assert_no_leak()

    def test_existing_key_is_not_overwritten_or_generated(self):
        transport = FakeTransport([(200, self.live), (200, {"properties": {"value": ENCODED}})])
        with self.assertRaisesRegex(m.GateError, "already_exists"):
            self.initialize(transport)
        self.assertEqual(self.random_calls, 0)
        self.assertEqual(len(transport.calls), 2)
        self.assert_no_leak()

    def test_existing_key_reuse_is_only_two_metadata_gets(self):
        transport = FakeTransport([(200, self.live), (200, {"id": SECRET_ID, "properties": {"secretUriWithVersion": URI, "value": ENCODED}})])
        with patch.object(m.secrets, "token_bytes") as random:
            result = m.reuse_existing(self.target, "0" * 64, self.state_digest, transport, lambda target: TOKEN)
            random.assert_not_called()
        self.assertEqual(result["mutations"], 0)
        self.assertFalse(result["keyGenerated"])
        self.assertEqual([c[0] for c in transport.calls], ["GET", "GET"])
        self.assertEqual(json.loads(m.metadata_path(self.target, "reuse").read_text())["versionedSecretUri"], URI)
        self.assertFalse(m.metadata_path(self.target).exists())
        self.assert_no_leak()

    def test_reuse_of_wrong_version_uri_fails_without_any_write(self):
        transport = FakeTransport([(200, self.live), (200, {"id": SECRET_ID, "properties": {"secretUriWithVersion": URI + "?x=1"}})])
        with self.assertRaises(m.GateError):
            m.reuse_existing(self.target, "0" * 64, self.state_digest, transport, lambda target: TOKEN)
        self.assertEqual([c[0] for c in transport.calls], ["GET", "GET"])
        self.assertFalse(m.metadata_path(self.target, "reuse").exists())

    def test_absence_requires_a_known_404_and_never_retries_unknown(self):
        for response in ((403, {"error": {"code": "Forbidden"}}), (404, {"error": {"code": "OtherFailure"}}), (404, {})):
            with self.subTest(response=response):
                m.metadata_path(self.target).unlink(missing_ok=True)
                transport = FakeTransport([(200, self.live), response])
                with self.assertRaises(m.GateError):
                    self.initialize(transport)
                self.assertEqual(self.random_calls, 0)
                self.assertEqual(len(transport.calls), 2)
                self.assert_no_leak()

    def test_live_vault_target_security_tags_and_retrieval_are_checked(self):
        changes = [(None, "id", VID.replace(SID, TID)), (None, "name", "different"), (None, "location", "eastus"),
                   ("properties", "tenantId", SID), ("properties", "publicNetworkAccess", "Enabled"),
                   ("properties", "enableRbacAuthorization", False), ("properties", "provisioningState", "Creating"),
                   ("properties", "sku", {"family": "A", "name": "premium"}), ("properties", "softDeleteRetentionInDays", 7),
                   ("properties", "enablePurgeProtection", False), ("properties", "enableSoftDelete", False),
                   ("properties", "enabledForDeployment", True), ("properties", "enabledForDiskEncryption", True),
                   ("properties", "enabledForTemplateDeployment", True), ("tags", "retention", "delete")]
        for parent, key, value in changes:
            with self.subTest(key=key):
                m.metadata_path(self.target).unlink(missing_ok=True)
                changed = copy.deepcopy(self.live)
                (changed[parent] if parent else changed)[key] = value
                transport = FakeTransport([(200, changed)])
                with self.assertRaises(m.GateError):
                    self.initialize(transport)
                self.assertEqual(len(transport.calls), 1)
                self.assertEqual(self.random_calls, 0)

    def test_live_network_exceptions_are_rejected(self):
        for key, value in (("bypass", "AzureServices"), ("defaultAction", "Allow"),
                           ("ipRules", [{"value": "192.0.2.1/32"}]), ("virtualNetworkRules", [{"id": "synthetic"}])):
            m.metadata_path(self.target).unlink(missing_ok=True)
            changed = copy.deepcopy(self.live)
            changed["properties"]["networkAcls"][key] = value
            with self.assertRaises(m.GateError):
                self.initialize(FakeTransport([(200, changed)]))
            self.assertEqual(self.random_calls, 0)

    def test_bad_version_or_response_id_is_ambiguous_after_put(self):
        for uri in (URI.rsplit("/", 1)[0], URI + "?x=1", URI.replace("example-cursor-vault", "different"),
                    URI.replace(m.SECRET_NAME, "different"), URI.replace("https:", "http:")):
            m.metadata_path(self.target).unlink(missing_ok=True)
            transport = FakeTransport(self.responses((200, {"id": SECRET_ID, "properties": {"secretUriWithVersion": uri}})))
            with self.assertRaises(m.GateError):
                self.initialize(transport)
            self.assertEqual(self.receipt()["phase"], "put_ambiguous_do_not_retry")
            self.assertNotIn("versionedSecretUri", self.receipt())
        m.metadata_path(self.target).unlink()
        with self.assertRaises(m.GateError):
            self.initialize(FakeTransport(self.responses((200, {"id": SECRET_ID + "-other", "properties": {"secretUriWithVersion": URI}}))))

    def test_durable_prewrite_receipt_precedes_put_and_fences_uncertain_outcome(self):
        outer = self
        class Uncertain(FakeTransport):
            def request(self, method, resource_id, token, payload=None):
                if method == "PUT":
                    outer.assertEqual(outer.receipt()["phase"], "put_started")
                    outer.assert_no_leak()
                return super().request(method, resource_id, token, payload)
        transport = Uncertain(self.responses(m.GateError("arm_transport_failed")))
        with self.assertRaises(m.GateError):
            self.initialize(transport)
        self.assertEqual(self.receipt()["phase"], "put_ambiguous_do_not_retry")
        second = FakeTransport([])
        with self.assertRaisesRegex(m.GateError, "prior_attempt_exists"):
            self.initialize(second)
        self.assertEqual(second.calls, [])
        self.assertEqual(self.random_calls, 1)

    def test_directory_fsync_failure_before_put_stops_without_a_write(self):
        real_sync = m.sync_directory
        failed = False
        def fail_prewrite(directory):
            nonlocal failed
            path = m.metadata_path(self.target)
            if not failed and path.exists() and json.loads(path.read_text()).get("phase") == "put_started":
                failed = True
                raise OSError("offline durability failure")
            return real_sync(directory)
        transport = FakeTransport(self.responses())
        with patch.object(m, "sync_directory", side_effect=fail_prewrite):
            with self.assertRaises(m.GateError):
                self.initialize(transport)
        self.assertTrue(failed)
        self.assertEqual([c[0] for c in transport.calls], ["GET", "GET"])
        self.assertEqual(self.receipt()["phase"], "put_ambiguous_do_not_retry")

    def test_completed_receipt_fsync_failure_is_post_put_ambiguous(self):
        real_sync = m.sync_directory
        failed = False
        def fail_complete(directory):
            nonlocal failed
            path = m.metadata_path(self.target)
            if not failed and path.exists() and json.loads(path.read_text()).get("phase") == "complete":
                failed = True
                raise OSError("offline completion failure")
            return real_sync(directory)
        transport = FakeTransport(self.responses())
        with patch.object(m, "sync_directory", side_effect=fail_complete):
            with self.assertRaises(m.GateError):
                self.initialize(transport)
        self.assertEqual([c[0] for c in transport.calls].count("PUT"), 1)
        self.assertEqual(self.receipt()["phase"], "put_ambiguous_do_not_retry")
        self.assert_no_leak()

    def test_same_target_lock_blocks_concurrent_initializer_before_network(self):
        with m.target_lock(self.target):
            second = FakeTransport([])
            with self.assertRaisesRegex(m.GateError, "another_initializer"):
                self.initialize(second)
            self.assertEqual(second.calls, [])

    def test_case_variants_have_one_fixed_receipt_without_config_path_input(self):
        changed = dict(self.target, id=self.target["id"].upper())
        self.assertEqual(m.metadata_path(self.target), m.metadata_path(changed))
        self.assertEqual(m.metadata_path(self.target).parent, m.ATTEMPT_ROOT)

    def test_single_writer_and_authority_are_required_before_network(self):
        transport = FakeTransport([])
        with self.assertRaisesRegex(m.GateError, "single_designated_writer"):
            m.initialize(self.target, "owner-authority", "0" * 64, self.state_digest, transport, lambda target: TOKEN)
        with self.assertRaisesRegex(m.GateError, "approval_reference"):
            m.initialize(self.target, "", "0" * 64, self.state_digest, transport, lambda target: TOKEN, sole_writer=True)
        self.assertEqual(transport.calls, [])

    def test_secret_fields_cannot_be_saved_in_receipts(self):
        m.ensure_receipt_directory()
        for key in ("value", "accessToken", "body", "response", "secret_value"):
            with self.assertRaisesRegex(m.GateError, "unsafe_receipt"):
                m.save_receipt(m.metadata_path(self.target), {key: ENCODED})

    def test_arm_transport_blocks_other_targets_and_tls_redirects(self):
        transport = m.ArmTransport()
        with patch.object(transport.opener, "open") as opening:
            for resource_id in (SECRET_ID + "-other", VID, VID + "/secrets/../else", VID + "?evil=1"):
                with self.assertRaises(m.GateError):
                    transport.request("PUT", resource_id, TOKEN, b"canary")
            opening.assert_not_called()
        self.assertIsNone(m.NoRedirect().redirect_request(None, None, 307, "redirect", {}, "https://example.invalid"))

    def test_cli_uses_existing_profile_no_login_no_context_change_and_no_file_logging(self):
        token = {"subscription": SID, "tenant": TID, "tokenType": "Bearer", "expires_on": time.time() + 600, "accessToken": TOKEN}
        current = {"id": "existing-default", "tenantId": "existing-default-tenant"}
        results = [subprocess.CompletedProcess([], 0, json.dumps(v).encode(), ENCODED.encode()) for v in (current, token, current)]
        provider = m.ExistingCliToken(self.folder)
        output = io.StringIO()
        with patch.object(m.subprocess, "run", side_effect=results) as run, contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.assertEqual(provider(self.target), TOKEN)
        self.assertEqual(output.getvalue(), "")
        argv = [call.args[0] for call in run.call_args_list]
        self.assertEqual([args[1:3] for args in argv], [["account", "show"], ["account", "get-access-token"], ["account", "show"]])
        self.assertNotIn("--tenant", argv[1])
        self.assertNotIn(TOKEN, repr(argv))
        for call in run.call_args_list:
            self.assertEqual(call.kwargs["env"]["AZURE_LOGGING_ENABLE_LOG_FILE"], "no")
            self.assertTrue(call.kwargs["capture_output"])

    def test_cli_changed_context_wrong_tenant_and_expiry_are_rejected(self):
        provider = m.ExistingCliToken(self.folder)
        current = {"id": "same", "tenantId": "same"}
        token = {"subscription": SID, "tenant": TID, "tokenType": "Bearer", "expires_on": time.time() + 600, "accessToken": TOKEN}
        for changed, after in ((dict(token, tenant=SID), current), (dict(token, subscription=TID), current),
                               (dict(token, expires_on=0), current), (dict(token, expires_on="inf"), current),
                               (token, {"id": "changed"})):
            with patch.object(provider, "command", side_effect=[current, changed, after]):
                with self.assertRaises(m.GateError):
                    provider(self.target)


if __name__ == "__main__":
    unittest.main()
