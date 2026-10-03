#!/usr/bin/env python3
"""Offline by default; create/reuse only a tagged approved validation environment."""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import uuid

from live_azure_preflight import (GateError, check_cli_default, load_manifest,
                                  manifest_digest, nonempty, require,
                                  require_target_approval)
from live_azure_contract import ROOT, private_json


def validate_selection(manifest, *, live=False):
    selected = manifest.get("provisioning", {})
    require(selected.get("billingMode") in ("free-tier-preferred", "serverless"),
            "select free-tier-preferred or serverless billing")
    require(nonempty(selected.get("region")), "select a permitted region")
    require(selected.get("retentionPolicy") in ("retain-for-reuse", "delete-after-explicit-owner-request"),
            "select an explicit validation-resource retention policy")
    if live:
        require_target_approval(manifest)
        require(nonempty(selected.get("approvalReference")),
                "owner must approve exact temporary resources, network and data-role assignment")
        budget = manifest["budget"]
        ceiling = budget.get("ceilingAmount")
        require((type(ceiling) in (int, float) and 0 < ceiling < float("inf"))
                or (ceiling is None and budget.get("unboundedCostApproved") is True),
                "owner must explicitly approve creation costs before resource access")
        try:
            principal = uuid.UUID(selected["dataPrincipalObjectId"])
            egress = ipaddress.ip_address(selected["egressIpv4"])
        except (KeyError, ValueError, TypeError):
            raise GateError("select the exact data principal and current public egress IPv4") from None
        require(principal.int != 0 and isinstance(egress, ipaddress.IPv4Address) and egress.is_global,
                "example principal/IP or nonpublic/broad network access is not allowed")
    return selected


def ownership_digest(manifest):
    selected = manifest["provisioning"]
    target = {"azure": manifest["azure"],
              "provisioning": {key: selected.get(key) for key in
                               ("region", "egressIpv4", "dataPrincipalObjectId")}}
    return hashlib.sha256(json.dumps(target, sort_keys=True).encode()).hexdigest()


def expected_tags(manifest):
    return {"cosmosSyncVerification": "retained-validation",
            "cosmosSyncOwnership": ownership_digest(manifest)}


def selection_digest(manifest):
    # OIDC token files/subjects may be filled after provisioning. Approval and
    # every resource/network/data-identity binding remain fixed for cleanup.
    value = {"ownership": ownership_digest(manifest),
             "targetApproval": manifest.get("targetApprovalReference"),
             "setupApproval": manifest["provisioning"].get("approvalReference")}
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def attempt_path(manifest):
    return ROOT / ".cache/azure-verification-environment" / (ownership_digest(manifest) + ".json")


def record_attempt(manifest, phase):
    path = attempt_path(manifest)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    private_json(path, {"mode": "approved-private-environment-attempt",
                        "selectionDigest": selection_digest(manifest),
                        "ownershipDigest": ownership_digest(manifest),
                        "manifestDigestAtAttempt": manifest_digest(manifest), "phase": phase})


def require_matching_attempt(manifest):
    path = attempt_path(manifest)
    try:
        info = path.stat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) & 0o077 == 0,
                "cleanup receipt must be a private current-user-owned regular file")
        value = json.loads(path.read_text())
    except (OSError, ValueError):
        raise GateError("matching private environment-attempt receipt is required for setup/partial cleanup") from None
    require(value.get("mode") == "approved-private-environment-attempt"
            and value.get("selectionDigest") == selection_digest(manifest)
            and value.get("ownershipDigest") == ownership_digest(manifest)
            and value.get("phase") in ("before-group-metadata", "group-create-requested", "account-create-requested",
                                       "database-create-requested", "container-create-requested", "role-create-requested",
                                       "assignment-create-requested", "environment-ready"),
            "private cleanup receipt differs from the exact approved resource selection")


def require_owned_group(manifest, group):
    require(all(group.get("tags", {}).get(key) == value
                for key, value in expected_tags(manifest).items()),
            "existing resource group is not owned by this exact verification target; refusing reuse/deletion")


def az(arguments, *, action, query=None, output=True):
    command = ["az", *arguments, "--only-show-errors", "-o", "json" if output else "none"]
    if query:
        command += ["--query", query]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=1200,
                                env={**os.environ, "AZURE_CORE_COLLECT_TELEMETRY": "no"}, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise GateError(f"{action} did not complete; cloud outcome may be pending; rerun metadata checks") from None
    require(result.returncode == 0,
            f"{action} failed; inspect the selected target privately; no raw CLI error is exposed")
    try:
        return json.loads(result.stdout) if output else None
    except ValueError:
        raise GateError(f"{action} returned invalid metadata") from None


def args_for(manifest):
    azure = manifest["azure"]
    subscription = ["--subscription", azure["subscriptionId"]]
    group = [*subscription, "--resource-group", azure["resourceGroup"]]
    account = [*group, "--account-name", azure["account"]]
    return subscription, group, account


def account_resource_id(manifest):
    azure = manifest["azure"]
    return (f"/subscriptions/{azure['subscriptionId']}/resourceGroups/{azure['resourceGroup']}"
            f"/providers/Microsoft.DocumentDB/databaseAccounts/{azure['account']}")


def scope_matches(manifest, value, relative):
    if value == relative:
        return True
    prefix = account_resource_id(manifest)
    return isinstance(value, str) and value[:len(prefix)].lower() == prefix.lower() \
        and value[len(prefix):] == relative


def require_only_target_resources(manifest, resources):
    azure = manifest["azure"]
    account = account_resource_id(manifest)
    database = account + "/sqlDatabases/" + azure["database"]
    definition = role_body(manifest)["Id"]
    assignment = str(uuid.uuid5(uuid.NAMESPACE_URL, "cosmos-sync-assignment:" + ownership_digest(manifest)))
    allowed = {value.lower() for value in (account, database,
               database + "/containers/" + azure["container"], database + "/throughputSettings/default",
               account + "/sqlRoleDefinitions/" + definition, account + "/sqlRoleAssignments/" + assignment)}
    require(all(isinstance(value, str) and value.lower() in allowed for value in resources),
            "unexpected resource in temporary group; refusing mutation/deletion")


def require_owned_account(manifest, account):
    require_owned_group(manifest, account)
    selected = manifest["provisioning"]
    require(account.get("kind") == "GlobalDocumentDB"
            and account.get("provisioningState") == "Succeeded"
            and account.get("consistencyPolicy", {}).get("defaultConsistencyLevel") == "Session"
            and account.get("enableMultipleWriteLocations") is False
            and account.get("disableLocalAuth") is True,
            "existing account differs from approved NoSQL/Session/single-write/Entra-only configuration")
    locations = account.get("locations") or []
    normalize = lambda value: str(value).replace(" ", "").lower()
    require(len(locations) == 1 and normalize(locations[0].get("locationName")) == normalize(selected["region"])
            and locations[0].get("isZoneRedundant") is False,
            "existing account differs from the selected single region without zones")
    allowed = account.get("ipRules") or []
    try:
        same_ip = len(allowed) == 1 and ipaddress.ip_network(allowed[0]["ipAddressOrRange"], strict=False) \
            == ipaddress.ip_network(selected["egressIpv4"] + "/32")
    except (KeyError, ValueError):
        same_ip = False
    require(same_ip and account.get("networkAclBypass") == "None",
            "existing account network rules differ from the exact selected egress IP")
    backup = account.get("backupPolicy") or {}
    require(str(account.get("publicNetworkAccess", "")).lower() == "enabled"
            and account.get("minimalTlsVersion") == "Tls12"
            and backup.get("type") == "Continuous"
            and (backup.get("continuousModeProperties") or {}).get("tier") == "Continuous7Days",
            "existing account TLS/public firewall/backup differs from approved configuration")
    capabilities = {value.get("name") for value in account.get("capabilities", [])}
    is_serverless = "EnableServerless" in capabilities
    require(is_serverless or account.get("enableFreeTier") is True,
            "refusing paid provisioned throughput outside the approved cheapest variants")
    require(selected["billingMode"] != "serverless" or is_serverless,
            "existing account billing differs from explicit serverless selection")
    return "serverless" if is_serverless else "free-tier"


def role_body(manifest):
    azure = manifest["azure"]
    value = json.loads((ROOT / "ops/azure/cosmos-data-role.example.json").read_text())
    value["Id"] = str(uuid.uuid5(uuid.NAMESPACE_URL, "cosmos-sync-role:" + ownership_digest(manifest)))
    value["AssignableScopes"] = [f"/dbs/{azure['database']}/colls/{azure['container']}"]
    return value


def definition_matches(manifest, definition, body):
    scopes = definition.get("assignableScopes", [])
    permissions = definition.get("permissions", [])
    return len(scopes) == 1 and scope_matches(manifest, scopes[0], body["AssignableScopes"][0]) \
        and len(permissions) == 1 and not permissions[0].get("notDataActions") \
        and set(permissions[0].get("dataActions", [])) == set(body["Permissions"][0]["DataActions"])


def create(manifest):
    selected = validate_selection(manifest, live=True)
    check_cli_default(manifest)
    current_principal = az(["ad", "signed-in-user", "show"], action="selected developer identity metadata", query="id")
    require(isinstance(current_principal, str)
            and current_principal.lower() == selected["dataPrincipalObjectId"].lower(),
            "selected local data principal differs from the current approved CLI user")
    record_attempt(manifest, "before-group-metadata")
    subscription, group, account_args = args_for(manifest)
    azure = manifest["azure"]
    # Keep failures resumable: ownership tags are written in the first mutation.
    exists = az(["group", "exists", *subscription, "--name", azure["resourceGroup"]], action="group metadata")
    if exists:
        require_owned_group(manifest, az(["group", "show", *subscription, "--name", azure["resourceGroup"]],
                                        action="group ownership metadata", query="{tags:tags}"))
    else:
        record_attempt(manifest, "group-create-requested")
        az(["group", "create", *subscription, "--name", azure["resourceGroup"],
            "--location", selected["region"], "--tags",
            *[key + "=" + value for key, value in expected_tags(manifest).items()]],
           action="temporary group creation", output=False)
    require_only_target_resources(manifest, az(["resource", "list", *group],
                                               action="temporary group resource inventory", query="[].id"))
    existing = az(["cosmosdb", "list", *group], action="target account metadata")
    matches = [value for value in existing if value.get("name") == azure["account"]]
    require(all(value.get("name") == azure["account"] for value in existing),
            "temporary group contains an unexpected account; refusing creation")
    if not matches:
        all_accounts = az(["cosmosdb", "list", *subscription], action="free-tier entitlement metadata",
                          query="[].{enableFreeTier:enableFreeTier}")
        free = selected["billingMode"] == "free-tier-preferred" \
            and not any(value.get("enableFreeTier") is True for value in all_accounts)
        variant = ["--enable-free-tier", "true"] if free else ["--capabilities", "EnableServerless"]
        record_attempt(manifest, "account-create-requested")
        az(["cosmosdb", "create", *group, "--name", azure["account"], "--kind", "GlobalDocumentDB",
            *variant, "--locations", "regionName=" + selected["region"], "failoverPriority=0", "isZoneRedundant=false",
            "--default-consistency-level", "Session", "--enable-multiple-write-locations", "false",
            "--enable-automatic-failover", "false", "--disable-local-auth", "true", "--minimal-tls-version", "Tls12",
            "--network-acl-bypass", "None", "--public-network-access", "Enabled",
            "--ip-range-filter", selected["egressIpv4"], "--backup-policy-type", "Continuous",
            "--continuous-tier", "Continuous7Days", "--tags",
            *[key + "=" + value for key, value in expected_tags(manifest).items()]],
           action="approved cheapest account creation (eligibility/policy errors stop without automatic retry)", output=False)
        matches = az(["cosmosdb", "list", *group], action="created account metadata")
    require(len(matches) == 1, "expected exactly one selected temporary account")
    mode = require_owned_account(manifest, matches[0])
    databases = az(["cosmosdb", "sql", "database", "list", *account_args], action="database metadata",
                   query="[].resource.id")
    require(all(value == azure["database"] for value in databases), "unexpected database in temporary account")
    if azure["database"] not in databases:
        record_attempt(manifest, "database-create-requested")
        az(["cosmosdb", "sql", "database", "create", *account_args, "--name", azure["database"],
            *(["--throughput", "400"] if mode == "free-tier" else [])],
           action="bounded verification database creation", output=False)
    if mode == "free-tier":
        throughput = az(["cosmosdb", "sql", "database", "throughput", "show", *account_args,
                         "--name", azure["database"]], action="free-tier throughput metadata", query="resource.throughput")
        require(throughput == 400, "existing database does not have the approved shared 400 RU/s")
    containers = az(["cosmosdb", "sql", "container", "list", *account_args,
                     "--database-name", azure["database"]], action="container metadata",
                    query="[].{name:resource.id,paths:resource.partitionKey.paths,ttl:resource.defaultTtl}")
    require(all(value.get("name") == azure["container"] for value in containers), "unexpected verification container")
    if not containers:
        record_attempt(manifest, "container-create-requested")
        az(["cosmosdb", "sql", "container", "create", *account_args, "--database-name", azure["database"],
            "--name", azure["container"], "--partition-key-path", "/scopeId", "--partition-key-version", "2"],
           action="TTL-disabled scope container creation", output=False)
    else:
        require(containers[0].get("paths") == ["/scopeId"] and containers[0].get("ttl") is None,
                "existing container partition/TTL differs from approved configuration")
    body = role_body(manifest)
    definitions = az(["cosmosdb", "sql", "role", "definition", "list", *account_args], action="data-role metadata")
    definition = next((value for value in definitions if value.get("id", "").split("/")[-1] == body["Id"]), None)
    if definition:
        require(definition_matches(manifest, definition, body),
                "existing data-role definition differs from approved narrow permissions")
    else:
        with tempfile.TemporaryDirectory(prefix="cosmos-verification-role-") as directory:
            path = Path(directory) / "role.json"
            private_json(path, body)
            record_attempt(manifest, "role-create-requested")
            az(["cosmosdb", "sql", "role", "definition", "create", *account_args, "--body", "@" + str(path)],
               action="approved narrow native data-role creation", output=False)
    assignment = str(uuid.uuid5(uuid.NAMESPACE_URL, "cosmos-sync-assignment:" + ownership_digest(manifest)))
    assignments = az(["cosmosdb", "sql", "role", "assignment", "list", *account_args], action="data-assignment metadata")
    existing_assignment = next((value for value in assignments if value.get("id", "").split("/")[-1] == assignment), None)
    if existing_assignment:
        require(existing_assignment.get("principalId") == selected["dataPrincipalObjectId"]
                and existing_assignment.get("roleDefinitionId", "").split("/")[-1] == body["Id"]
                and scope_matches(manifest, existing_assignment.get("scope"), body["AssignableScopes"][0]),
                "existing data assignment differs from the selected principal/container")
    else:
        record_attempt(manifest, "assignment-create-requested")
        az(["cosmosdb", "sql", "role", "assignment", "create", *account_args,
            "--role-assignment-id", assignment, "--role-definition-id", body["Id"],
            "--principal-id", selected["dataPrincipalObjectId"], "--scope", body["AssignableScopes"][0]],
           action="approved exact container role assignment", output=False)
    record_attempt(manifest, "environment-ready")
    return {"mode": "prepared-approved-temporary-environment", "ownershipDigest": ownership_digest(manifest),
            "billingVariant": mode, "onlyContainerDataRoleAssigned": True,
            "dataContractNotExecuted": True, "teardownNotExecuted": True}


def teardown(manifest, evidence_path):
    selected = validate_selection(manifest, live=True)
    require(selected["retentionPolicy"] == "delete-after-explicit-owner-request"
            and nonempty(selected.get("teardownApprovalReference")),
            "resources are retained; cleanup needs a future explicit owner request for this exact new group")
    require_matching_attempt(manifest)
    if evidence_path is not None:
        try:
            evidence = json.loads(evidence_path.read_text())
        except (OSError, ValueError):
            raise GateError("private verification evidence could not be read") from None
        require(evidence.get("mode") in ("approved-live-cosmos-contract", "incomplete-approved-live-contract")
                and evidence.get("targetDigest") == manifest_digest(manifest),
                "private verification evidence differs from this exact manifest")
    check_cli_default(manifest)
    azure = manifest["azure"]
    subscription, group, _ = args_for(manifest)
    exists = az(["group", "exists", *subscription, "--name", azure["resourceGroup"]], action="teardown metadata")
    if exists:
        require_owned_group(manifest, az(["group", "show", *subscription, "--name", azure["resourceGroup"]],
                                        action="teardown ownership metadata", query="{tags:tags}"))
        resources = az(["resource", "list", *group], action="teardown resource inventory", query="[].id")
        require_only_target_resources(manifest, resources)
        _, _, account_args = args_for(manifest)
        accounts = az(["cosmosdb", "list", *group], action="teardown account inventory")
        require(all(value.get("name") == azure["account"] for value in accounts), "unexpected account during teardown")
        if accounts:
            require_owned_group(manifest, accounts[0])
            # Enumerate proxy children even after a partial setup: generic ARM
            # inventory can omit them. Unavailable metadata stops deletion.
            databases = az(["cosmosdb", "sql", "database", "list", *account_args],
                           action="teardown database inventory", query="[].resource.id")
            require(all(value == azure["database"] for value in databases), "unexpected database; refusing teardown")
            if databases:
                containers = az(["cosmosdb", "sql", "container", "list", *account_args,
                                 "--database-name", azure["database"]], action="teardown container inventory",
                                query="[].resource.id")
                require(all(value == azure["container"] for value in containers), "unexpected container; refusing teardown")
            definitions = az(["cosmosdb", "sql", "role", "definition", "list", *account_args],
                             action="teardown role inventory")
            own_role = role_body(manifest)["Id"]
            builtins = {"00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002"}
            require(all(value.get("id", "").split("/")[-1] in builtins | {own_role} for value in definitions),
                    "unexpected custom role; refusing teardown")
            assignments = az(["cosmosdb", "sql", "role", "assignment", "list", *account_args],
                             action="teardown assignment inventory")
            own_assignment = str(uuid.uuid5(uuid.NAMESPACE_URL, "cosmos-sync-assignment:" + ownership_digest(manifest)))
            require(all(value.get("id", "").split("/")[-1] == own_assignment
                        and value.get("principalId") == selected["dataPrincipalObjectId"]
                        and value.get("roleDefinitionId", "").split("/")[-1] == own_role
                        and scope_matches(manifest, value.get("scope"), role_body(manifest)["AssignableScopes"][0])
                        for value in assignments), "unexpected assignment; refusing teardown")
        az(["group", "delete", *subscription, "--name", azure["resourceGroup"], "--yes"],
           action="approved owned temporary group deletion", output=False)
        require(az(["group", "exists", *subscription, "--name", azure["resourceGroup"]],
                   action="teardown completion metadata") is False, "temporary deletion has not completed")
    return {"mode": "approved-temporary-environment-deleted", "ownershipDigest": ownership_digest(manifest),
            "onlyTaggedNewGroupDeleted": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--create-approved", action="store_true")
    actions.add_argument("--teardown-approved", action="store_true")
    parser.add_argument("--verification-evidence", type=Path)
    args = parser.parse_args()
    try:
        manifest = load_manifest(args.manifest)
        validate_selection(manifest)
        if args.create_approved:
            result = create(manifest)
        elif args.teardown_approved:
            result = teardown(manifest, args.verification_evidence)
        else:
            result = {"mode": "offline-environment-plan", "ownershipDigest": ownership_digest(manifest),
                      "azureContacted": False, "resourcesModified": False,
                      "retentionPolicy": manifest["provisioning"]["retentionPolicy"],
                      "steps": ["match isolated CLI context", "create/reuse exact ownership-tagged validation group",
                                "free-tier shared400 if unused/eligible; otherwise serverless",
                                "one-region Session Entra-only TLS1.2 selected-egress firewall",
                                "one TTL-disabled /scopeId container", "exact native container role/assignment",
                                "run approved separate data/app/device gate", "retain selected resources for future reuse"]}
        print(json.dumps(result, indent=2))
        return 0
    except (GateError, KeyboardInterrupt) as error:
        print("Environment blocked: " + (str(error) if isinstance(error, GateError) else
                                        "interrupted; inspect ownership-tagged target metadata before retry"), file=sys.stderr)
        return 130 if isinstance(error, KeyboardInterrupt) else 2
    except (OSError, KeyError, TypeError, ValueError):
        print("Environment blocked: private receipt/configuration could not complete; inspect selected target metadata privately", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
