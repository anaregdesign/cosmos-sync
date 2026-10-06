package integration

import (
	"strings"
	"testing"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
)

func TestStagedIdentityDirectoryDoesNotActivateProductionRoutes(t *testing.T) {
	api := builtinAPI(t)
	token := api.issuer.token(t, nil)
	before := builtinAccount(t, api, token)
	var binding syncbff.Scope
	decode(t, api.request(t, token, "GET", "/v1/session", nil), &binding)
	const sentinel = "UNTRUSTED_LINK_PROOF_MUST_NOT_BE_REFLECTED"
	for _, path := range []string{"/v1/identity/challenges", "/v1/identities/link", "/v1/identities/unlink", "/v1/identity/register"} {
		response := builtinData(t, api.handler, token, "POST", path, binding, map[string]any{
			"accountId": before.AccountID, "providerData": sentinel, "auth_time": 9999999999,
		})
		status(t, response, 404)
		if strings.Contains(response.Body.String(), sentinel) {
			t.Fatal("disabled identity boundary reflected untrusted proof")
		}
	}
	if after := builtinAccount(t, api, token); after != before {
		t.Fatal("inactive directory changed the current account namespace")
	}
	rawProviderToken := api.issuer.token(t, map[string]any{"aud": "provider-client", "scp": nil, "token_use": "id"})
	status(t, api.requestRaw(t, rawProviderToken, "GET", "/v1/account", nil, false), 401)
	status(t, api.requestRaw(t, rawProviderToken, "GET", "/v1/session", nil, false), 401)
}
