"""Meaningful negative tests for the physical-device mutation boundary."""

import argparse
from contextlib import redirect_stdout
import io
import json
import subprocess
import unittest
from unittest.mock import patch

import device_validation as validation


class PhysicalDeviceBoundaryTest(unittest.TestCase):
    def device(self, **changes):
        return {"id": "private-test-device", "emulator": False, "isSupported": True,
                "targetPlatform": "android-arm64", **changes}

    def test_refuses_unapproved_install_before_any_tool_call(self):
        arguments = argparse.Namespace(authorize_install=False)
        with patch.object(validation, "invoke") as invoke:
            with self.assertRaises(validation.ValidationError):
                validation.run_fixture(arguments)
            invoke.assert_not_called()

    def test_refuses_simulator_even_when_id_explicitly_matches(self):
        with self.assertRaises(validation.ValidationError):
            validation.select_physical_device([self.device(emulator=True)], "private-test-device", "android")

    def test_refuses_unknown_physical_status(self):
        device = self.device()
        del device["emulator"]
        with self.assertRaises(validation.ValidationError):
            validation.select_physical_device([device], "private-test-device", "android")

    def test_refuses_wrong_platform_or_duplicate_identity(self):
        for devices, platform in (([self.device()], "ios"), ([self.device(), self.device()], "android")):
            with self.subTest(platform=platform, count=len(devices)):
                with self.assertRaises(validation.ValidationError):
                    validation.select_physical_device(devices, "private-test-device", platform)

    def test_accepts_exact_supported_physical_identity(self):
        device = self.device()
        self.assertIs(validation.select_physical_device([device], "private-test-device", "android"), device)

    def test_inventory_omits_serial_names_and_hostnames(self):
        raw = "List of devices attached\nsecret-serial device model:Pixel_9 transport_id:2\n"
        data = validation.parse_android_inventory(raw)
        self.assertEqual(data, [{"platform": "android", "physical": True,
                                 "model": "Pixel_9", "connection_state": "device"}])
        apple = validation.parse_apple_inventory({"result": {"devices": [{
            "identifier": "secret-udid", "name": "Owner's iPhone", "hostname": "private.local",
            "visibilityClass": "simulators", "properties": {
                "hardware": {"platform": "iOS", "deviceType": "iPhone", "marketingName": "iPhone 17"}
            }
        }]}})
        self.assertFalse(apple[0]["physical"])
        self.assertNotIn("secret", str(apple))
        self.assertNotIn("Owner", str(apple))
        self.assertNotIn("private.local", str(apple))

    def test_identity_file_and_evidence_cannot_overwrite_repository_sources(self):
        with self.assertRaises(validation.ValidationError):
            validation.selected_identity(str(validation.REPO / "README.md"))
        with self.assertRaises(validation.ValidationError):
            validation.write_evidence(str(validation.REPO / "README.md"), {"passed": True})

    def test_refuses_unapproved_ios_team_before_device_discovery(self):
        arguments = argparse.Namespace(authorize_install=True, device_id_file="unused",
                                       output=str(validation.REPO / "artifacts" / "test.json"),
                                       platform="ios", signing_team=None, authorize_apple_provisioning=True)
        with patch.object(validation, "selected_identity", return_value="private-test-device"):
            with patch.object(validation, "invoke") as invoke:
                with self.assertRaises(validation.ValidationError):
                    validation.run_fixture(arguments)
                invoke.assert_not_called()

    def test_refuses_unapproved_apple_portal_changes_before_any_tool_call(self):
        arguments = argparse.Namespace(authorize_install=True, platform="ios", authorize_apple_provisioning=False)
        with patch.object(validation, "invoke") as invoke:
            with self.assertRaises(validation.ValidationError):
                validation.run_fixture(arguments)
            invoke.assert_not_called()

    def test_ios_resolves_effective_runner_debug_team_instead_of_release_literal(self):
        wrong_debug = json.dumps([{"target": "Runner", "buildSettings": {
            "CONFIGURATION": "Debug", "DEVELOPMENT_TEAM": "B123456789",
            "PLATFORM_NAME": "iphoneos", "SDK_NAME": "iphoneos26.5"
        }}, {"target": "ReleaseOnly", "buildSettings": {
            "CONFIGURATION": "Release", "DEVELOPMENT_TEAM": "A123456789"
        }}])
        result = subprocess.CompletedProcess([], 0, wrong_debug, "")
        with patch.object(validation, "invoke", return_value=result) as invoke:
            with self.assertRaises(validation.ValidationError):
                validation.require_ios_team("A123456789")
            command = invoke.call_args.args[0]
            self.assertIn("-showBuildSettings", command)
            self.assertIn("Debug", command)
            self.assertEqual(command[command.index("-sdk") + 1], "iphoneos")
            self.assertNotIn("-allowProvisioningUpdates", command)

    def test_ios_refuses_missing_or_unresolved_effective_team(self):
        for team in (None, "$(OTHER_TEAM)"):
            with self.subTest(team=team):
                rows = [{"target": "Runner", "buildSettings": {
                    "CONFIGURATION": "Debug", "DEVELOPMENT_TEAM": team,
                    "PLATFORM_NAME": "iphoneos", "SDK_NAME": "iphoneos26.5"
                }}]
                with patch.object(validation, "invoke", return_value=subprocess.CompletedProcess([], 0, json.dumps(rows), "")):
                    with self.assertRaises(validation.ValidationError):
                        validation.require_ios_team("A123456789")

    def test_ios_accepts_only_approved_effective_physical_debug_settings(self):
        for sdk, should_pass in (("iphoneos", True), ("iphonesimulator", False)):
            with self.subTest(sdk=sdk):
                rows = [{"target": "Runner", "buildSettings": {
                    "CONFIGURATION": "Debug", "DEVELOPMENT_TEAM": "A123456789",
                    "PLATFORM_NAME": sdk, "SDK_NAME": sdk + "26.5"
                }}]
                with patch.object(validation, "invoke", return_value=subprocess.CompletedProcess([], 0, json.dumps(rows), "")):
                    if should_pass:
                        validation.require_ios_team("A123456789")
                    else:
                        with self.assertRaises(validation.ValidationError):
                            validation.require_ios_team("A123456789")

    def test_runtime_evidence_omits_identity_names_and_raw_credentials(self):
        arguments = argparse.Namespace(authorize_install=True, device_id_file="unused",
                                       output=str(validation.REPO / "artifacts" / "test.json"),
                                       platform="android", signing_team=None, timeout_seconds=1200)
        device = self.device(name="Owner private phone", sdk="Android 15 API 35")
        result = lambda output, status=0: subprocess.CompletedProcess([], status, output, "")
        responses = [result(json.dumps([device])), result(json.dumps({"frameworkVersion": "3.44.6"})),
                     result("a" * 40), result(" M examples/flutter_smoke/ios/Runner.xcodeproj/project.pbxproj\n"),
                     result("COSMOS_SYNC_NATIVE_PASS android\nBearer private-token\n")]
        captured = io.StringIO()
        with patch.object(validation, "selected_identity", return_value="private-test-device"):
            with patch.object(validation, "invoke", side_effect=responses):
                with patch.object(validation, "write_evidence") as write:
                    with redirect_stdout(captured):
                        self.assertEqual(validation.run_fixture(arguments), 0)
                    evidence = write.call_args.args[1]
        self.assertTrue(evidence["physical_device"])
        self.assertTrue(evidence["source_tree_dirty"])
        self.assertFalse(evidence["live_azure"])
        for secret in ("private-test-device", "Owner private phone", "private-token"):
            self.assertNotIn(secret, captured.getvalue())
            self.assertNotIn(secret, str(evidence))

    def test_nonzero_fixture_exit_cannot_record_a_pass_from_marker_alone(self):
        arguments = argparse.Namespace(authorize_install=True, device_id_file="unused",
                                       output=str(validation.REPO / "artifacts" / "test.json"),
                                       platform="android", signing_team=None, timeout_seconds=1200)
        result = lambda output, status=0: subprocess.CompletedProcess([], status, output, "")
        responses = [result(json.dumps([self.device()])), result("{}"), result("a" * 40), result(""),
                     result("COSMOS_SYNC_NATIVE_PASS android", status=1)]
        with patch.object(validation, "selected_identity", return_value="private-test-device"):
            with patch.object(validation, "invoke", side_effect=responses):
                with patch.object(validation, "write_evidence") as write:
                    with redirect_stdout(io.StringIO()):
                        self.assertEqual(validation.run_fixture(arguments), 1)
                    self.assertFalse(write.call_args.args[1]["passed"])


if __name__ == "__main__":
    unittest.main()
