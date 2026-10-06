import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

from device_validation import ValidationError
import flutter_restart_smoke as restart


class RestartBoundaryTests(unittest.TestCase):
    def test_exclusive_assertion_precedes_any_device_or_package_operation(self):
        with patch.object(restart, "android_target") as target:
            with self.assertRaises(ValidationError):
                restart.run(argparse.Namespace(exclusive_emulator=False), Path("."))
            target.assert_not_called()

    def test_existing_package_is_never_replaced_or_cleared(self):
        args = argparse.Namespace(exclusive_emulator=True, flutter_bin="flutter")
        with patch.object(restart, "android_target", return_value=("emulator-5556", {})), \
                patch.object(restart, "adb", side_effect=["1", "package:" + restart.APP_ID]) as adb:
            with self.assertRaises(ValidationError):
                restart.run(args, Path("."))
            self.assertFalse(any("install" in call.args or "clear" in call.args for call in adb.call_args_list))

    def test_ambiguous_pid_is_not_terminated(self):
        with patch.object(restart, "invoke", return_value=subprocess.CompletedProcess([], 0, "123 456", "")), \
                patch.object(restart, "adb") as adb:
            with self.assertRaises(ValidationError):
                restart.terminate_selected_application("emulator-5556", "123")
            adb.assert_not_called()

    def test_only_exact_fixture_process_is_stopped_without_data_clear(self):
        with patch.object(restart, "application_pid", side_effect=["123", None]), \
                patch.object(restart, "adb") as adb:
            restart.terminate_selected_application("emulator-5556", "123")
            adb.assert_called_once_with("emulator-5556", "shell", "run-as", restart.APP_ID, "kill", "-9", "123")

    def test_restart_control_requires_capability_phase_and_true_replay_checks(self):
        with tempfile.TemporaryDirectory() as temporary:
            control = restart.RestartControl(Path(temporary))
            control.start()
            try:
                def post(path, body):
                    request = urllib.request.Request(control.url + path, data=json.dumps(body).encode())
                    try:
                        with urllib.request.urlopen(request, timeout=2) as response:
                            return response.status
                    except urllib.error.HTTPError as error:
                        with error:
                            return error.code

                self.assertEqual(post("replayed", dict.fromkeys(restart.REPLAY_FIELDS, True)), 400)
                self.assertEqual(post("durable", {"operationId": "a" * 36, "scopeId": "b" * 64}), 400)
                value = {"operationId": "11111111-1111-4111-8111-111111111111", "scopeId": "b" * 64}
                self.assertEqual(post("durable", value), 200)
                self.assertEqual(post("durable", value), 400)
                self.assertTrue(control.durable.is_set())
                control.phase = "read"
                self.assertEqual(post("replayed", dict.fromkeys(restart.REPLAY_FIELDS, False)), 400)
                self.assertEqual(post("replayed", dict.fromkeys(restart.REPLAY_FIELDS, True)), 200)
                self.assertEqual(post("replayed", dict.fromkeys(restart.REPLAY_FIELDS, True)), 400)
                self.assertTrue(control.replayed.is_set())
            finally:
                control.close()


if __name__ == "__main__":
    unittest.main()
