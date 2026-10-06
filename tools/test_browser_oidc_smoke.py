import unittest

from browser_oidc_smoke import (
    APP_FLAGS, PROTOCOL_CHECKS, valid_app, valid_counters, valid_protocol, valid_ready,
)


class BrowserOIDCSmokeTests(unittest.TestCase):
    def test_readiness_has_only_public_exact_owned_loopback_configuration(self):
        origin = "http://127.0.0.1:8123"
        ready = {
            "url": "http://127.0.0.1:8124",
            "issuer": "https://127.0.0.1:8125",
            "clientId": "non-uuid-browser-public-client",
            "redirectUrl": origin + "/oidc-redirect.html",
            "scopes": ["openid", "offline_access", "cosmos_sync"],
            "discoveryUrl": "https://127.0.0.1:8125/.well-known/openid-configuration",
            "certificate": "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n",
            "spki": "a" * 43 + "=",
        }
        self.assertTrue(valid_ready(ready, origin))
        for changes in [
            {"token": "must-not-be-injected"},
            {"issuer": "http://127.0.0.1:8125"},
            {"url": "http://remote.example.test:8124"},
            {"url": "http://user:private@127.0.0.1:8124"},
            {"redirectUrl": origin + "/auth-redirect.html"},
            {"redirectUrl": origin + "/oidc-redirect.html?code=must-not-be-retained"},
            {"discoveryUrl": "https://127.0.0.1:8126/.well-known/openid-configuration"},
            {"clientId": "different-client"},
            {"spki": "--ignore-certificate-errors"},
            {"certificate": "not-a-certificate"},
        ]:
            self.assertFalse(valid_ready({**ready, **changes}, origin))
        self.assertFalse(valid_ready(ready, "http://127.0.0.1:9123"))

    def test_protocol_requires_all_real_adapter_checks_and_no_unknown_fields(self):
        value = {
            "passed": True, "checks": list(PROTOCOL_CHECKS), "auth": "actual_generic_oidc_popup",
        }
        self.assertTrue(valid_protocol(value))
        for changes in [
            {"passed": "true"}, {"checks": list(PROTOCOL_CHECKS[:-1])},
            {"checks": list(PROTOCOL_CHECKS) + [PROTOCOL_CHECKS[0]]},
            {"checks": list(reversed(PROTOCOL_CHECKS))}, {"auth": "signed_test_issuer_adapter"},
            {"token": "must-not-be-reported"},
        ]:
            self.assertFalse(valid_protocol({**value, **changes}))

    def test_app_requires_observed_document_reload_and_account_cache_isolation(self):
        value = dict.fromkeys(APP_FLAGS, True)
        value["auth"] = "actual_generic_oidc_popup"
        self.assertTrue(valid_app(value, True))
        self.assertFalse(valid_app(value, False))
        for flag in APP_FLAGS:
            self.assertFalse(valid_app({**value, flag: False}, True))
            self.assertFalse(valid_app({**value, flag: "true"}, True))
        self.assertFalse(valid_app({**value, "auth": "signed_test_issuer_adapter"}, True))
        self.assertFalse(valid_app({**value, "token": "must-not-be-reported"}, True))

    def test_success_requires_independent_bounded_server_observation_not_browser_flags(self):
        counts = {
            "authorization_requests": 15, "code_exchanges": 13,
            "pkce_verified": 10, "refresh_exchanges": 3, "jwks_requests": 10,
        }
        self.assertTrue(valid_counters(counts))
        for name, value in counts.items():
            self.assertFalse(valid_counters({**counts, name: value - 1}))
            self.assertFalse(valid_counters({**counts, name: True}))
            self.assertFalse(valid_counters({**counts, name: str(value)}))
        self.assertFalse(valid_counters({**counts, "token": "must-not-be-reported"}))
        self.assertFalse(valid_counters({**counts, "jwks_requests": 1001}))


if __name__ == "__main__":
    unittest.main()
