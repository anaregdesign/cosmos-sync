"""One explicitly approved, transient native fresh proof and directory registration."""
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.request

from live_azure_preflight import GateError, account_https_origin, require
from directory_request_ledger import DirectoryRequestLedger
from directory_hosting_contract import config_digest, validate_hosting, verify_hosting

HEX_ID = re.compile(r"^[0-9a-f]{64}$")
PROOF_FIELDS = {"independentApiIdSignaturesVerified", "selectedObjectTenantCorrelated",
                "exactProvidedNonceVerified", "recentIntegerAuthenticationTimeVerified"}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *unused):
        return None


def validate_manifest(value):
    try:
        require(set(value) == {"schemaVersion", "authorizationMode", "endpoint", "runtimeConfigFile",
                               "aggregateLedgerFile", "hosting",
                               "targetApprovalReference", "directoryWriteApprovalReference",
                               "retainedDirectoryStateAcknowledged", "budget"},
                "directory proof manifest contains unsupported fields")
        require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
                and value["authorizationMode"] == "directory", "explicit directory proof mode required")
        account_https_origin(value["endpoint"])
        validate_hosting(value["hosting"])
        require(all(isinstance(value[key], str) and Path(value[key]).is_absolute()
                    for key in ("runtimeConfigFile", "aggregateLedgerFile")),
                "private directory configuration and aggregate ledger required")
        require(all(isinstance(value[key], str) and value[key].strip() for key in
                    ("targetApprovalReference", "directoryWriteApprovalReference"))
                and value["retainedDirectoryStateAcknowledged"] is True,
                "one retained challenge/registration and authorization initialization require approval")
        budget = value["budget"]
        require(set(budget) == {"maxProtocolRequests", "maxDirectoryMetadataOperations",
                                "maxAuthorizationInitializations", "maxFreshProofChecks"}
                and all(type(count) is int for count in budget.values())
                and budget == {"maxProtocolRequests": 4, "maxDirectoryMetadataOperations": 2,
                               "maxAuthorizationInitializations": 1, "maxFreshProofChecks": 1},
                "directory proof requires the exact four-request, two-metadata-operation budget")
        return value
    except (KeyError, TypeError, AttributeError):
        raise GateError("invalid directory proof manifest") from None


class DirectoryProofSession:
    def __init__(self, manifest, config, directory, receipt_path, owner_path, runtime_config,
                 root, go_bin, *, clock=time.monotonic, now=lambda: datetime.now(timezone.utc)):
        validate_manifest(manifest)
        try:
            trust = runtime_config["authorization"]["directory"]
            require(runtime_config["authorization"]["mode"] == "directory"
                    and runtime_config["storage"] == "cosmos" and runtime_config["development"] is False
                    and runtime_config.get("grants") == [] and not runtime_config.get("grantsFile")
                    and runtime_config["oidc"]["issuer"] == config["issuer"]
                    and runtime_config["oidc"]["allowedClientIds"] == [config["clientId"]]
                    and config["redirectUrl"] in trust["callbacks"],
                    "approved native configuration differs from exact directory runtime")
            self.target = {"issuer": config["issuer"], "clientId": config["clientId"],
                           "callback": config["redirectUrl"], "provider": "entra", "namespace": trust["namespace"]}
        except (KeyError, TypeError):
            raise GateError("invalid directory runtime configuration") from None
        self.manifest, self.directory, self.root, self.go_bin = manifest, directory, root, go_bin
        self.configuration_digest = config_digest(runtime_config)
        verify_hosting(manifest["hosting"], manifest["endpoint"], runtime_config)
        self.ledger = DirectoryRequestLedger(manifest["aggregateLedgerFile"], manifest["endpoint"])
        self.aggregate_requests = self.ledger.read()["protocolRequests"]
        require(self.aggregate_requests + 4 <= 40, "remaining aggregate budget must cover the complete native proof")
        self.receipt_path, self.owner_path = receipt_path, owner_path
        self.clock, self.now, self.deadline = clock, now, float("inf")
        self.cancelled = threading.Event()
        self.state, self.token, self.challenge_value = "unverified", None, None
        self.expires = None
        self.requests = self.metadata_reserved = self.metadata_acknowledged = 0
        self.authorization_reserved = self.proof_checks = 0
        self.unknown_outcome = self.fresh_verified = self.registration_verified = False
        self.server_challenge_verified = False

    def verify_initial(self, token_path):
        require(self.state == "unverified", "selected API credential already verified")
        output = self.directory / "selected-api-proof"
        output.mkdir(mode=0o700)
        result = subprocess.run(
            [self.go_bin, "run", "./cmd/verify-entra-principal", "--owner-file", str(self.owner_path),
             "--receipt-file", str(self.receipt_path), "--token-file", str(token_path),
             "--output-dir", str(output), "--permission-version", "directory-selected-proof-only"],
            cwd=self.root / "bff", capture_output=True, text=True, timeout=60)
        require(result.returncode == 0 and not self.cancelled.is_set(), "selected API credential verification failed")
        self.token = token_path.read_text()
        self.state = "selected"
        self.deadline = self.clock() + 300

    def _request(self, method, path, *, token=None, body=None):
        mutation = method == "POST"
        require(not self.cancelled.is_set() and not self.unknown_outcome and self.clock() < self.deadline
                and self.requests < 4, "directory proof request budget exhausted")
        if mutation:
            require(self.metadata_reserved < 2, "directory metadata budget exhausted")
        self.aggregate_requests = self.ledger.reserve()["protocolRequests"]
        self.requests += 1
        if mutation:
            self.metadata_reserved += 1
            self.authorization_reserved += int(path == "/v1/identity/register")
        request = urllib.request.Request(
            self.manifest["endpoint"].rstrip("/") + path,
            data=None if body is None else json.dumps(body).encode(), method=method,
            headers={"Authorization": "Bearer " + (token or self.token),
                     "Content-Type": "application/json", "Cache-Control": "no-store"})
        opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ssl.create_default_context()), NoRedirect())
        try:
            with opener.open(request, timeout=min(15, self.deadline - self.clock())) as response:
                data = response.read(65537)
                require(response.status == 200 and len(data) <= 65536, "directory response rejected")
                result = json.loads(data)
                require(isinstance(result, dict), "directory response rejected")
            if mutation:
                self.metadata_acknowledged += 1
            return result
        except (OSError, ValueError, GateError, urllib.error.URLError):
            if mutation:
                self.unknown_outcome = True
            raise GateError("directory request failed; do not retry an unknown write") from None

    def challenge(self):
        require(self.state == "selected", "directory challenge is single-use after selected API verification")
        self.state = "challenging"
        capabilities = self._request("GET", "/v1/identity/capabilities")
        require(capabilities.get("version") == 1 and capabilities.get("freshAuthenticationSeconds") == 300
                and capabilities.get("maximumIdentities") == 8
                and capabilities.get("recovery") == "remaining-identity-only"
                and capabilities.get("deletion") == capabilities.get("migration") == "operator-review-required"
                and isinstance(capabilities.get("targets"), list)
                and capabilities["targets"].count(self.target) == 1,
                "exact directory target was not advertised")
        challenge = self._request("POST", "/v1/identity/challenges",
                                  body={"operation": "register", "callback": self.target["callback"]})
        require(challenge.get("operation") == "register" and challenge.get("target") == self.target
                and isinstance(challenge.get("challenge"), str)
                and HEX_ID.fullmatch(challenge["challenge"]), "invalid server-issued directory challenge")
        try:
            self.expires = datetime.fromisoformat(challenge["expiresAt"].replace("Z", "+00:00"))
            remaining = (self.expires - self.now()).total_seconds()
            require(0 < remaining <= 300, "directory challenge expired or has an invalid lifetime")
        except (KeyError, ValueError, TypeError, AttributeError):
            raise GateError("invalid server challenge expiry") from None
        require(not self.cancelled.is_set(), "directory operation cancelled")
        self.challenge_value = challenge["challenge"]
        self.server_challenge_verified = True
        self.deadline = min(self.deadline, self.clock() + remaining)
        self.state = "challenged"
        return challenge

    def accept(self, value):
        require(self.state == "challenged" and self.clock() < self.deadline
                and self.now() < self.expires and self.proof_checks == 0,
                "directory proof is duplicate, late or expired")
        require(isinstance(value, dict) and set(value) == {"accessToken", "idToken"}
                and all(isinstance(value[key], str) and 8 <= len(value[key]) <= bound
                        and re.fullmatch(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", value[key])
                        for key, bound in (("accessToken", 32768), ("idToken", 16384))),
                "invalid transient directory proof")
        self.state, self.proof_checks = "proving", 1
        result = subprocess.run(
            [self.go_bin, "run", "./cmd/verify-entra-principal", "--fresh-proof-stdin",
             "--owner-file", str(self.owner_path), "--receipt-file", str(self.receipt_path),
             "--directory-config-file", self.manifest["runtimeConfigFile"], "--callback", self.target["callback"]],
            input=json.dumps({"challenge": self.challenge_value, **value}), capture_output=True, text=True,
            cwd=self.root / "bff", timeout=60)
        require(result.returncode == 0 and not self.cancelled.is_set(), "fresh directory authentication proof rejected")
        try:
            evidence = json.loads(result.stdout)
            require(all(evidence.get(key) is True for key in PROOF_FIELDS)
                    and evidence.get("rawProofPersisted") is False and evidence.get("grantsApplied") is False,
                    "fresh directory authentication evidence incomplete")
        except (ValueError, TypeError, AttributeError):
            raise GateError("fresh directory authentication evidence incomplete") from None
        self.fresh_verified = True
        account = self._request("POST", "/v1/identity/register", token=value["accessToken"],
                                body={"challenge": self.challenge_value, "idToken": value["idToken"]})
        session = self._request("GET", "/v1/session", token=value["accessToken"])
        require(isinstance(account.get("accountId"), str) and HEX_ID.fullmatch(account["accountId"])
                and isinstance(account.get("personalScopeId"), str) and HEX_ID.fullmatch(account["personalScopeId"])
                and isinstance(account.get("currentIdentityId"), str) and HEX_ID.fullmatch(account["currentIdentityId"])
                and type(account.get("identityGeneration")) is int
                and 1 <= account["identityGeneration"] <= 10000
                and session.get("principalId") == account["accountId"]
                and session.get("scopeId") == account.get("personalScopeId")
                and type(session.get("identityGeneration")) is int
                and session["identityGeneration"] == account["identityGeneration"]
                and session.get("identityId") == account.get("currentIdentityId")
                and session.get("scopeMode") == "user", "registered account and verified session differ")
        self.registration_verified = True
        self.state = "complete"
        self.token = self.challenge_value = None
        return {"freshAuthenticationVerified": True, "directoryRegistrationVerified": True}

    def evidence(self):
        return {
            "freshIdentityProofVerified": self.fresh_verified,
            "serverChallengeProvenanceVerified": self.server_challenge_verified,
            "directoryConfigurationSha256": self.configuration_digest,
            "directoryEndpointSha256": self.ledger.endpoint_hash,
            "directoryHostingCandidateSha256": config_digest(self.manifest["hosting"]),
            "directoryRegistrationVerified": self.registration_verified,
            "directoryProofProtocolRequests": self.requests,
            "directoryMetadataOperationsReserved": self.metadata_reserved,
            "directoryMetadataOperationsAcknowledged": self.metadata_acknowledged,
            "authorizationInitializationsReserved": self.authorization_reserved,
            "freshProofChecks": self.proof_checks, "directoryWriteOutcomeUnknown": self.unknown_outcome,
            "aggregateProtocolRequestsObservedAtLastReservation": self.aggregate_requests,
            "acceptedAppDocumentMutations": 0, "rawFreshProofPersisted": False,
        }

    def close(self):
        self.cancelled.set()
        self.token = self.challenge_value = None
        if self.state != "complete":
            self.state = "closed"
