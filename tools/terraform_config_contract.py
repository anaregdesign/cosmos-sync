#!/usr/bin/env python3
"""Extract only the known, nonsecret directory runtime from passing mock plans."""
import json
import sys


def extract_configuration(stream):
    configuration = None
    summary = None
    for line in stream:
        if len(line) > 8 * 1024 * 1024:
            raise ValueError("terraform_configuration_contract_failed")
        event = json.loads(line)
        if not isinstance(event, dict):
            raise ValueError("terraform_configuration_contract_failed")
        if event.get("type") == "test_plan" and (
                event.get("@testfile") == "tests/directory.tftest.hcl"
                and event.get("@testrun") == "directory_configuration_contract"):
            if configuration is not None:
                raise ValueError("terraform_configuration_contract_failed")
            output = event.get("test_plan", {}).get("output_changes", {}).get("runtime_config", {})
            if output.get("after_unknown") is not False or output.get("after_sensitive") is not False:
                raise ValueError("terraform_configuration_contract_failed")
            configuration = output.get("after")
        if event.get("type") == "test_summary":
            if summary is not None:
                raise ValueError("terraform_configuration_contract_failed")
            summary = event.get("test_summary")
    if (not isinstance(summary, dict) or summary.get("status") != "pass"
            or summary.get("failed") != 0 or summary.get("errored") != 0
            or not isinstance(configuration, dict)
            or configuration.get("storage") != "cosmos"
            or configuration.get("development") is not False
            or configuration.get("grants") != []
            or not isinstance(configuration.get("authorization"), dict)
            or configuration["authorization"].get("mode") != "directory"):
        raise ValueError("terraform_configuration_contract_failed")
    return configuration


if __name__ == "__main__":
    try:
        json.dump(extract_configuration(sys.stdin), sys.stdout)
        sys.stdout.write("\n")
    except (ValueError, TypeError, AttributeError, OSError):
        print("terraform_configuration_contract_failed", file=sys.stderr)
        raise SystemExit(1)
