import copy
import io
import json
import unittest

from terraform_config_contract import extract_configuration


class TerraformConfigurationContractTests(unittest.TestCase):
    def fixture(self):
        return [
            {"type": "test_plan", "@testfile": "tests/directory.tftest.hcl",
             "@testrun": "directory_configuration_contract", "test_plan": {
                 "output_changes": {"runtime_config": {
                     "after": {"storage": "cosmos", "development": False, "grants": [],
                               "authorization": {"mode": "directory", "directory": {}}},
                     "after_unknown": False, "after_sensitive": False}}}},
            {"type": "test_summary",
             "test_summary": {"status": "pass", "passed": 30, "failed": 0, "errored": 0}},
        ]

    def extract(self, events):
        return extract_configuration(io.StringIO("\n".join(json.dumps(value) for value in events)))

    def test_only_exact_known_nonsecret_contract_output_is_extracted(self):
        events = self.fixture()
        unrelated = copy.deepcopy(events[0])
        unrelated["@testrun"] = "other_run"
        unrelated["test_plan"]["output_changes"]["runtime_config"]["after"] = {"secret": "NOT_FOR_OUTPUT"}
        actual = self.extract([unrelated] + events)
        self.assertEqual(actual, events[0]["test_plan"]["output_changes"]["runtime_config"]["after"])
        self.assertNotIn("NOT_FOR_OUTPUT", json.dumps(actual))

    def test_failure_missing_duplicate_unknown_and_sensitive_outputs_are_rejected(self):
        cases = [[], self.fixture()[:1], self.fixture()[1:],
                 self.fixture() + self.fixture(), [None]]
        for name, value in (("after_unknown", True), ("after_unknown", {"field": True}),
                            ("after_sensitive", True), ("after_sensitive", {"field": True})):
            events = self.fixture()
            events[0]["test_plan"]["output_changes"]["runtime_config"][name] = value
            cases.append(events)
        for changes in ({"status": "fail"}, {"failed": 1}, {"errored": 1}):
            events = self.fixture()
            events[1]["test_summary"].update(changes)
            cases.append(events)
        for changes in ({"storage": "memory"}, {"development": True}, {"grants": [{}]},
                        {"authorization": {"mode": "builtin"}}):
            events = self.fixture()
            events[0]["test_plan"]["output_changes"]["runtime_config"]["after"].update(changes)
            cases.append(events)
        for events in cases:
            with self.subTest(events=events), self.assertRaises(ValueError):
                self.extract(events)

    def test_invalid_or_oversized_event_is_rejected(self):
        for value in ("{", " " * (8 * 1024 * 1024 + 1)):
            with self.subTest(size=len(value)), self.assertRaises(ValueError):
                extract_configuration(io.StringIO(value))


if __name__ == "__main__":
    unittest.main()
