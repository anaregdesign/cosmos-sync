#!/usr/bin/env python3
"""A pinned, bounded directory SDK journey; proof/registration is a separate run."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys

from directory_hosting_contract import config_digest, validate_hosting, verify_hosting
from directory_request_ledger import DirectoryRequestLedger, endpoint_digest
from hosted_azure_live import GET_PATHS, STAGES, HostedControl, private_input, verify_token
from live_azure_preflight import GateError, account_https_origin, manifest_digest, require
from native_entra_auth import private_json, replace_private_json, source_state
from flutter_app_smoke import stop_owned_process

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY_STAGES = ("directory_capabilities_verified", "directory_registered_session_verified") + STAGES + ("directory_signout_purged",)
DIRECTORY_GET_PATHS = GET_PATHS | {"/v1/identity/capabilities", "/v1/identities"}


def validate_manifest(value):
    fields = {"schemaVersion", "authorizationMode", "authenticationMode", "endpoint", "replicas",
              "hosting", "runtimeConfigFile", "aggregateLedgerFile", "nativeProofFile",
              "accessTokenFile", "ownerFile", "receiptFile", "targetApprovalReference",
              "liveWriteApprovalReference", "testDataRetentionAcknowledged", "budget"}
    require(isinstance(value, dict) and set(value) == fields,
            "directory acceptance manifest contains missing/unsupported fields")
    require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
            and value["authorizationMode"] == "directory"
            and value["authenticationMode"] == "recorded-api-token"
            and type(value["replicas"]) is int and value["replicas"] == 1,
            "explicit one-replica recorded-token directory mode required")
    account_https_origin(value["endpoint"])
    validate_hosting(value["hosting"])
    require(all(isinstance(value[key], str) and Path(value[key]).is_absolute() for key in
                ("runtimeConfigFile", "aggregateLedgerFile", "nativeProofFile", "accessTokenFile",
                 "ownerFile", "receiptFile")), "exact private input paths required")
    require(all(isinstance(value[key], str) and value[key].strip() for key in
                ("targetApprovalReference", "liveWriteApprovalReference"))
            and value["testDataRetentionAcknowledged"] is True, "retained test document/receipt/tombstone approval required")
    budget = value["budget"]
    require(isinstance(budget, dict) and set(budget) ==
            {"maxRuntimeSeconds", "maxProtocolRequests", "maxAcceptedAppMutations",
             "maxMutationAttempts", "maxDirectoryMetadataOperations", "maxFreshProofChecks"}
            and all(type(number) is int for number in budget.values())
            and 30 <= budget["maxRuntimeSeconds"] <= 120 and 29 <= budget["maxProtocolRequests"] <= 40
            and budget["maxAcceptedAppMutations"] == 3 and budget["maxMutationAttempts"] == 4
            and budget["maxDirectoryMetadataOperations"] == budget["maxFreshProofChecks"] == 0,
            "recorded directory data journey cannot hide new proof/registration writes in its budget")
    return value


def validate_prior_proof(manifest, proof):
    require(isinstance(proof, dict) and type(proof.get("schemaVersion")) is int
            and proof["schemaVersion"] == 2 and proof.get("status") == "passed"
            and proof.get("cleanupComplete") is True and proof.get("actualNativeAppAuth") is True
            and proof.get("ownerInitiatedForegroundSignIn") is True
            and proof.get("sourceSha") == manifest["hosting"]["sourceCommit"]
            and proof.get("sourceTreeDirty") is False
            and proof.get("serverChallengeProvenanceVerified") is True
            and proof.get("freshIdentityProofVerified") is True
            and proof.get("directoryRegistrationVerified") is True
            and proof.get("rawFreshProofPersisted") is False and proof.get("directoryWriteOutcomeUnknown") is False,
            "clean-source attended directory proof/registration evidence required")
    require(proof.get("directoryConfigurationSha256") == manifest["hosting"]["reviewedConfigurationSha256"]
            and proof.get("directoryEndpointSha256") == endpoint_digest(manifest["endpoint"])
            and proof.get("directoryHostingCandidateSha256") == config_digest(manifest["hosting"])
            and Path(manifest["accessTokenFile"]) == Path(manifest["nativeProofFile"]).parent / "initial.jwt",
            "the coordinated native proof/configuration and initial API credential must match")
    require(type(proof.get("aggregateProtocolRequestsObservedAtLastReservation")) is int
            and 4 <= proof["aggregateProtocolRequestsObservedAtLastReservation"] <= 40,
            "coordinated native proof must retain its aggregate request history")
    try:
        completed = datetime.fromisoformat(proof["completedAtUtc"].replace("Z", "+00:00"))
        age = (datetime.now(timezone.utc) - completed).total_seconds()
        require(0 <= age <= 900, "a newly coordinated native directory run is required")
    except (KeyError, ValueError, TypeError, AttributeError):
        raise GateError("coordinated native proof completion time rejected") from None
    return proof


def begin_run():
    parent = ROOT / ".cache/directory-azure-live"
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    require(parent.is_dir() and not parent.is_symlink() and parent.stat().st_uid == os.geteuid(),
            "private current-owner evidence directory required")
    parent.chmod(0o700)
    directory = parent / secrets.token_hex(12)
    directory.mkdir(mode=0o700)
    report = {"schemaVersion": 1, "status": "incomplete", "failureStage": "manifest_preflight",
              "recordedAtUtc": datetime.now(timezone.utc).isoformat(),
              "authenticationMode": "recorded-api-token", "authorizationMode": "directory",
              "protocolRequests": 0, "directoryMetadataOperationsInThisRun": 0, "freshProofChecksInThisRun": 0,
              "knownAcceptedMutationResponses": 0, "mutationAttempts": 0, "cleanupComplete": False}
    private_json(directory / "proof.json", report)
    replace_private_json(parent / "latest.local.json", {"runDirectory": str(directory)})
    return directory, report


def execute(manifest_path, dart_bin="dart", go_bin="go"):
    directory, report = begin_run()
    control = process = None
    stage = "manifest_preflight"
    try:
        manifest = validate_manifest(private_input(manifest_path))
        report["targetDigest"] = manifest_digest(manifest)
        stage = "source_preflight"
        source = source_state(ROOT)
        require(not source["sourceTreeDirty"] and source["sourceSha"] == manifest["hosting"]["sourceCommit"],
                "execute from the exact clean reviewed candidate")
        report.update(source)
        stage = "directory_configuration_preflight"
        config = private_input(manifest["runtimeConfigFile"])
        require(isinstance(config.get("authorization"), dict)
                and config["authorization"].get("mode") == "directory"
                and config.get("storage") == "cosmos" and config.get("development") is False
                and config_digest(config) == manifest["hosting"]["reviewedConfigurationSha256"],
                "exact production directory configuration required")
        stage = "prior_native_proof_preflight"
        prior = validate_prior_proof(manifest, private_input(manifest["nativeProofFile"]))
        stage = "aggregate_budget_preflight"
        ledger = DirectoryRequestLedger(manifest["aggregateLedgerFile"], manifest["endpoint"])
        observed = ledger.read()["protocolRequests"]
        require(observed >= prior["aggregateProtocolRequestsObservedAtLastReservation"],
                "aggregate ledger cannot discard the coordinated native proof requests")
        require(observed + manifest["budget"]["maxProtocolRequests"] <= 40,
                "remaining aggregate budget must cover this complete SDK run")
        stage = "hosting_preflight"
        report.update(verify_hosting(manifest["hosting"], manifest["endpoint"], config))
        stage = "api_verification"
        token = verify_token(manifest, directory, go_bin=go_bin)
        receipt = private_input(manifest["receiptFile"])
        require(config["oidc"]["issuer"] == receipt["oidc"]["issuer"]
                and config["oidc"]["audience"] == receipt["oidc"]["audience"]
                and config["oidc"]["allowedClientIds"] == [receipt["native"]["appId"]],
                "selected API/native trust differs from exact directory runtime")
        callback = receipt["nativeConfig"]["redirectUrl"]
        require(callback in config["authorization"]["directory"]["callbacks"], "exact native callback required")
        fixture = {"protocolVersion": 2, "authorizationMode": "directory",
                   "authenticationMode": "recorded-api-token", "endpoint": manifest["endpoint"],
                   "accessToken": token, "documentId": "directory-live-" + secrets.token_hex(12),
                   "cacheDirectory": str(directory / "sqlite"), "issuer": config["oidc"]["issuer"],
                   "clientId": receipt["native"]["appId"], "callback": callback,
                   "namespace": config["authorization"]["directory"]["namespace"]}
        report["retainedTestDocumentId"] = fixture["documentId"]
        budget = manifest["budget"]
        control = HostedControl(
            fixture, max_requests=budget["maxProtocolRequests"], seconds=budget["maxRuntimeSeconds"],
            stages=DIRECTORY_STAGES, get_paths=DIRECTORY_GET_PATHS, request_ledger=ledger)
        control.start()
        stage = "sdk_runtime"
        log_fd = os.open(directory / "dart.private.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(log_fd, "wb") as output:
            process = subprocess.Popen(
                [dart_bin, "run", "test/directory_azure_live.dart"], cwd=ROOT / "packages/cosmos_sync",
                env={**os.environ, "COSMOS_SYNC_DIRECTORY_CONTROL_URL": control.url},
                stdout=output, stderr=output, start_new_session=os.name == "posix")
            process.wait(timeout=budget["maxRuntimeSeconds"])
        require(process.returncode == 0 and tuple(control.stages) == DIRECTORY_STAGES
                and control.accepted == 3 and control.conflicts == 1 and control.mutation_attempts == 4
                and control.pending_attempt is None and not control.unknown_outcome,
                "directory SDK assertions did not complete")
        report.update({"status": "passed", "failureStage": None, "actualHostedBff": True, "realSqlite": True,
                       "hostedGraphExecuted": True,
                       "hostedGraphEvidence": "reviewed-production-directory-application-path-accepted",
                       "notVerified": ["new provider login in this target", "ordinary native UI",
                                       "distinct shared member", "multiple actual credentials/link/unlink",
                                       "multiple hosted BFF replicas", "physical OS/airplane/suspension"],
                       "priorDirectoryProofEvidenceReused": True, "localSdkSignoutPurged": True,
                       "noCrossPartitionRollbackClaimed": True})
        return report
    except (GateError, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        report.update({"status": "failed", "failureStage": stage, "failureCategory": type(error).__name__})
        raise
    finally:
        cleaned = True
        try:
            stop_owned_process(process)
        except (OSError, subprocess.SubprocessError):
            cleaned = False
        if control is not None:
            try:
                control.close()
            except OSError:
                cleaned = False
            report.update({"stages": list(control.stages), "protocolRequests": control.requests,
                           "knownAcceptedMutationResponses": control.accepted, "mutationAttempts": control.mutation_attempts,
                           "conflictResponses": control.conflicts,
                           "unknownOutcome": control.unknown_outcome or control.pending_attempt is not None,
                           "aggregateProtocolRequestsObservedAtLastReservation": control.aggregate_requests,
                           "retainedTestDataMayExist": control.mutation_attempts > 0})
        try:
            (directory / "api-access.jwt").unlink(missing_ok=True)
        except OSError:
            cleaned = False
        report["cleanupComplete"] = cleaned
        if not cleaned:
            report.update({"status": "failed", "failureStage": "cleanup", "failureCategory": "owned_cleanup_failed"})
        replace_private_json(directory / "proof.json", report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--execute-approved", action="store_true")
    parser.add_argument("--dart-bin", default="dart")
    parser.add_argument("--go-bin", default="go")
    args = parser.parse_args()
    if args.execute_approved:
        report = execute(args.manifest, args.dart_bin, args.go_bin)
        require(report["status"] == "passed", "owned cleanup did not complete")
    else:
        manifest = validate_manifest(private_input(args.manifest))
        report = {"mode": "offline-directory-plan", "targetDigest": manifest_digest(manifest),
                  "azureContacted": False, "tokensLoaded": False, "resourcesModified": False,
                  "registrationInThisRun": False, "freshLoginInThisRun": False,
                  "budget": manifest["budget"], "plannedStages": DIRECTORY_STAGES}
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (GateError, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError, KeyboardInterrupt):
        print("DIRECTORY_AZURE_VALIDATION_FAILED_CHECK_PRIVATE_EVIDENCE", file=sys.stderr)
        raise SystemExit(1)
