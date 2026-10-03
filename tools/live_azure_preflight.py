#!/usr/bin/env python3
"""Offline plan or explicit read-only Azure metadata check; never provisions."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit
import uuid

MIN_PROTOCOL_REQUESTS = 31  # 29 contract requests plus two HTTPS health probes.


class GateError(Exception):
    """Safe message: never include credential or arbitrary server response data."""


def require(condition, message):
    if not condition:
        raise GateError(message)


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def https_url(value, field):
    require(isinstance(value, str), f"{field} must be a HTTPS URL")
    parsed = urlsplit(value)
    require(parsed.scheme == "https" and parsed.hostname and not parsed.username
            and not parsed.password and not parsed.query and not parsed.fragment,
            f"{field} must be HTTPS without credentials, query, or fragment")
    return parsed


def load_manifest(path):
    try:
        value = json.loads(Path(path).read_text())
        require(value.get("schemaVersion") == 1, "unsupported manifest version")
        azure = value["azure"]
        for key in ("tenantId", "subscriptionId"):
            require(str(uuid.UUID(azure[key])).lower() == azure[key].lower(),
                    f"azure.{key} must be a canonical UUID")
        for key in ("resourceGroup", "account", "database", "container"):
            require(nonempty(azure[key]) and "/" not in azure[key]
                    and len(azure[key]) <= 255, f"invalid azure.{key}")
        endpoint = https_url(azure["endpoint"], "azure.endpoint")
        require(endpoint.path in ("", "/") and endpoint.port in (None, 443),
                "azure.endpoint must be an account HTTPS origin")
        oidc = value["oidc"]
        https_url(oidc["issuer"], "oidc.issuer")
        for key in ("audience", "tenantClaim", "requiredScope"):
            require(nonempty(oidc[key]), f"oidc.{key} must be specified")
        require(isinstance(oidc.get("tokenUse", ""), str), "invalid oidc.tokenUse")
        principals = value["testPrincipals"]
        for role in ("writer", "reader", "outsider"):
            principal = principals[role]
            require(all(nonempty(principal[key]) for key in
                        ("tenant", "subject", "accessTokenFile")),
                    f"{role} requires explicitly selected tenant, subject, token file")
            require(Path(principal["accessTokenFile"]).is_absolute(),
                    f"{role} token file must use an absolute private path")
        require(principals["writer"]["tenant"] == principals["reader"]["tenant"],
                "writer and reader must share the selected test tenant")
        require(principals["writer"]["subject"] != principals["reader"]["subject"],
                "writer and reader must be distinct principals")
        outsider_identity = (principals["outsider"]["tenant"],
                             principals["outsider"]["subject"])
        require(all(outsider_identity != (principals[role]["tenant"],
                                         principals[role]["subject"])
                    for role in ("writer", "reader")),
                "outsider must be a distinct ungranted principal")
        budget = value["budget"]
        for key, lower, upper in (("maxRuntimeSeconds", 30, 180),
                                  ("maxProtocolRequests", MIN_PROTOCOL_REQUESTS, 50)):
            require(type(budget[key]) is int and lower <= budget[key] <= upper,
                    f"budget.{key} is outside the bounded harness range")
        require(budget["maxAcceptedMutations"] == 3,
                "this contract accepts exactly three new mutations")
        require(type(budget["ceilingAmount"]) in (int, float)
                and 0 <= budget["ceilingAmount"] < float("inf"),
                "budget.ceilingAmount must be finite and nonnegative")
        require(re.fullmatch(r"[A-Z]{3}", budget["currency"]) is not None,
                "budget.currency must be a three-letter currency code")
        return value
    except (KeyError, TypeError, ValueError, OSError):
        raise GateError("manifest is missing or invalid; compare environment.example.json") from None


def manifest_digest(manifest):
    return hashlib.sha256(json.dumps(manifest, sort_keys=True,
                                    separators=(",", ":")).encode()).hexdigest()


def require_target_approval(manifest):
    require(nonempty(manifest.get("targetApprovalReference")),
            "owner must select and authorize this isolated Azure target first")
    azure = manifest["azure"]
    require(not any(azure[key] == "00000000-0000-0000-0000-000000000000"
                    for key in ("tenantId", "subscriptionId")),
            "example UUIDs cannot be used for a live target")
    require(not any("owner-selected" in str(value) for value in azure.values()),
            "replace every Azure target placeholder after owner selection")


def az_json(arguments, query):
    command = ["az", *arguments, "--query", query, "--only-show-errors", "-o", "json"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=40,
                                check=False, env={**os.environ,
                                                  "AZURE_CORE_COLLECT_TELEMETRY": "no"})
    except (OSError, subprocess.TimeoutExpired):
        raise GateError("Azure CLI metadata check could not complete") from None
    require(result.returncode == 0,
            "Azure CLI metadata access failed; ask the owner to authenticate or grant target metadata read access")
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise GateError("Azure CLI returned invalid metadata") from None


def assess_metadata(manifest, account, container, subscription):
    azure = manifest["azure"]
    require(subscription.get("id", "").lower() == azure["subscriptionId"].lower()
            and subscription.get("tenantId", "").lower() == azure["tenantId"].lower()
            and subscription.get("state") == "Enabled",
            "subscription/tenant metadata differs from the owner-selected target")
    require(account.get("kind") == "GlobalDocumentDB", "account must use Cosmos DB for NoSQL")
    require(account.get("endpoint", "").rstrip("/").lower()
            == azure["endpoint"].rstrip("/").lower(),
            "account endpoint differs from the selected target")
    require(account.get("multiWrite") is False,
            "production guard requires explicit single-write-region mode")
    require(account.get("consistency") in ("Session", "Strong", "BoundedStaleness"),
            "production guard requires Session or stronger account consistency")
    require(bool(account.get("writeLocations")), "account must have writable location metadata")
    require(container.get("partitionPaths") == ["/scopeId"],
            "container partition key must be /scopeId")
    require(container.get("ttl") in (None, -1),
            "journal and receipts must not have default expiry")
    # Per-item TTL is not supported by this BFF even when the container uses -1.
    warnings = []
    if account.get("disableLocalAuth") is not True:
        warnings.append("account key authentication is not disabled; this BFF still uses Entra credentials only")
    return {"productionGuardCompatible": True,
            "consistency": account["consistency"],
            "writeRegionCount": len(account["writeLocations"]),
            "readRegionCount": len(account.get("readLocations") or []),
            "partitionPaths": ["/scopeId"], "defaultTtl": container.get("ttl"),
            "backupPolicy": account.get("backupPolicy"), "warnings": warnings}


def inspect_target(manifest):
    require_target_approval(manifest)
    azure = manifest["azure"]
    subscription = az_json(["account", "show", "--subscription", azure["subscriptionId"]],
                           "{id:id,tenantId:tenantId,state:state}")
    common = ["--subscription", azure["subscriptionId"], "--resource-group", azure["resourceGroup"]]
    account = az_json(["cosmosdb", "show", "--name", azure["account"], *common],
                      "{kind:kind,endpoint:documentEndpoint,multiWrite:enableMultipleWriteLocations,"
                      "consistency:consistencyPolicy.defaultConsistencyLevel,writeLocations:writeLocations,"
                      "readLocations:readLocations,disableLocalAuth:disableLocalAuth,backupPolicy:backupPolicy}")
    container = az_json(["cosmosdb", "sql", "container", "show", "--account-name", azure["account"],
                        "--database-name", azure["database"], "--name", azure["container"], *common],
                       "{partitionPaths:resource.partitionKey.paths,ttl:resource.defaultTtl}")
    return {"schemaVersion": 1, "targetDigest": manifest_digest(manifest),
            "mode": "read-only-metadata", "resourcesModified": False,
            **assess_metadata(manifest, account, container, subscription)}


def check_cli_default(manifest):
    # The production factory uses DefaultAzureCredential(nil). Its CLI branch
    # uses the CLI default context, so do not silently change the owner's context.
    current = az_json(["account", "show"], "{id:id,tenantId:tenantId,state:state}")
    azure = manifest["azure"]
    require(current.get("id", "").lower() == azure["subscriptionId"].lower()
            and current.get("tenantId", "").lower() == azure["tenantId"].lower(),
            "existing Azure CLI default differs from the selected target; owner must select it or authenticate in an isolated AZURE_CONFIG_DIR")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--inspect", action="store_true",
                        help="explicitly inspect the owner-selected target with three read-only CLI commands")
    args = parser.parse_args()
    try:
        manifest = load_manifest(args.manifest)
        result = inspect_target(manifest) if args.inspect else {
            "schemaVersion": 1, "mode": "offline-plan", "targetDigest": manifest_digest(manifest),
            "resourcesModified": False, "azureContacted": False,
            "targetApprovalPresent": nonempty(manifest.get("targetApprovalReference")),
            "writeApprovalPresent": nonempty(manifest.get("liveWriteApprovalReference")),
            "maxAcceptedMutations": manifest["budget"]["maxAcceptedMutations"],
            "maxProtocolRequests": manifest["budget"]["maxProtocolRequests"],
            "maxRuntimeSeconds": manifest["budget"]["maxRuntimeSeconds"],
            "plannedProtocolRequests": MIN_PROTOCOL_REQUESTS,
            "remainingGates": ["owner-selected isolated target and cost ceiling",
                               "container-scoped Entra data role and network access",
                               "API access JWT files and exact approved server grant subjects",
                               "explicit authorization for three retained test mutations"]}
        print(json.dumps(result, indent=2))
    except GateError as error:
        print(f"Preflight blocked: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
