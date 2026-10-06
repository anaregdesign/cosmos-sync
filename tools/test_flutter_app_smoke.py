"""Negative tests for exact physical/emulator fixture and network boundaries."""
import argparse
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import flutter_app_smoke as smoke


class AndroidAppBoundaryTest(unittest.TestCase):
    def arguments(self):
        return argparse.Namespace(authorize_install=True,
                                  device_id_file=str(smoke.Path(__file__).resolve().parents[1] / ".cache/devices/test.txt"),
                                  output=str(smoke.Path(__file__).resolve().parents[1] / "artifacts/test.json"))

    def result(self, stdout="", status=0):
        return subprocess.CompletedProcess([], status, stdout, "")

    def test_unapproved_install_is_rejected_before_any_tool_or_file_read(self):
        args = argparse.Namespace(authorize_install=False)
        with patch.object(smoke, "invoke") as invoke, patch.object(smoke, "private_android_identity") as read:
            with self.assertRaises(smoke.ValidationError):
                smoke.android_target(args, "flutter")
            invoke.assert_not_called()
            read.assert_not_called()

    def test_private_file_mode_and_evidence_destination_fail_before_discovery(self):
        with patch.object(smoke, "selected_identity", return_value="private-device"):
            with patch.object(smoke.Path, "stat", return_value=type("FileStat", (), {"st_mode": stat.S_IFREG | 0o644})()):
                with self.assertRaises(smoke.ValidationError):
                    smoke.private_android_identity(self.arguments().device_id_file)
        args = self.arguments()
        args.output = str(Path(__file__).resolve().parents[1] / "README.md")
        with patch.object(smoke, "private_android_identity", return_value="private-device"):
            with patch.object(smoke, "invoke") as invoke:
                with self.assertRaises(smoke.ValidationError):
                    smoke.android_target(args, "flutter")
                invoke.assert_not_called()

    def test_requires_supported_exact_physical_android(self):
        base = {"id": "private-device", "emulator": False, "isSupported": True,
                "targetPlatform": "android-arm64"}
        rows = ([dict(base, emulator=True)], [dict(base, targetPlatform="ios")],
                [dict(base, id="other-device")], [base, base], [dict(base, isSupported=False)])
        for devices in rows:
            with self.subTest(devices=devices):
                with patch.object(smoke, "private_android_identity", return_value="private-device"):
                    with patch.object(smoke, "invoke", return_value=self.result(json.dumps(devices))):
                        with self.assertRaises(smoke.ValidationError):
                            smoke.android_target(self.arguments(), "flutter")

    def test_accepts_exact_supported_target_with_fresh_ignored_output(self):
        device = {"id": "private-device", "emulator": False, "isSupported": True,
                  "targetPlatform": "android-arm64"}
        with patch.object(smoke, "private_android_identity", return_value="private-device"):
            with patch.object(smoke, "invoke", return_value=self.result(json.dumps([device]))):
                self.assertEqual(smoke.android_target(self.arguments(), "flutter"), ("private-device", device))

    def test_emulator_mode_never_selects_a_physical_or_ambiguous_target(self):
        base = {"id": "emulator-5556", "emulator": True, "isSupported": True,
                "targetPlatform": "android-arm64"}
        rows = ([dict(base, emulator=False)], [dict(base, emulator="true")],
                [dict(base, targetPlatform="ios")], [dict(base, id="emulator-5558")],
                [base, base], [dict(base, isSupported=False)], {"devices": [base]}, [None])
        for devices in rows:
            with self.subTest(devices=devices):
                with patch.object(smoke, "private_android_identity", return_value="emulator-5556"):
                    with patch.object(smoke, "invoke", return_value=self.result(json.dumps(devices))):
                        with self.assertRaises(smoke.ValidationError):
                            smoke.android_target(self.arguments(), "flutter", emulator=True)

    def test_exact_supported_emulator_is_distinct_from_physical_scope(self):
        device = {"id": "emulator-5556", "emulator": True, "isSupported": True,
                  "targetPlatform": "android-arm64"}
        with patch.object(smoke, "private_android_identity", return_value="emulator-5556"):
            with patch.object(smoke, "invoke", return_value=self.result(json.dumps([device]))):
                self.assertEqual(smoke.android_target(self.arguments(), "flutter", emulator=True),
                                 ("emulator-5556", device))
                with self.assertRaises(smoke.ValidationError):
                    smoke.android_target(self.arguments(), "flutter")

    def test_emulator_mode_retains_install_and_private_evidence_gates(self):
        with patch.object(smoke, "invoke") as invoke, patch.object(smoke, "private_android_identity") as read:
            with self.assertRaises(smoke.ValidationError):
                smoke.android_target(argparse.Namespace(authorize_install=False), "flutter", emulator=True)
            invoke.assert_not_called()
            read.assert_not_called()
        args = self.arguments()
        args.output = str(Path(__file__).resolve().parents[1] / "README.md")
        with patch.object(smoke, "private_android_identity", return_value="emulator-5556"):
            with patch.object(smoke, "invoke") as invoke:
                with self.assertRaises(smoke.ValidationError):
                    smoke.android_target(args, "flutter", emulator=True)
                invoke.assert_not_called()

    def test_forward_endpoint_rejects_credentials_external_hosts_and_extra_url_parts(self):
        for url in ("https://127.0.0.1:1234", "http://localhost:1234", "http://example.com:1234",
                    "http://secret@127.0.0.1:1234", "http://127.0.0.1", "http://127.0.0.1:1234/path",
                    "http://127.0.0.1:1234?token=secret", "http://127.0.0.1:1234#fragment"):
            with self.subTest(url=url):
                with self.assertRaises(smoke.ValidationError):
                    smoke.fixture_port({"url": url})
        self.assertEqual(smoke.fixture_port({"url": "http://127.0.0.1:1234"}), 1234)

    def test_reverse_is_exact_device_no_rebind_and_cleanup_only_owned_ports(self):
        reverse = smoke.AndroidReverse("private-device")
        responses = [self.result(), self.result(), self.result("transport tcp:2345 tcp:2345\nother tcp:9999 tcp:9999"),
                     self.result(), self.result("transport tcp:1234 tcp:1234"), self.result()]
        with patch.object(smoke, "invoke", side_effect=responses) as invoke:
            reverse.add(1234)
            reverse.add(2345)
            self.assertTrue(reverse.close())
            commands = [call.args[0] for call in invoke.call_args_list]
        self.assertIn("--no-rebind", commands[0])
        self.assertEqual(commands[0][-2:], ["tcp:1234", "tcp:1234"])
        self.assertTrue(all(command[:3] == ["adb", "-s", "private-device"] for command in commands))
        removes = [command[-1] for command in commands if "--remove" in command]
        self.assertEqual(removes, ["tcp:2345", "tcp:1234"])
        self.assertFalse(any("--remove-all" in command for command in commands))

    def test_existing_forward_is_not_claimed_or_removed(self):
        reverse = smoke.AndroidReverse("private-device")
        with patch.object(smoke, "invoke", return_value=self.result("private raw error", status=1)) as invoke:
            with self.assertRaises(smoke.ValidationError) as error:
                reverse.add(1234)
            self.assertNotIn("private raw error", str(error.exception))
            self.assertTrue(reverse.close())
            self.assertEqual(invoke.call_count, 1)

    def test_cleanup_does_not_remove_a_replaced_mapping(self):
        reverse = smoke.AndroidReverse("private-device")
        with patch.object(smoke, "invoke", side_effect=[self.result(), self.result("transport tcp:1234 tcp:7777")]) as invoke:
            reverse.add(1234)
            self.assertFalse(reverse.close())
            self.assertEqual(invoke.call_count, 2)

    def test_invalid_port_does_not_call_adb(self):
        reverse = smoke.AndroidReverse("private-device")
        with patch.object(smoke, "invoke") as invoke:
            for port in (0, -1, 65536, True, "1234"):
                with self.assertRaises(smoke.ValidationError):
                    reverse.add(port)
            invoke.assert_not_called()

    def test_runtime_evidence_discards_secrets_and_nonzero_exit_cannot_verify_storage(self):
        marker = ("COSMOS_SYNC_APP_PASS android realHttp=true realSqlite=true "
                  "auth=test-adapter nativeSecureStorage=verified")
        status = smoke.android_runtime_status(self.result(marker + "\nprivate-device Bearer private-jwt /private/path", status=1))
        self.assertTrue(status["expected_runtime_marker_seen"])
        self.assertFalse(status["native_secure_storage_verified"])
        self.assertEqual(status["exit_code"], 1)
        self.assertNotIn("private", str(status))
        self.assertFalse(smoke.android_runtime_status(self.result(""))["expected_runtime_marker_seen"])

    def test_process_cleanup_targets_only_the_owned_process_group(self):
        from unittest.mock import Mock
        process = Mock(pid=12345)
        process.poll.return_value = None
        with patch.object(smoke.os, "name", "posix"), patch.object(smoke.os, "killpg") as kill:
            smoke.stop_owned_process(process)
            kill.assert_called_once_with(12345, smoke.signal.SIGTERM)
            process.wait.assert_called_once_with(timeout=5)
            process.terminate.assert_not_called()

    def test_prior_evidence_is_preserved_and_rejected_before_discovery(self):
        artifacts = Path(__file__).resolve().parents[1] / "artifacts"
        artifacts.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=artifacts) as directory:
            output = Path(directory) / "prior.json"
            output.write_text("prior evidence")
            args = self.arguments()
            args.output = str(output)
            with patch.object(smoke, "private_android_identity", return_value="private-device"):
                with patch.object(smoke, "invoke") as invoke:
                    with self.assertRaises(smoke.ValidationError):
                        smoke.android_target(args, "flutter")
                    invoke.assert_not_called()
            with self.assertRaises(smoke.ValidationError):
                smoke.write_android_evidence(str(output), {"passed": True})
            self.assertEqual(output.read_text(), "prior evidence")

    def test_evidence_writer_is_private_and_atomic_no_overwrite(self):
        artifacts = Path(__file__).resolve().parents[1] / "artifacts"
        artifacts.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=artifacts) as directory:
            output = Path(directory) / "new.json"
            smoke.write_android_evidence(str(output), {"passed": True})
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(json.loads(output.read_text()), {"passed": True})
            with patch.object(smoke, "evidence_destination", return_value=output):
                with self.assertRaises(smoke.ValidationError):
                    smoke.write_android_evidence(str(output), {"passed": False})
            self.assertEqual(json.loads(output.read_text()), {"passed": True})

    def test_process_cleanup_failure_does_not_skip_control_reverse_cleanup(self):
        from unittest.mock import Mock
        control, worker, reverse = Mock(), Mock(), Mock()
        worker.is_alive.return_value = False
        reverse.close.return_value = True
        with patch.object(smoke, "stop_owned_process", side_effect=subprocess.TimeoutExpired("private", 5)):
            result = smoke.cleanup_fixture(None, control, worker, reverse)
        self.assertFalse(result["owned_process_cleanup_passed"])
        self.assertTrue(result["control_cleanup_passed"])
        self.assertTrue(result["owned_reverse_cleanup_passed"])
        control.shutdown.assert_called_once()
        control.server_close.assert_called_once()
        reverse.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
