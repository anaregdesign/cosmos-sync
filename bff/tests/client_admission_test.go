package integration

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
)

const nativeClientID = "abcdef01-0000-0000-0000-000000000001"
const secondNativeClientID = "abcdef01-0000-0000-0000-000000000002"

func TestConfiguredClientAdmissionRequiresExactSignedAuthorizedParty(t *testing.T) {
	api := newTestAPI(t, nil, func(config *syncbff.Config) {
		config.OIDC.AllowedClientIDs = []string{nativeClientID, secondNativeClientID}
	})
	tests := []struct {
		name   string
		claims map[string]any
		status int
	}{
		{"allowed-first", map[string]any{"azp": nativeClientID}, 200},
		{"allowed-second", map[string]any{"azp": secondNativeClientID}, 200},
		{"disallowed", map[string]any{"azp": "another-client"}, 403},
		{"missing", nil, 403},
		{"null", map[string]any{"azp": json.RawMessage("null")}, 403},
		{"empty", map[string]any{"azp": ""}, 403},
		{"number", map[string]any{"azp": 7}, 403},
		{"boolean", map[string]any{"azp": true}, 403},
		{"array", map[string]any{"azp": []string{nativeClientID}}, 403},
		{"object", map[string]any{"azp": map[string]any{"clientId": nativeClientID}}, 403},
		{"case-mismatch", map[string]any{"azp": strings.ToUpper(nativeClientID)}, 403},
		{"prefix", map[string]any{"azp": "prefix-" + nativeClientID}, 403},
		{"suffix", map[string]any{"azp": nativeClientID + "-suffix"}, 403},
		{"leading-space", map[string]any{"azp": " " + nativeClientID}, 403},
		{"appid-does-not-replace-azp", map[string]any{"appid": nativeClientID}, 403},
		{"appid-does-not-override-azp", map[string]any{"appid": nativeClientID, "azp": "another-client"}, 403},
		{"allowed-client-wrong-issuer", map[string]any{"azp": nativeClientID, "iss": "https://attacker.example.test"}, 401},
		{"allowed-client-wrong-audience", map[string]any{"azp": nativeClientID, "aud": "another-api"}, 401},
		{"allowed-client-expired", map[string]any{"azp": nativeClientID, "exp": time.Now().Add(-time.Hour).Unix()}, 401},
		{"allowed-client-future-nbf", map[string]any{"azp": nativeClientID, "nbf": time.Now().Add(time.Hour).Unix()}, 401},
		{"allowed-client-id-token-without-scope", map[string]any{"azp": nativeClientID, "scp": nil}, 403},
		{"allowed-client-wrong-scope", map[string]any{"azp": nativeClientID, "scp": "cosmos_sync_admin"}, 403},
		{"allowed-client-no-grant", map[string]any{"azp": nativeClientID, "sub": "unknown"}, 403},
		{"allowed-client-revoked-grant", map[string]any{"azp": nativeClientID, "sub": "revoked"}, 403},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response := api.request(t, api.issuer.token(t, test.claims), http.MethodGet, "/v1/session", nil)
			if test.status == 403 {
				errorCode(t, response, http.StatusForbidden, "forbidden")
			} else {
				status(t, response, test.status)
			}
		})
	}
	valid := api.issuer.token(t, map[string]any{"azp": nativeClientID})
	parts := strings.Split(valid, ".")
	parts[2] = strings.Repeat("A", len(parts[2]))
	errorCode(t, api.request(t, strings.Join(parts, "."), http.MethodGet, "/v1/session", nil), 401, "unauthorized")
}

func TestEmptyClientAdmissionPreservesExistingIssuerPolicy(t *testing.T) {
	issuer := newOIDCIssuer(t)
	for _, ids := range [][]string{nil, {}} {
		api := newTestAPI(t, issuer, func(config *syncbff.Config) {
			config.OIDC.AllowedClientIDs = ids
		})
		for _, claims := range []map[string]any{nil, {"azp": "another-client"}, {"azp": []string{"another-client"}}} {
			status(t, api.request(t, issuer.token(t, claims), http.MethodGet, "/v1/session", nil), 200)
		}
	}
}

type clientAdmissionStore struct {
	*syncbff.MemoryStore
	registrations int
}

func (store *clientAdmissionStore) EnsureAccount(ctx context.Context, identity syncbff.AccountIdentity) (syncbff.Account, error) {
	store.registrations++
	return store.MemoryStore.EnsureAccount(ctx, identity)
}

func TestClientAdmissionPrecedesBuiltinRegistrationAndDoesNotChangeAccountIdentity(t *testing.T) {
	api := newTestAPI(t, nil, func(config *syncbff.Config) {
		config.Grants = nil
		config.Authorization.Mode = "builtin"
		config.OIDC.AllowedClientIDs = []string{nativeClientID, secondNativeClientID}
	})
	store := &clientAdmissionStore{MemoryStore: syncbff.NewMemoryStore()}
	handler, err := syncbff.NewServer(api.config, store, api.issuer.verifier(t))
	if err != nil {
		t.Fatal(err)
	}
	api.handler = handler
	for _, path := range []string{"/v1/account", "/v1/session"} {
		for _, claims := range []map[string]any{nil, {"azp": "another-client"}} {
			errorCode(t, api.requestRaw(t, api.issuer.token(t, claims), http.MethodGet, path, nil, false), 403, "forbidden")
		}
	}
	if store.registrations != 0 {
		t.Fatal("rejected client reached persistent account registration")
	}
	first := builtinAccount(t, api, api.issuer.token(t, map[string]any{"azp": nativeClientID}))
	second := builtinAccount(t, api, api.issuer.token(t, map[string]any{"azp": secondNativeClientID}))
	if first != second || store.registrations != 2 {
		t.Fatal("client admission must preserve the verified issuer/subject account identity")
	}
}

func TestClientAdmissionConfigurationIsBoundedAndCopied(t *testing.T) {
	api := newTestAPI(t, nil, func(config *syncbff.Config) {
		config.OIDC.AllowedClientIDs = []string{nativeClientID}
	})
	api.config.OIDC.AllowedClientIDs[0] = "mutated-after-construction"
	status(t, api.request(t, api.issuer.token(t, map[string]any{"azp": nativeClientID}), http.MethodGet, "/v1/session", nil), 200)
	errorCode(t, api.request(t, api.issuer.token(t, map[string]any{"azp": "mutated-after-construction"}), http.MethodGet, "/v1/session", nil), 403, "forbidden")

	tooMany := make([]string, 33)
	for index := range tooMany {
		tooMany[index] = fmt.Sprintf("client-%d", index)
	}
	for _, ids := range [][]string{{""}, {"has space"}, {"has\nnewline"}, {"non-ascii-\u00e9"}, {strings.Repeat("x", 257)}, {nativeClientID, nativeClientID}, tooMany} {
		config := api.config
		config.OIDC.AllowedClientIDs = ids
		if _, err := syncbff.NewServer(config, api.store, api.issuer.verifier(t)); err == nil {
			t.Fatal("invalid client admission configuration accepted at server startup")
		}
		if _, err := syncbff.NewOIDCVerifier(context.Background(), config.OIDC); err == nil {
			t.Fatal("invalid client admission configuration accepted before discovery")
		}
	}
}
