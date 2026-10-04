#!/usr/bin/env python3
"""Create one retained cursor key, or reuse only its ARM metadata. Offline by default.

Before either live mode, copy the reviewed prerequisite *raw* terraform.tfstate
to an immutable current-user-owned 0600 file in a 0700 directory. Record its
SHA256 in a private copy of ops/azure/cursor-bootstrap.example.json. The config
must bind the exact vault, tenant, location and root azurerm_key_vault.cursor
address. Do not pass a saved plan, terraform-show JSON or a live-changing state.
The hash proves which reviewed state was used; the operator must establish that
the copy comes from the approved prerequisite apply, not an unrelated import.

--plan checks those local inputs without CLI, network, key generation or writes.
--execute additionally needs the existing owner authority reference and an
explicit --sole-writer assertion. The ARM API is create-or-update, not an atomic
create-only API: the operator must exclude other external writers. A fixed local
target receipt/lock rejects retries and ambiguous outcomes. Never delete/change
an attempt receipt to retry, and do not use another clone as a retry mechanism.
--reuse-existing performs ARM metadata GETs only and records the actual version
URI; it never retrieves a secret value, generates a key, rotates or sends a PUT.
Metadata does not prove the key's format or runtime identity permissions; check
the actual BFF separately before accepting a reused version.

The helper keeps its token copies and a new 32-byte CSPRNG key in memory and
never writes their values. Azure CLI retains its normal existing authentication
cache in the selected private profile. The key never enters
Terraform, argv, environment, files, logs or stdout. Receipts contain metadata
and digests only. TLS uses system trust (or an explicitly supplied trusted CA
bundle), with redirects disabled. Existing CLI auth is used without login,
consent, account-set or new scopes; an expired login stops for operator action.
"""

import argparse
import base64
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import secrets
import ssl
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
ATTEMPT_ROOT = ROOT / ".cache/cursor-bootstrap"
ARM_ROOT = "https://management.azure.com"
API_VERSION = "2024-11-01"
SECRET_NAME = "cosmos-sync-cursor"
RESOURCE_ADDRESS = "azurerm_key_vault.cursor"
OWNER_TAGS = {"managed_by": "cosmos-sync", "purpose": "validation", "retention": "retain-for-reuse"}
MAX_RESPONSE = 1024 * 1024


class GateError(Exception):
    """Only fixed nonsecret error codes are exposed by main."""


def require(value, code):
    if not value:
        raise GateError(code)


def is_guid(value):
    try:
        return str(uuid.UUID(value)).lower() == value.lower() and uuid.UUID(value).int != 0
    except (ValueError, TypeError, AttributeError):
        return False


def private_directory(path):
    path = Path(path).absolute()
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o700, "private_directory_required")
    return path


def decode_json(raw):
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate_json_key")
            result[key] = value
        return result

    def reject_constant(value):
        raise GateError("nonfinite_json_number")

    def finite_float(value):
        result = float(value)
        require(math.isfinite(result), "nonfinite_json_number")
        return result

    return json.loads(raw, object_pairs_hook=unique_object, parse_constant=reject_constant, parse_float=finite_float)


def private_json(path):
    path = Path(path).absolute()
    private_directory(path.parent)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o600 and info.st_size <= 20 * MAX_RESPONSE,
                "private_input_required")
        raw = stream.read(20 * MAX_RESPONSE + 1)
        require(len(raw) <= 20 * MAX_RESPONSE, "private_input_too_large")
    try:
        value = decode_json(raw)
        require(isinstance(value, dict), "invalid_private_json")
        return value, hashlib.sha256(raw).hexdigest()
    except (ValueError, UnicodeDecodeError):
        raise GateError("invalid_private_json") from None


def target_from_inputs(config, state, state_digest):
    try:
        require(type(config["schemaVersion"]) is int and config["schemaVersion"] == 1, "unsupported_config_schema")
        require(set(config) == {"schemaVersion", "vault", "terraformState"}, "unexpected_config_field")
        provenance = config["terraformState"]
        require(set(provenance) == {"resourceAddress", "sha256", "provenance"}, "unexpected_provenance_field")
        require(provenance["resourceAddress"] == RESOURCE_ADDRESS, "exact_resource_address_required")
        require(provenance["provenance"] == "immutable-copy-after-reviewed-prerequisite-apply", "reviewed_state_provenance_required")
        require(bool(re.fullmatch(r"[0-9a-f]{64}", provenance["sha256"]))
                and provenance["sha256"] == state_digest, "reviewed_state_hash_mismatch")
        vault = config["vault"]
        require(set(vault) == {"resourceId", "tenantId", "location"}, "unexpected_vault_field")
        resource_id = vault["resourceId"]
        require(isinstance(resource_id, str) and bool(re.fullmatch(
            r"/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9_.()-]{1,90}/providers/Microsoft[.]KeyVault/vaults/[a-zA-Z][a-zA-Z0-9-]{2,23}", resource_id, re.I)), "invalid_vault_id")
        parts = resource_id.split("/")
        require(is_guid(parts[2]) and is_guid(vault["tenantId"]), "invalid_subscription_or_tenant")
        require(not parts[4].endswith(".") and not parts[8].endswith("-") and "--" not in parts[8], "invalid_resource_name")
        require(bool(re.fullmatch(r"[a-z][a-z0-9]{1,40}", vault["location"])), "invalid_location")
        require(type(state["version"]) is int and state["version"] == 4, "raw_terraform_state_required")
        resources = [r for r in state["resources"] if r.get("mode") == "managed"
                     and r.get("type") == "azurerm_key_vault" and r.get("name") == "cursor"
                     and not r.get("module")]
        require(len(resources) == 1, "state_vault_count")
        instances = resources[0]["instances"]
        require(len(instances) == 1 and "index_key" not in instances[0]
                and not instances[0].get("deposed") and not instances[0].get("status"), "state_vault_instance_mismatch")
        attrs = instances[0]["attributes"]
        require(attrs["id"].lower() == resource_id.lower() and attrs["name"].lower() == parts[8].lower(), "state_vault_mismatch")
        require(attrs["tenant_id"].lower() == vault["tenantId"].lower(), "state_tenant_mismatch")
        require(attrs["location"].lower().replace(" ", "") == vault["location"], "state_location_mismatch")
        require(attrs["public_network_access_enabled"] is False and attrs["rbac_authorization_enabled"] is True, "state_private_rbac_required")
        require(attrs["purge_protection_enabled"] is True and attrs["sku_name"].lower() == "standard"
                and attrs["soft_delete_retention_days"] == 90, "state_retention_sku_mismatch")
        require(all(attrs.get(k, False) is False for k in ("enabled_for_deployment", "enabled_for_disk_encryption", "enabled_for_template_deployment")), "state_secret_retrieval_enabled")
        require(all(attrs.get("tags", {}).get(k) == v for k, v in OWNER_TAGS.items()), "state_ownership_tags")
        return {"id": resource_id, "name": parts[8].lower(), "subscription": parts[2],
                "tenant": vault["tenantId"], "location": vault["location"]}
    except (KeyError, TypeError, AttributeError, IndexError):
        raise GateError("invalid_config_or_state") from None


def validate_live_vault(body, target):
    try:
        require(body["id"].lower() == target["id"].lower() and body["name"].lower() == target["name"], "live_vault_mismatch")
        require(body["location"].lower().replace(" ", "") == target["location"], "live_location_mismatch")
        props = body["properties"]
        require(props["tenantId"].lower() == target["tenant"].lower() and props["provisioningState"] == "Succeeded", "live_tenant_or_state_mismatch")
        require(props["publicNetworkAccess"] == "Disabled" and props["enableRbacAuthorization"] is True, "live_private_rbac_required")
        require(props["enablePurgeProtection"] is True and props["sku"]["name"].lower() == "standard"
                and props["sku"]["family"] == "A" and props["softDeleteRetentionInDays"] == 90
                and props.get("enableSoftDelete", True) is True, "live_retention_sku_mismatch")
        require(all(props.get(k, False) is False for k in ("enabledForDeployment", "enabledForDiskEncryption", "enabledForTemplateDeployment")), "live_secret_retrieval_enabled")
        acls = props["networkAcls"]
        require(acls["bypass"] == "None" and acls["defaultAction"] == "Deny"
                and not acls.get("ipRules", []) and not acls.get("virtualNetworkRules", []), "live_network_exception")
        require(props["vaultUri"].lower().rstrip("/") == "https://" + target["name"] + ".vault.azure.net", "live_vault_uri_mismatch")
        require(all(body.get("tags", {}).get(k) == v for k, v in OWNER_TAGS.items()), "live_ownership_tags")
    except (KeyError, TypeError, AttributeError):
        raise GateError("invalid_live_vault") from None


def version_uri(body, target):
    try:
        value = body["properties"]["secretUriWithVersion"]
        require(isinstance(value, str), "invalid_version_uri")
        parsed = urllib.parse.urlsplit(value)
        require(parsed.scheme == "https" and parsed.netloc == target["name"] + ".vault.azure.net"
                and not parsed.query and not parsed.fragment
                and bool(re.fullmatch(r"/secrets/" + SECRET_NAME + r"/[0-9a-fA-F]{32}", parsed.path)), "invalid_version_uri")
        require(body["id"].lower() == (target["id"] + "/secrets/" + SECRET_NAME).lower(), "secret_response_target_mismatch")
        return value
    except (KeyError, TypeError, AttributeError, ValueError):
        raise GateError("invalid_secret_metadata") from None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class ArmTransport:
    def __init__(self, ca_bundle=None):
        context = ssl.create_default_context(cafile=ca_bundle)
        self.opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=context), NoRedirect())

    def request(self, method, resource_id, token, payload=None):
        expected = r"/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9_.()-]{1,90}/providers/Microsoft[.]KeyVault/vaults/[a-zA-Z0-9-]{3,24}(?:/secrets/" + SECRET_NAME + ")?"
        require(bool(re.fullmatch(expected, resource_id, re.I)) and method in ("GET", "PUT"), "invalid_arm_target_or_method")
        require(method != "PUT" or resource_id.lower().endswith("/secrets/" + SECRET_NAME), "invalid_write_target")
        request = urllib.request.Request(ARM_ROOT + resource_id + "?api-version=" + API_VERSION,
                    data=payload, method=method, headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        try:
            response = self.opener.open(request, timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        except (urllib.error.URLError, TimeoutError, OSError):
            raise GateError("arm_transport_failed") from None
        try:
            with response:
                status, raw = response.code, response.read(MAX_RESPONSE + 1)
            require(len(raw) <= MAX_RESPONSE, "arm_response_too_large")
            body = decode_json(raw)
            require(isinstance(body, dict), "invalid_arm_response")
            return status, body
        except (ValueError, UnicodeDecodeError, OSError):
            raise GateError("invalid_arm_response") from None


class ExistingCliToken:
    def __init__(self, profile):
        self.profile = private_directory(profile)

    def command(self, args):
        env = os.environ.copy()
        env.update(AZURE_CONFIG_DIR=str(self.profile), AZURE_CORE_COLLECT_TELEMETRY="no", AZURE_LOGGING_ENABLE_LOG_FILE="no")
        env.pop("AZURE_LOG_LEVEL", None)
        env.pop("AZURE_CORE_LOG_LEVEL", None)
        try:
            result = subprocess.run(["az", *args, "--only-show-errors", "--output", "json"],
                                    env=env, capture_output=True, timeout=30, check=False)
            require(result.returncode == 0 and len(result.stdout) <= MAX_RESPONSE, "existing_cli_auth_required")
            return decode_json(result.stdout)
        except (OSError, subprocess.TimeoutExpired, ValueError):
            raise GateError("existing_cli_auth_required") from None

    def __call__(self, target):
        query = ["account", "show", "--query", "{id:id,tenantId:tenantId}"]
        before = self.command(query)
        body = self.command(["account", "get-access-token", "--resource", ARM_ROOT, "--subscription", target["subscription"]])
        require(before == self.command(query), "default_cli_context_changed")
        try:
            require(body["subscription"].lower() == target["subscription"].lower()
                    and body["tenant"].lower() == target["tenant"].lower(), "token_target_mismatch")
            expiry = float(body["expires_on"])
            require(body["tokenType"].lower() == "bearer" and math.isfinite(expiry)
                    and expiry > time.time() + 60, "token_type_or_expiry_invalid")
            token = body["accessToken"]
            require(isinstance(token, str) and len(token) > 100 and "\n" not in token and "\r" not in token, "invalid_arm_token")
            return token
        except (KeyError, TypeError, ValueError, AttributeError):
            raise GateError("invalid_cli_token_response") from None


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def metadata_path(target, kind="attempt"):
    target_digest = hashlib.sha256(target["id"].lower().encode()).hexdigest()
    return ATTEMPT_ROOT / ("cursor-" + kind + "-" + target_digest + ".json")


def ensure_receipt_directory():
    ATTEMPT_ROOT.parent.mkdir(mode=0o700, exist_ok=True)
    private_directory(ATTEMPT_ROOT.parent)
    ATTEMPT_ROOT.mkdir(mode=0o700, exist_ok=True)
    private_directory(ATTEMPT_ROOT)
    sync_directory(ATTEMPT_ROOT.parent)


@contextlib.contextmanager
def target_lock(target):
    ensure_receipt_directory()
    path = metadata_path(target).with_suffix(".lock")
    fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0), 0o600)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o600, "private_lock_required")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise GateError("another_initializer_is_active") from None
        sync_directory(path.parent)
        yield
    finally:
        os.close(fd)


def save_receipt(path, receipt, exclusive=False):
    allowed = {"schemaVersion", "approvalReference", "configSha256", "stateSha256", "phase", "reason",
               "keySha256", "versionedSecretUri", "startedAtUtc", "completedAtUtc", "soleWriterAsserted"}
    require(path.parent == ATTEMPT_ROOT and set(receipt).issubset(allowed), "unsafe_receipt_path_or_field")
    encoded = json.dumps(receipt, sort_keys=True, indent=2).encode() + b"\n"
    if exclusive:
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        except FileExistsError:
            raise GateError("prior_attempt_exists_do_not_rotate") from None
        with os.fdopen(fd, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        sync_directory(path.parent)
        return
    fd, temporary = tempfile.mkstemp(prefix=".cursor-receipt-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def live_metadata(transport, token, target):
    status, body = transport.request("GET", target["id"], token)
    require(status == 200, "live_vault_get_failed")
    validate_live_vault(body, target)
    return transport.request("GET", target["id"] + "/secrets/" + SECRET_NAME, token)


def initialize(target, authority, config_digest, state_digest, transport, token_provider,
               random_bytes=secrets.token_bytes, sole_writer=False):
    require(sole_writer is True, "single_designated_writer_required")
    require(bool(re.fullmatch(r"[A-Za-z0-9_.:-]{3,120}", authority)), "invalid_approval_reference")
    with target_lock(target):
        path = metadata_path(target)
        receipt = {"schemaVersion": 1, "approvalReference": authority, "configSha256": config_digest,
                   "stateSha256": state_digest, "phase": "preflight_started", "startedAtUtc": utc_now(), "soleWriterAsserted": True}
        save_receipt(path, receipt, exclusive=True)
        token = key = payload = None
        try:
            token = token_provider(target)
            status, body = live_metadata(transport, token, target)
            require(status != 200, "secret_already_exists_do_not_rotate")
            require(status == 404 and body.get("error", {}).get("code") in
                    ("SecretNotFound", "ResourceNotFound", "NotFound"), "secret_absence_not_confirmed")
            key = random_bytes(32)
            require(isinstance(key, bytes) and len(key) == 32, "invalid_random_source")
            receipt.update(keySha256=hashlib.sha256(key).hexdigest(), phase="put_started")
            save_receipt(path, receipt)
            payload = json.dumps({"properties": {"value": base64.b64encode(key).decode("ascii")}}, separators=(",", ":")).encode()
            status, body = transport.request("PUT", target["id"] + "/secrets/" + SECRET_NAME, token, payload)
            require(status in (200, 201), "secret_put_outcome_unknown")
            receipt.update(versionedSecretUri=version_uri(body, target), phase="complete", completedAtUtc=utc_now())
            save_receipt(path, receipt)
            return {"mode": "bootstrap-complete", "receiptRecorded": True}
        except Exception as error:
            receipt["reason"] = str(error) if isinstance(error, GateError) else "unexpected_failure"
            receipt["phase"] = "put_ambiguous_do_not_retry" if receipt["phase"] in ("put_started", "complete") else "preflight_failed_do_not_retry"
            save_receipt(path, receipt)
            raise GateError(receipt["reason"]) from None
        finally:
            token = key = payload = None


def reuse_existing(target, config_digest, state_digest, transport, token_provider):
    with target_lock(target):
        token = token_provider(target)
        status, body = live_metadata(transport, token, target)
        require(status == 200, "existing_secret_metadata_required")
        receipt = {"schemaVersion": 1, "configSha256": config_digest, "stateSha256": state_digest,
                   "phase": "existing_metadata_reused", "versionedSecretUri": version_uri(body, target), "completedAtUtc": utc_now()}
        save_receipt(metadata_path(target, "reuse"), receipt)
        return {"mode": "existing-metadata-reused", "receiptRecorded": True, "keyGenerated": False, "mutations": 0}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--plan", action="store_true")
    modes.add_argument("--execute", action="store_true")
    modes.add_argument("--reuse-existing", action="store_true")
    parser.add_argument("--config", help="Private 0600 config copied from the public example.")
    parser.add_argument("--state", help="Private immutable raw prerequisite state copy bound by config SHA256.")
    parser.add_argument("--azure-config-dir", help="Existing private Azure CLI profile; live modes require this explicitly.")
    parser.add_argument("--ca-bundle", help="Optional trusted CA bundle; TLS verification always remains enabled.")
    parser.add_argument("--approval-reference", help="Nonsecret reference to existing owner authorization for this exact bootstrap.")
    parser.add_argument("--sole-writer", action="store_true")
    args = parser.parse_args(argv)
    try:
        if not (args.plan or args.execute or args.reuse_existing):
            print(json.dumps({"mode": "offline", "networkCalls": 0, "keyGenerated": False, "mutations": 0}))
            return 0
        require(args.config and args.state, "private_config_and_state_required")
        config, config_digest = private_json(args.config)
        state, state_digest = private_json(args.state)
        target = target_from_inputs(config, state, state_digest)
        if args.plan:
            result = {"mode": "offline-plan", "reviewedStateMatched": True, "networkCalls": 0, "keyGenerated": False, "mutations": 0}
        else:
            require(args.azure_config_dir, "existing_cli_profile_required")
            if args.execute:
                require(args.sole_writer and args.approval_reference, "existing_authority_and_sole_writer_required")
            transport, token_provider = ArmTransport(args.ca_bundle), ExistingCliToken(args.azure_config_dir)
            result = (initialize(target, args.approval_reference, config_digest, state_digest, transport, token_provider,
                                 sole_writer=args.sole_writer) if args.execute else
                      reuse_existing(target, config_digest, state_digest, transport, token_provider))
        print(json.dumps(result))
        return 0
    except Exception as error:
        print(json.dumps({"mode": "stopped", "code": str(error) if isinstance(error, GateError) else "unexpected_failure", "rawDiagnosticsSuppressed": True}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
