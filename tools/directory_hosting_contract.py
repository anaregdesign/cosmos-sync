"""Read back one reviewed directory image/configuration; never deploy or log in."""
import hashlib
import json
import re

from live_azure_preflight import GateError, account_https_origin, az_json, require
from release_verify import IMAGE, SHA

UNSUPPORTED_SOURCES = {
    "82e937c8659e9ec0263a78e6e3ad2f43e05be20a",
    "76c1f46876b3dfd13f4bd7d4dd144cdf74efa5c0",
}
UNSUPPORTED_DIGESTS = {
    "sha256:a23ab75eb4518597aa26e4833787b9b77a07def717868e080944555594adc1b3",
    "sha256:2651a4bca6df6f751b7f5e46d317ea9f6e4ca83081374badae142d57cdfc812a",
}
APP_ID = re.compile(
    r"^/subscriptions/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
    r"/resourceGroups/[A-Za-z0-9_.()-]{1,90}/providers/Microsoft\.App/containerApps/[a-z][a-z0-9-]{1,30}$")


def config_digest(config):
    return hashlib.sha256(json.dumps(config, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def validate_hosting(value):
    require(isinstance(value, dict)
            and set(value) == {"appResourceId", "image", "sourceCommit", "reviewedConfigurationSha256"},
            "exact reviewed hosting candidate required")
    require(isinstance(value["appResourceId"], str) and APP_ID.fullmatch(value["appResourceId"]),
            "exact approved Container App resource ID required")
    require(isinstance(value["sourceCommit"], str) and SHA.fullmatch(value["sourceCommit"])
            and value["sourceCommit"] not in UNSUPPORTED_SOURCES, "compatible full source commit required")
    require(isinstance(value["image"], str)
            and re.fullmatch(re.escape(IMAGE) + r"@sha256:[0-9a-f]{64}", value["image"])
            and value["image"].split("@")[1] not in UNSUPPORTED_DIGESTS,
            "reviewed immutable directory-compatible image required")
    require(isinstance(value["reviewedConfigurationSha256"], str)
            and re.fullmatch(r"[0-9a-f]{64}", value["reviewedConfigurationSha256"]),
            "exact reviewed configuration digest required")
    return value


def assess_readback(hosting, endpoint, config, app, revision):
    validate_hosting(hosting)
    require(isinstance(config, dict) and isinstance(app, dict) and isinstance(revision, dict),
            "directory hosting readback must contain exact objects")
    require(config_digest(config) == hosting["reviewedConfigurationSha256"],
            "runtime configuration differs from the reviewed candidate")
    require(isinstance(app.get("id"), str) and isinstance(app.get("fqdn"), str)
            and app["id"].casefold() == hosting["appResourceId"].casefold()
            and app.get("state") == "Succeeded" and app.get("mode") == "Single"
            and app.get("ready") == app.get("latest") and isinstance(app.get("ready"), str)
            and app["ready"] and app.get("image") == hosting["image"]
            and account_https_origin("https://" + app["fqdn"]) == account_https_origin(endpoint),
            "Container App readback differs from the reviewed candidate")
    traffic = app.get("traffic")
    require(isinstance(traffic, list) and len(traffic) == 1 and isinstance(traffic[0], dict)
            and traffic[0].get("weight") == 100
            and (traffic[0].get("latestRevision") is True or traffic[0].get("revisionName") == app["ready"]),
            "single reviewed ready revision must receive all traffic")
    require(revision.get("active") is True and revision.get("state") == "Provisioned"
            and revision.get("health") == "Healthy" and revision.get("image") == hosting["image"],
            "reviewed ready revision is not healthy/active")
    for record in (app, revision):
        environment = record.get("environment")
        require(isinstance(environment, list), "reviewed runtime environment missing")
        values = [entry.get("value") for entry in environment
                  if isinstance(entry, dict) and entry.get("name") == "COSMOS_SYNC_CONFIG_JSON"]
        require(len(values) == 1 and isinstance(values[0], str) and len(values[0]) <= 65536,
                "exact directory runtime configuration missing")
        try:
            actual = json.loads(values[0])
        except ValueError:
            raise GateError("active directory configuration is not valid JSON") from None
        require(isinstance(actual, dict) and config_digest(actual) == hosting["reviewedConfigurationSha256"],
                "active directory configuration differs from the reviewed source")


def verify_hosting(hosting, endpoint, config):
    validate_hosting(hosting)
    query = ("{id:id,state:properties.provisioningState,mode:properties.configuration.activeRevisionsMode,"
             "ready:properties.latestReadyRevisionName,latest:properties.latestRevisionName,"
             "fqdn:properties.configuration.ingress.fqdn,traffic:properties.configuration.ingress.traffic,"
             "image:properties.template.containers[0].image,environment:properties.template.containers[0].env}")
    url = "https://management.azure.com" + hosting["appResourceId"]
    app = az_json(["rest", "--method", "get", "--url", url + "?api-version=2025-07-01"], query)
    require(isinstance(app, dict) and isinstance(app.get("ready"), str)
            and re.fullmatch(r"[a-z0-9-]+", app["ready"]), "ready revision readback unavailable")
    revision = az_json(["rest", "--method", "get", "--url",
                        url + "/revisions/" + app["ready"] + "?api-version=2025-07-01"],
                       "{active:properties.active,state:properties.provisioningState,"
                       "health:properties.healthState,image:properties.template.containers[0].image,"
                       "environment:properties.template.containers[0].env}")
    require(isinstance(revision, dict), "ready revision readback unavailable")
    assess_readback(hosting, endpoint, config, app, revision)
    return {"imageReadBack": True, "configurationReadBack": True,
            "healthyActiveRevisionReadBack": True, "sourceCommitOperatorReviewed": True,
            "registrySourceLabelsInspected": False, "hostedGraphExecuted": False}
