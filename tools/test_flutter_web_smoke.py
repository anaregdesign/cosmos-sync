import unittest

from flutter_web_smoke import EXPECTED_FLAGS, valid_checkpoint, valid_result


class FlutterWebSmokeTests(unittest.TestCase):
    def test_checkpoint_is_only_one_bounded_opaque_operation_id(self):
        self.assertTrue(valid_checkpoint({"operation": "a" * 32}))
        for value in [
            {}, {"operation": "../outside"}, {"operation": "a" * 129},
            {"operation": 42}, {"operation": "a" * 32, "token": "not-accepted"},
        ]:
            self.assertFalse(valid_checkpoint(value))

    def test_success_requires_every_measured_flag_and_an_observed_reload(self):
        success = dict.fromkeys(EXPECTED_FLAGS, True)
        success["auth"] = "signed_test_issuer_adapter"
        self.assertTrue(valid_result(success, True))
        self.assertFalse(valid_result(success, False))
        for flag in EXPECTED_FLAGS:
            self.assertFalse(valid_result({**success, flag: False}, True))
            self.assertFalse(valid_result({**success, flag: "true"}, True))
        self.assertFalse(valid_result({**success, "auth": "real_oidc"}, True))
        self.assertFalse(valid_result({**success, "token": "not-accepted"}, True))


if __name__ == "__main__":
    unittest.main()
