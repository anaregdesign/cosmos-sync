"""Guarded resource-plan tests; every Azure CLI and identity action is mocked."""

import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import azure_verification_environment as environment
import live_azure_preflight as preflight
import test_live_azure_tools as existing_tools


class EnvironmentTest(unittest.TestCase):
    def fixture(self):
        source = existing_tools.ToolsTest()
        source.setUp()
        value = source.approved_manifest()
        value["fixtureMode"] = "single-account"
        value["testPrincipals"] = {"writer": value["testPrincipals"]["writer"]}
        value["provisioning"] = {"approvalReference": "fixture-exact-target-network-role-approval",
                                 "region": "eastus", "egressIpv4": "8.8.4.4",
                                 "dataPrincipalObjectId": "33333333-3333-4333-8333-333333333333",
                                 "billingMode": "free-tier-preferred", "retentionPolicy": "retain-for-reuse",
                                 "teardownApprovalReference": ""}
        return value

    def account(self, manifest, *, serverless=False):
        return {"name": manifest["azure"]["account"], "tags": environment.expected_tags(manifest),
                "kind": "GlobalDocumentDB", "provisioningState": "Succeeded",
                "consistencyPolicy": {"defaultConsistencyLevel": "Session"},
                "enableMultipleWriteLocations": False, "disableLocalAuth": True,
                "locations": [{"locationName": "East US", "isZoneRedundant": False}],
                "ipRules": [{"ipAddressOrRange": manifest["provisioning"]["egressIpv4"]}],
                "publicNetworkAccess": "Enabled", "networkAclBypass": "None", "minimalTlsVersion": "Tls12",
                "backupPolicy": {"type": "Continuous", "continuousModeProperties": {"tier": "Continuous7Days"}},
                "enableFreeTier": not serverless,
                "capabilities": [{"name": "EnableServerless"}] if serverless else []}

    def test_default_plan_never_calls_cli_or_reads_identity(self):
        path = environment.ROOT / "ops/azure/environment.single-account.example.json"
        with patch("sys.argv", ["environment", "--manifest", str(path)]), patch.object(environment, "az") as cli, \
                patch.object(environment, "check_cli_default") as context, patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertEqual(environment.main(), 0)
            cli.assert_not_called()
            context.assert_not_called()
            self.assertFalse(json.loads(output.getvalue())["resourcesModified"])

    def test_create_rejects_missing_approval_cost_and_example_network_before_cli(self):
        changes = ({"approvalReference": ""}, {"egressIpv4": "0.0.0.0"}, {"egressIpv4": "198.51.100.1"},
                   {"dataPrincipalObjectId": "00000000-0000-0000-0000-000000000000"})
        for change in changes:
            value = self.fixture()
            value["provisioning"].update(change)
            with self.subTest(change=change), patch.object(environment, "az") as cli:
                with self.assertRaises(preflight.GateError):
                    environment.create(value)
                cli.assert_not_called()
        value = self.fixture()
        value["budget"]["ceilingAmount"] = 0
        with patch.object(environment, "az") as cli, self.assertRaises(preflight.GateError):
            environment.create(value)
        cli.assert_not_called()

    def test_existing_unowned_group_never_gets_mutated(self):
        value = self.fixture()
        with patch.object(environment, "record_attempt"), patch.object(environment, "check_cli_default"), patch.object(environment, "az", side_effect=[
                value["provisioning"]["dataPrincipalObjectId"], True, {"tags": {}}]) as cli:
            with self.assertRaises(preflight.GateError):
                environment.create(value)
        self.assertTrue(all(call.args[0][:2] != ["group", "create"] for call in cli.call_args_list))

    def test_foreign_principal_and_unexpected_resources_are_denied(self):
        value = self.fixture()
        with patch.object(environment, "record_attempt"), patch.object(environment, "check_cli_default"), patch.object(environment, "az", return_value="different") as cli:
            with self.assertRaises(preflight.GateError):
                environment.create(value)
        self.assertEqual(cli.call_count, 1)
        allowed = environment.account_resource_id(value)
        environment.require_only_target_resources(value, [allowed, allowed + "/sqlDatabases/" + value["azure"]["database"]])
        with self.assertRaises(preflight.GateError):
            environment.require_only_target_resources(value, [allowed + "-other"])

    def test_account_and_role_validation_rejects_widening_and_accepts_arm_scope(self):
        value = self.fixture()
        account = self.account(value)
        self.assertEqual(environment.require_owned_account(value, account), "free-tier")
        for update in ({"enableFreeTier": False}, {"networkAclBypass": "AzureServices"},
                       {"minimalTlsVersion": "Tls"}, {"provisioningState": "Creating"},
                       {"locations": [{"locationName": "East US", "isZoneRedundant": True}]},
                       {"ipRules": [{"ipAddressOrRange": "0.0.0.0/0"}]}):
            with self.subTest(update=update), self.assertRaises(preflight.GateError):
                environment.require_owned_account(value, {**account, **update})
        body = environment.role_body(value)
        definition = {"assignableScopes": [environment.account_resource_id(value) + body["AssignableScopes"][0]],
                      "permissions": [{"dataActions": body["Permissions"][0]["DataActions"]}]}
        self.assertTrue(environment.definition_matches(value, definition, body))
        widened = copy.deepcopy(definition)
        widened["permissions"][0]["dataActions"].append("Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/*")
        self.assertFalse(environment.definition_matches(value, widened, body))

    def test_completed_owned_environment_is_idempotent_without_mutation(self):
        value = self.fixture()
        body = environment.role_body(value)
        assignment = str(environment.uuid.uuid5(environment.uuid.NAMESPACE_URL,
                                               "cosmos-sync-assignment:" + environment.ownership_digest(value)))
        definition = {"id": body["Id"], "assignableScopes": body["AssignableScopes"],
                      "permissions": [{"dataActions": body["Permissions"][0]["DataActions"]}]}
        existing_assignment = {"id": assignment, "principalId": value["provisioning"]["dataPrincipalObjectId"],
                               "roleDefinitionId": body["Id"], "scope": body["AssignableScopes"][0]}
        answers = [value["provisioning"]["dataPrincipalObjectId"], True, {"tags": environment.expected_tags(value)},
                   [environment.account_resource_id(value)], [self.account(value)], [value["azure"]["database"]], 400,
                   [{"name": value["azure"]["container"], "paths": ["/scopeId"], "ttl": None}],
                   [definition], [existing_assignment]]
        with patch.object(environment, "record_attempt"), patch.object(environment, "check_cli_default"), patch.object(environment, "az", side_effect=answers) as cli:
            result = environment.create(value)
        self.assertEqual(result["billingVariant"], "free-tier")
        self.assertTrue(all(not any(action in call.args[0] for action in ("create", "delete", "update"))
                            for call in cli.call_args_list))

    def test_teardown_requires_exact_evidence_tags_and_only_new_group(self):
        value = self.fixture()
        value["provisioning"].update({"retentionPolicy": "delete-after-explicit-owner-request",
                                      "teardownApprovalReference": "fixture-future-explicit-cleanup"})
        evidence = {"mode": "approved-live-cosmos-contract", "productionFactory": "NewCosmosStore",
                    "targetDigest": preflight.manifest_digest(value), "acceptedNewMutations": 3}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "evidence.json"
            path.write_text(json.dumps(evidence))
            with patch.object(environment, "require_matching_attempt"), patch.object(environment, "check_cli_default"), patch.object(environment, "az", side_effect=[
                    True, {"tags": environment.expected_tags(value)}, ["/unrelated/storageAccount"]]) as cli:
                with self.assertRaises(preflight.GateError):
                    environment.teardown(value, path)
            self.assertTrue(all("delete" not in call.args[0] for call in cli.call_args_list))
            evidence["targetDigest"] = "other-target"
            path.write_text(json.dumps(evidence))
            with patch.object(environment, "require_matching_attempt"), patch.object(environment, "az") as cli, self.assertRaises(preflight.GateError):
                environment.teardown(value, path)
            cli.assert_not_called()

    def test_current_retention_policy_blocks_cleanup_before_azure(self):
        value = self.fixture()
        value["provisioning"]["teardownApprovalReference"] = "superseded-delete-after-test-approval"
        with patch.object(environment, "az") as cli, self.assertRaises(preflight.GateError):
            environment.teardown(value, None)
        cli.assert_not_called()

    def test_success_partial_and_setup_failure_can_clean_only_with_future_explicit_request(self):
        for mode in ("approved-live-cosmos-contract", "incomplete-approved-live-contract", "setup-only"):
            value = self.fixture()
            value["provisioning"].update({"retentionPolicy": "delete-after-explicit-owner-request",
                                          "teardownApprovalReference": "fixture-future-explicit-request"})
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                receipt = Path(folder) / "receipt.json"
                with patch.object(environment, "attempt_path", return_value=receipt):
                    environment.record_attempt(value, "account-create-requested")
                    path = Path(folder) / "evidence.json"
                    if mode != "setup-only":
                        path.write_text(json.dumps({"mode": mode, "targetDigest": preflight.manifest_digest(value)}))
                    answers = [True, {"tags": environment.expected_tags(value)}, [], [], None, False]
                    with patch.object(environment, "check_cli_default"), patch.object(environment, "az", side_effect=answers) as cli:
                        result = environment.teardown(value, None if mode == "setup-only" else path)
                    self.assertTrue(result["onlyTaggedNewGroupDeleted"])
                    self.assertEqual(sum(call.args[0][:2] == ["group", "delete"] for call in cli.call_args_list), 1)

    def test_teardown_enumerates_proxy_children_and_refuses_unexpected_data_or_grants(self):
        for kind in ("database", "container", "assignment"):
            value = self.fixture()
            value["provisioning"].update({"retentionPolicy": "delete-after-explicit-owner-request",
                                          "teardownApprovalReference": "fixture-future-explicit-request"})
            base = [True, {"tags": environment.expected_tags(value)}, [environment.account_resource_id(value)],
                    [self.account(value)]]
            extra = (["unapproved-database"],) if kind == "database" else (
                [value["azure"]["database"]], ["unapproved-container"])
            if kind == "assignment":
                extra = ([value["azure"]["database"]], [value["azure"]["container"]], [], [{"id": "unapproved-assignment"}])
            with self.subTest(kind=kind), patch.object(environment, "require_matching_attempt"), \
                    patch.object(environment, "check_cli_default"), patch.object(environment, "az", side_effect=base + list(extra)) as cli:
                with self.assertRaises(preflight.GateError):
                    environment.teardown(value, None)
            self.assertTrue(all("delete" not in call.args[0] for call in cli.call_args_list))
            with self.assertRaises(preflight.GateError):
                environment.require_only_target_resources(value,
                    [environment.account_resource_id(value) + "/sqlDatabases/unapproved-database/containers/unapproved-container"])


if __name__ == "__main__":
    unittest.main()
