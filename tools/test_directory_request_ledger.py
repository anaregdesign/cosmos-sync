from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import tempfile
import unittest

from directory_request_ledger import DirectoryRequestLedger, initialize
from live_azure_preflight import GateError


class DirectoryRequestLedgerTests(unittest.TestCase):
    def test_exclusive_initialization_preserves_measured_prior_attempts_and_aggregate_cap(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "ledger.json"
            initialize(path, "https://fixture.example", 7)
            with self.assertRaises(FileExistsError):
                initialize(path, "https://fixture.example", 0)
            ledger = DirectoryRequestLedger(path, "https://FIXTURE.example/")
            self.assertEqual(ledger.read()["protocolRequests"], 7)
            with ThreadPoolExecutor(max_workers=8) as workers:
                results = list(workers.map(lambda _: ledger.reserve()["protocolRequests"], range(33)))
            self.assertEqual(sorted(results), list(range(8, 41)))
            with self.assertRaises(GateError):
                ledger.reserve()
            self.assertEqual(ledger.read()["protocolRequests"], 40)

    def test_other_target_public_mode_and_symlink_are_rejected_without_reservation(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "ledger.json"
            initialize(path, "https://fixture.example", 7)
            with self.assertRaises(GateError):
                DirectoryRequestLedger(path, "https://other.example")
            link = Path(temporary) / "link"
            link.symlink_to(path)
            with self.assertRaises(GateError):
                DirectoryRequestLedger(link, "https://fixture.example")
            os.chmod(path, 0o644)
            with self.assertRaises(GateError):
                DirectoryRequestLedger(path, "https://fixture.example")
            self.assertEqual(json.loads(path.read_text())["protocolRequests"], 7)

    def test_corrupt_ledger_and_unmeasured_initialization_never_reset_to_zero(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "ledger.json"
            for prior in (None, True, -1, 41):
                with self.assertRaises(GateError):
                    initialize(path, "https://fixture.example", prior)
            initialize(path, "https://fixture.example", 7)
            value = json.loads(path.read_text())
            value["protocolRequests"] = True
            path.write_text(json.dumps(value))
            with self.assertRaises(GateError):
                DirectoryRequestLedger(path, "https://fixture.example")
            self.assertTrue(json.loads(path.read_text())["protocolRequests"])


if __name__ == "__main__":
    unittest.main()
