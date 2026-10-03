package integration

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
)

type testAPI struct {
	handler http.Handler
	issuer  *oidcIssuer
	config  syncbff.Config
	store   syncbff.Store
}

func newTestAPI(t *testing.T, issuer *oidcIssuer, configure func(*syncbff.Config)) *testAPI {
	t.Helper()
	if issuer == nil {
		issuer = newOIDCIssuer(t)
	}
	config := syncbff.Config{
		Development:     true,
		Storage:         "Memory",
		CursorKeyBase64: base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32)),
		OIDC: syncbff.OIDCConfig{
			Issuer: issuer.server.URL, Audience: testAudience,
			TenantClaim: "tid", RequiredScope: "cosmos_sync",
		},
		Grants: []syncbff.Grant{
			{Tenant: "tenant-a", Subject: "alice", PermissionVersion: "permissions-v1", Active: true, CanRead: true, CanWrite: true},
			{Tenant: "tenant-a", Subject: "bob", PermissionVersion: "permissions-v1", Active: true, CanRead: true, CanWrite: true},
			{Tenant: "tenant-b", Subject: "alice", PermissionVersion: "permissions-v1", Active: true, CanRead: true, CanWrite: true},
			{Tenant: "tenant-a", Subject: "reader", PermissionVersion: "permissions-v1", Active: true, CanRead: true, CanWrite: false},
			{Tenant: "tenant-a", Subject: "revoked", PermissionVersion: "permissions-v1", Active: false, CanRead: true, CanWrite: true},
			{Tenant: "tenant-a", Subject: "no-access", PermissionVersion: "permissions-v1", Active: true, CanRead: false, CanWrite: false},
		},
	}
	if configure != nil {
		configure(&config)
	}
	store := syncbff.NewMemoryStore()
	handler, err := syncbff.NewServer(config, store, issuer.verifier(t))
	if err != nil {
		t.Fatal(err)
	}
	return &testAPI{handler: handler, issuer: issuer, config: config, store: store}
}

func (api *testAPI) request(t *testing.T, token, method, endpoint string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var raw []byte
	if body != nil {
		var err error
		raw, err = json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
	}
	return api.requestRaw(t, token, method, endpoint, raw, true)
}

func (api *testAPI) requestRaw(t *testing.T, token, method, endpoint string, raw []byte, bind bool) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(method, "https://api.example.test"+endpoint, bytes.NewReader(raw))
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	if raw != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if bind && endpoint != "/v1/session" && token != "" {
		session := api.requestRaw(t, token, http.MethodGet, "/v1/session", nil, false)
		if session.Code == http.StatusOK {
			var binding struct {
				ScopeID           string `json:"scopeId"`
				PermissionVersion string `json:"permissionVersion"`
				PrincipalID       string `json:"principalId"`
				ScopeMode         string `json:"scopeMode"`
			}
			decode(t, session, &binding)
			request.Header.Set("X-Cosmos-Sync-Scope", binding.ScopeID)
			request.Header.Set("X-Cosmos-Sync-Permission", binding.PermissionVersion)
			request.Header.Set(syncbff.PrincipalHeader, binding.PrincipalID)
			request.Header.Set(syncbff.ScopeModeHeader, binding.ScopeMode)
		}
	}
	recorder := httptest.NewRecorder()
	api.handler.ServeHTTP(recorder, request)
	return recorder
}

func decode(t *testing.T, response *httptest.ResponseRecorder, target any) {
	t.Helper()
	if err := json.Unmarshal(response.Body.Bytes(), target); err != nil {
		t.Fatalf("response %d is not expected JSON: %s (%v)", response.Code, response.Body.String(), err)
	}
}

func status(t *testing.T, response *httptest.ResponseRecorder, expected int) {
	t.Helper()
	if response.Code != expected {
		t.Fatalf("expected HTTP %d, got %d: %s", expected, response.Code, response.Body.String())
	}
}

func errorCode(t *testing.T, response *httptest.ResponseRecorder, expectedStatus int, expectedCode string) {
	t.Helper()
	status(t, response, expectedStatus)
	var body struct {
		Code string `json:"code"`
	}
	decode(t, response, &body)
	if body.Code != expectedCode {
		t.Fatalf("expected error code %q, got %q", expectedCode, body.Code)
	}
}

func mutation(operationID, documentID, kind string, baseVersion int64, data any) map[string]any {
	return map[string]any{
		"operationId": operationID, "documentId": documentID,
		"kind": kind, "baseVersion": baseVersion, "data": data,
	}
}

func operationID(index int) string {
	return fmt.Sprintf("00000000-0000-4000-8000-%012d", index)
}

type document struct {
	ID      string         `json:"id"`
	Data    map[string]any `json:"data"`
	Version int64          `json:"version"`
	Deleted bool           `json:"deleted"`
}

type mutationResponse struct {
	Document document `json:"document"`
}
type syncResponse struct {
	Changes []document `json:"changes"`
	Cursor  string     `json:"cursor"`
	HasMore bool       `json:"hasMore"`
}

func syncPath(cursor string, limit int) string {
	if cursor == "" {
		return "/v1/sync?limit=" + fmt.Sprint(limit)
	}
	return "/v1/sync?cursor=" + url.QueryEscape(cursor) + "&limit=" + fmt.Sprint(limit)
}

func TestSessionBindingPreventsIdentityAndPermissionRaces(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	alice := api.issuer.token(t, nil)
	bob := api.issuer.token(t, map[string]any{"sub": "bob"})
	var expected struct {
		ScopeID           string `json:"scopeId"`
		PermissionVersion string `json:"permissionVersion"`
		PrincipalID       string `json:"principalId"`
		ScopeMode         string `json:"scopeMode"`
	}
	decode(t, api.request(t, alice, http.MethodGet, "/v1/session", nil), &expected)
	for _, endpoint := range []string{"/v1/sync", "/v1/mutations"} {
		method := http.MethodGet
		var raw []byte
		if endpoint == "/v1/mutations" {
			method = http.MethodPost
			raw, _ = json.Marshal(mutation(operationID(1), "note", "put", 0, map[string]any{"owner": "alice"}))
		}
		t.Run("missing-binding-"+endpoint, func(t *testing.T) {
			errorCode(t, api.requestRaw(t, alice, method, endpoint, raw, false), http.StatusForbidden, "session_mismatch")
		})
		t.Run("identity-swapped-"+endpoint, func(t *testing.T) {
			request := httptest.NewRequest(method, "https://api.example.test"+endpoint, bytes.NewReader(raw))
			request.Header.Set("Authorization", "Bearer "+bob)
			request.Header.Set(syncbff.ScopeHeader, expected.ScopeID)
			request.Header.Set(syncbff.PermissionHeader, expected.PermissionVersion)
			request.Header.Set(syncbff.PrincipalHeader, expected.PrincipalID)
			request.Header.Set(syncbff.ScopeModeHeader, expected.ScopeMode)
			recorder := httptest.NewRecorder()
			api.handler.ServeHTTP(recorder, request)
			errorCode(t, recorder, http.StatusForbidden, "session_mismatch")
		})
		t.Run("stale-permission-"+endpoint, func(t *testing.T) {
			request := httptest.NewRequest(method, "https://api.example.test"+endpoint, bytes.NewReader(raw))
			request.Header.Set("Authorization", "Bearer "+alice)
			request.Header.Set(syncbff.ScopeHeader, expected.ScopeID)
			request.Header.Set(syncbff.PermissionHeader, "old-permissions")
			request.Header.Set(syncbff.PrincipalHeader, expected.PrincipalID)
			request.Header.Set(syncbff.ScopeModeHeader, expected.ScopeMode)
			recorder := httptest.NewRecorder()
			api.handler.ServeHTTP(recorder, request)
			errorCode(t, recorder, http.StatusForbidden, "session_mismatch")
		})
	}
	for _, token := range []string{alice, bob} {
		var journal syncResponse
		response := api.request(t, token, http.MethodGet, "/v1/sync", nil)
		status(t, response, http.StatusOK)
		decode(t, response, &journal)
		if len(journal.Changes) != 0 {
			t.Fatal("a rejected identity or permission race wrote to a partition")
		}
	}
}

func TestGrantReloadRevokesActiveTokenAndOldPermissionCursor(t *testing.T) {
	grantFile := filepath.Join(t.TempDir(), "grants.json")
	grant := syncbff.Grant{Tenant: "tenant-a", Subject: "alice", PermissionVersion: "permissions-v1", Active: true, CanRead: true, CanWrite: true}
	writeGrant := func() {
		t.Helper()
		raw, err := json.Marshal([]syncbff.Grant{grant})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(grantFile, raw, 0600); err != nil {
			t.Fatal(err)
		}
	}
	writeGrant()
	api := newTestAPI(t, nil, func(config *syncbff.Config) { config.GrantsFile = grantFile })
	token := api.issuer.token(t, nil)
	var initial syncResponse
	response := api.request(t, token, http.MethodGet, "/v1/sync", nil)
	status(t, response, http.StatusOK)
	decode(t, response, &initial)
	grant.PermissionVersion = "permissions-v2"
	writeGrant()
	errorCode(t, api.request(t, token, http.MethodGet, syncPath(initial.Cursor, 100), nil), http.StatusGone, "resync_required")
	grant.Active = false
	writeGrant()
	status(t, api.request(t, token, http.MethodGet, "/v1/session", nil), http.StatusForbidden)
	status(t, api.request(t, token, http.MethodPost, "/v1/mutations", mutation(operationID(1), "note", "put", 0, map[string]any{"value": 1})), http.StatusForbidden)
	if err := os.WriteFile(grantFile, []byte("not-json"), 0600); err != nil {
		t.Fatal(err)
	}
	errorCode(t, api.request(t, token, http.MethodGet, "/v1/session", nil), http.StatusServiceUnavailable, "grant_store_unavailable")
}

func TestConfiguredTokenUseRejectsIDToken(t *testing.T) {
	api := newTestAPI(t, nil, func(config *syncbff.Config) { config.OIDC.TokenUse = "access" })
	status(t, api.request(t, api.issuer.token(t, map[string]any{"token_use": "access"}), http.MethodGet, "/v1/session", nil), http.StatusOK)
	for _, claims := range []map[string]any{nil, {"token_use": "id"}} {
		status(t, api.request(t, api.issuer.token(t, claims), http.MethodGet, "/v1/session", nil), http.StatusUnauthorized)
	}
}

func TestCanonicalDocumentSizeBoundary(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	token := api.issuer.token(t, nil)
	for index, character := range []string{"a", ">"} {
		data := `{"text":"` + strings.Repeat(character, syncbff.MaxDocumentBytes-11) + `"}`
		body := []byte(fmt.Sprintf(`{"operationId":%q,"documentId":%q,"kind":"put","baseVersion":0,"data":%s}`, operationID(index+1), fmt.Sprintf("boundary-%d", index), data))
		status(t, api.requestRaw(t, token, http.MethodPost, "/v1/mutations", body, true), http.StatusOK)
	}
	tooLarge := mutation(operationID(3), "too-large", "put", 0, map[string]any{"text": strings.Repeat("a", syncbff.MaxDocumentBytes-10)})
	errorCode(t, api.request(t, token, http.MethodPost, "/v1/mutations", tooLarge), http.StatusBadRequest, "document_too_large")
}

func TestDuplicateServerGrantsFailClosed(t *testing.T) {
	api := newTestAPI(t, nil, func(config *syncbff.Config) {
		config.Grants = append(config.Grants, config.Grants[0])
	})
	status(t, api.request(t, api.issuer.token(t, nil), http.MethodGet, "/v1/session", nil), http.StatusForbidden)
}

// Simulates a Cosmos adapter returning an opaque SDK session token so the HTTP
// boundary is tested without an Azure account or paid resources.
type sessionMetadataStore struct {
	base     syncbff.Store
	token    string
	mu       sync.Mutex
	received []string
}

func (store *sessionMetadataStore) Mutate(ctx context.Context, scope string, mutation syncbff.Mutation, hash, session string) (syncbff.Document, string, error) {
	store.mu.Lock()
	store.received = append(store.received, session)
	store.mu.Unlock()
	document, _, err := store.base.Mutate(ctx, scope, mutation, hash, session)
	return document, store.token, err
}

func (store *sessionMetadataStore) Sync(ctx context.Context, scope string, after int64, limit int, session string) (syncbff.StorePage, string, error) {
	store.mu.Lock()
	store.received = append(store.received, session)
	store.mu.Unlock()
	page, _, err := store.base.Sync(ctx, scope, after, limit, session)
	return page, store.token, err
}

func TestSignedSessionMetadataIsBoundToIdentityAndPurpose(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	store := &sessionMetadataStore{base: api.store, token: "0:123#1=456"}
	handler, err := syncbff.NewServer(api.config, store, api.issuer.verifier(t))
	if err != nil {
		t.Fatal(err)
	}
	api.handler = handler
	token := api.issuer.token(t, nil)
	response := api.request(t, token, http.MethodPost, "/v1/mutations", mutation(operationID(1), "note", "put", 0, map[string]any{"value": 1}))
	status(t, response, http.StatusOK)
	envelope := response.Header().Get(syncbff.SessionHeader)
	if envelope == "" || envelope == store.token {
		t.Fatal("server did not wrap the store's session token in signed metadata")
	}
	requestWithSession := func(token, session string) *httptest.ResponseRecorder {
		var binding struct {
			ScopeID           string `json:"scopeId"`
			PermissionVersion string `json:"permissionVersion"`
			PrincipalID       string `json:"principalId"`
			ScopeMode         string `json:"scopeMode"`
		}
		decode(t, api.request(t, token, http.MethodGet, "/v1/session", nil), &binding)
		request := httptest.NewRequest(http.MethodGet, "https://api.example.test/v1/sync", nil)
		request.Header.Set("Authorization", "Bearer "+token)
		request.Header.Set(syncbff.ScopeHeader, binding.ScopeID)
		request.Header.Set(syncbff.PermissionHeader, binding.PermissionVersion)
		request.Header.Set(syncbff.SessionHeader, session)
		request.Header.Set(syncbff.PrincipalHeader, binding.PrincipalID)
		request.Header.Set(syncbff.ScopeModeHeader, binding.ScopeMode)
		recorder := httptest.NewRecorder()
		api.handler.ServeHTTP(recorder, request)
		return recorder
	}
	status(t, requestWithSession(token, envelope), http.StatusOK)
	store.mu.Lock()
	received := append([]string(nil), store.received...)
	store.mu.Unlock()
	if len(received) != 2 || received[1] != store.token {
		t.Fatalf("signed session was not passed back to the store: %+v", received)
	}
	errorCode(t, requestWithSession(token, "invalid"), http.StatusGone, "resync_required")
	errorCode(t, requestWithSession(api.issuer.token(t, map[string]any{"sub": "bob"}), envelope), http.StatusGone, "resync_required")
	var page syncResponse
	decode(t, api.request(t, token, http.MethodGet, "/v1/sync", nil), &page)
	errorCode(t, requestWithSession(token, page.Cursor), http.StatusGone, "resync_required")
	errorCode(t, api.request(t, token, http.MethodGet, syncPath(envelope, 100), nil), http.StatusGone, "resync_required")
}

func TestDuplicateJSONAndSyncParametersAreRejected(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	token := api.issuer.token(t, nil)
	for _, body := range []string{
		fmt.Sprintf(`{"operationId":%q,"documentId":"note","kind":"put","baseVersion":0,"data":{"x":1,"x":2}}`, operationID(1)),
		fmt.Sprintf(`{"operationId":%q,"documentId":"note","documentId":"another","kind":"put","baseVersion":0,"data":{}}`, operationID(1)),
		fmt.Sprintf(`{"operationId":%q,"documentId":"note","kind":"put","baseVersion":0,"data":{}} {}`, operationID(1)),
	} {
		status(t, api.requestRaw(t, token, http.MethodPost, "/v1/mutations", []byte(body), true), http.StatusBadRequest)
	}
	oversized := mutation(operationID(1), "note", "put", 0, map[string]any{"text": strings.Repeat("a", syncbff.MaxBodyBytes)})
	status(t, api.request(t, token, http.MethodPost, "/v1/mutations", oversized), http.StatusBadRequest)
	for _, query := range []string{"limit=0", "limit=101", "limit=abc"} {
		status(t, api.request(t, token, http.MethodGet, "/v1/sync?"+query, nil), http.StatusBadRequest)
	}
	for _, query := range []string{"cursor=", "cursor=first&cursor=second"} {
		errorCode(t, api.request(t, token, http.MethodGet, "/v1/sync?"+query, nil), http.StatusGone, "resync_required")
	}
}

// This opt-in fixture lets the Dart SDK run against the actual Go HTTP stack and
// RSA/JWKS verification. Only ephemeral test credentials are written to the ready file.
func TestDartFixture(t *testing.T) {
	readyFile := os.Getenv("COSMOS_SYNC_E2E_READY_FILE")
	stopFile := os.Getenv("COSMOS_SYNC_E2E_STOP_FILE")
	if readyFile == "" || stopFile == "" {
		t.Skip("set COSMOS_SYNC_E2E_READY_FILE and COSMOS_SYNC_E2E_STOP_FILE for Dart/Go integration")
	}
	api := newTestAPI(t, nil, func(config *syncbff.Config) {
		config.Events = syncbff.EventOptions{Enabled: true, PollMilliseconds: 20, HeartbeatMilliseconds: 50, MaxStreamSeconds: 2}
		config.Snapshots = syncbff.SnapshotOptions{Enabled: true}
		if origin := os.Getenv("COSMOS_SYNC_E2E_ORIGIN"); origin != "" {
			config.AllowedOrigins = []string{origin}
		}
	})
	server := httptest.NewServer(api.handler)
	t.Cleanup(server.Close)
	ready, err := json.Marshal(map[string]string{"url": server.URL, "token": api.issuer.token(t, nil)})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(readyFile, ready, 0600); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(readyFile) })
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	deadline := time.NewTimer(89 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case <-ticker.C:
			if _, err := os.Stat(stopFile); err == nil {
				return
			} else if !os.IsNotExist(err) {
				t.Fatal(err)
			}
		case <-deadline.C:
			t.Fatal("Dart/Go integration fixture timed out after 89 seconds")
		}
	}
}

func TestAccessTokenValidation(t *testing.T) {
	issuer := newOIDCIssuer(t)
	api := newTestAPI(t, issuer, nil)
	tests := []struct {
		name   string
		token  string
		status int
	}{
		{"missing", "", http.StatusUnauthorized},
		{"malformed", "not.a.jwt", http.StatusUnauthorized},
		{"expired", issuer.token(t, map[string]any{"exp": time.Now().Add(-time.Hour).Unix()}), http.StatusUnauthorized},
		{"issuer", issuer.token(t, map[string]any{"iss": "https://attacker.example.test"}), http.StatusUnauthorized},
		{"audience", issuer.token(t, map[string]any{"aud": "another-api"}), http.StatusUnauthorized},
		{"future-not-before", issuer.token(t, map[string]any{"nbf": time.Now().Add(time.Hour).Unix()}), http.StatusUnauthorized},
		{"missing-tenant", issuer.token(t, map[string]any{"tid": nil}), http.StatusForbidden},
		{"missing-subject", issuer.token(t, map[string]any{"sub": nil}), http.StatusForbidden},
		{"missing-scope", issuer.token(t, map[string]any{"scp": nil}), http.StatusForbidden},
		{"different-scope", issuer.token(t, map[string]any{"scp": "other_scope"}), http.StatusForbidden},
		{"scope-substring", issuer.token(t, map[string]any{"scp": "cosmos_sync_admin"}), http.StatusForbidden},
		{"unknown-grant", issuer.token(t, map[string]any{"sub": "unknown"}), http.StatusForbidden},
		{"inactive-grant", issuer.token(t, map[string]any{"sub": "revoked"}), http.StatusForbidden},
	}
	valid := issuer.token(t, nil)
	parts := strings.Split(valid, ".")
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatal(err)
	}
	signature[0] ^= 0xff
	parts[2] = base64.RawURLEncoding.EncodeToString(signature)
	tests = append(tests, struct {
		name, token string
		status      int
	}{"bad-signature", strings.Join(parts, "."), http.StatusUnauthorized})
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			status(t, api.request(t, test.token, http.MethodGet, "/v1/session", nil), test.status)
		})
	}

	t.Run("valid-scope-among-scopes", func(t *testing.T) {
		response := api.request(t, issuer.token(t, map[string]any{"scp": "openid cosmos_sync profile"}), http.MethodGet, "/v1/session", nil)
		status(t, response, http.StatusOK)
		var session struct{ ScopeID, PermissionVersion string }
		decode(t, response, &session)
		if session.ScopeID == "" || session.PermissionVersion != "permissions-v1" {
			t.Fatalf("missing server scope or permission version: %+v", session)
		}
	})
	if issuer.jwksHits.Load() == 0 {
		t.Fatal("OIDC verifier did not fetch the test issuer's JWKS")
	}
}

func TestAuthorizationAppliesToEveryDataRoute(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	for _, endpoint := range []string{"/v1/sync", "/v1/events"} {
		t.Run("anonymous-"+endpoint, func(t *testing.T) {
			status(t, api.request(t, "", http.MethodGet, endpoint, nil), http.StatusUnauthorized)
		})
	}
	status(t, api.request(t, "", http.MethodPost, "/v1/mutations", mutation(operationID(1), "note", "put", 0, map[string]any{"value": 1})), http.StatusUnauthorized)
	reader := api.issuer.token(t, map[string]any{"sub": "reader"})
	status(t, api.request(t, reader, http.MethodGet, "/v1/sync", nil), http.StatusOK)
	status(t, api.request(t, reader, http.MethodPost, "/v1/mutations", mutation(operationID(1), "note", "put", 0, map[string]any{"value": 1})), http.StatusForbidden)
	denied := api.issuer.token(t, map[string]any{"sub": "no-access"})
	status(t, api.request(t, denied, http.MethodGet, "/v1/sync", nil), http.StatusForbidden)
}

func TestPartitionIsolation(t *testing.T) {
	for _, identity := range []struct{ name, subject, tenant string }{
		{"another-user", "bob", "tenant-a"},
		{"another-tenant", "alice", "tenant-b"},
	} {
		t.Run(identity.name, func(t *testing.T) {
			api := newTestAPI(t, nil, nil)
			alice := api.issuer.token(t, nil)
			other := api.issuer.token(t, map[string]any{"sub": identity.subject, "tid": identity.tenant})
			status(t, api.request(t, alice, http.MethodPost, "/v1/mutations", mutation(operationID(1), "same-id", "put", 0, map[string]any{"owner": "alice"})), http.StatusOK)
			var initial syncResponse
			response := api.request(t, other, http.MethodGet, "/v1/sync", nil)
			status(t, response, http.StatusOK)
			decode(t, response, &initial)
			if len(initial.Changes) != 0 {
				t.Fatal("another identity read Alice's partition")
			}
			status(t, api.request(t, other, http.MethodPost, "/v1/mutations", mutation(operationID(1), "same-id", "put", 0, map[string]any{"owner": "other"})), http.StatusOK)
			var changes syncResponse
			response = api.request(t, alice, http.MethodGet, "/v1/sync", nil)
			status(t, response, http.StatusOK)
			decode(t, response, &changes)
			if len(changes.Changes) != 1 || changes.Changes[0].Data["owner"] != "alice" {
				t.Fatalf("identity leaked into Alice's journal: %+v", changes)
			}
			var sessionA, sessionB map[string]any
			decode(t, api.request(t, alice, http.MethodGet, "/v1/session", nil), &sessionA)
			decode(t, api.request(t, other, http.MethodGet, "/v1/session", nil), &sessionB)
			if sessionA["scopeId"] == sessionB["scopeId"] {
				t.Fatal("different server identities received the same scopeId")
			}
		})
	}
}

func TestMutationIdempotencyAndConflict(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	token := api.issuer.token(t, nil)
	put := mutation(operationID(1), "note", "put", 0, map[string]any{"value": "first"})
	first := api.request(t, token, http.MethodPost, "/v1/mutations", put)
	status(t, first, http.StatusOK)
	var accepted mutationResponse
	decode(t, first, &accepted)
	if accepted.Document.ID != "note" || accepted.Document.Version != 1 || accepted.Document.Deleted {
		t.Fatalf("unexpected accepted document: %+v", accepted)
	}
	replay := api.request(t, token, http.MethodPost, "/v1/mutations", put)
	status(t, replay, http.StatusOK)
	if first.Body.String() != replay.Body.String() {
		t.Fatal("an identical operation did not replay its original response")
	}
	errorCode(t, api.request(t, token, http.MethodPost, "/v1/mutations", mutation(operationID(1), "note", "put", 0, map[string]any{"value": "different"})), http.StatusConflict, "idempotency_mismatch")
	stale := api.request(t, token, http.MethodPost, "/v1/mutations", mutation(operationID(2), "note", "put", 0, map[string]any{"value": "stale"}))
	errorCode(t, stale, http.StatusConflict, "conflict")
	var conflict struct {
		Current document `json:"current"`
	}
	decode(t, stale, &conflict)
	if conflict.Current.Version != 1 || conflict.Current.Data["value"] != "first" {
		t.Fatalf("conflict did not expose the current server base: %+v", conflict)
	}
	status(t, api.request(t, token, http.MethodPost, "/v1/mutations", mutation(operationID(3), "note", "put", 1, map[string]any{"value": "updated"})), http.StatusOK)
	// The original receipt remains unchanged after later server edits.
	replay = api.request(t, token, http.MethodPost, "/v1/mutations", put)
	status(t, replay, http.StatusOK)
	if replay.Body.String() != first.Body.String() {
		t.Fatal("old receipt changed after a newer document mutation")
	}
	var journal syncResponse
	response := api.request(t, token, http.MethodGet, "/v1/sync", nil)
	status(t, response, http.StatusOK)
	decode(t, response, &journal)
	if len(journal.Changes) != 2 {
		t.Fatalf("duplicate or rejected mutation was journaled: %+v", journal)
	}
}

func TestIdempotencyCanonicalizesJSONPropertyOrder(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	token := api.issuer.token(t, nil)
	first := []byte(fmt.Sprintf(`{"operationId":%q,"documentId":"note","kind":"put","data":{"z":1,"a":2},"baseVersion":0}`, operationID(1)))
	reordered := []byte(fmt.Sprintf(`{"baseVersion":0,"kind":"put","documentId":"note","operationId":%q,"data":{"a":2,"z":1}}`, operationID(1)))
	accepted := api.requestRaw(t, token, http.MethodPost, "/v1/mutations", first, true)
	status(t, accepted, http.StatusOK)
	replayed := api.requestRaw(t, token, http.MethodPost, "/v1/mutations", reordered, true)
	status(t, replayed, http.StatusOK)
	if accepted.Body.String() != replayed.Body.String() {
		t.Fatal("semantically identical JSON did not replay the stored receipt")
	}
}

func TestConcurrentMutationsHaveOneWinner(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	token := api.issuer.token(t, nil)
	const count = 12
	responses := make(chan *httptest.ResponseRecorder, count)
	var writers sync.WaitGroup
	for index := range count {
		writers.Add(1)
		go func() {
			defer writers.Done()
			responses <- api.request(t, token, http.MethodPost, "/v1/mutations", mutation(operationID(index+1), "note", "put", 0, map[string]any{"writer": index}))
		}()
	}
	writers.Wait()
	close(responses)
	winners, conflicts := 0, 0
	for response := range responses {
		switch response.Code {
		case http.StatusOK:
			winners++
		case http.StatusConflict:
			errorCode(t, response, http.StatusConflict, "conflict")
			conflicts++
		default:
			t.Fatalf("unexpected concurrent response: %d %s", response.Code, response.Body.String())
		}
	}
	if winners != 1 || conflicts != count-1 {
		t.Fatalf("expected one accepted version: winners=%d conflicts=%d", winners, conflicts)
	}
	var journal syncResponse
	decode(t, api.request(t, token, http.MethodGet, "/v1/sync", nil), &journal)
	if len(journal.Changes) != 1 || journal.Changes[0].Version != 1 {
		t.Fatalf("concurrent writes did not commit atomically: %+v", journal)
	}
}

func TestConcurrentRetryCreatesOnlyOneReceiptAndEvent(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	token := api.issuer.token(t, nil)
	put := mutation(operationID(1), "note", "put", 0, map[string]any{"value": "retry"})
	const count = 12
	responses := make(chan *httptest.ResponseRecorder, count)
	var writers sync.WaitGroup
	for range count {
		writers.Add(1)
		go func() {
			defer writers.Done()
			responses <- api.request(t, token, http.MethodPost, "/v1/mutations", put)
		}()
	}
	writers.Wait()
	close(responses)
	var expectedBody string
	for response := range responses {
		status(t, response, http.StatusOK)
		if expectedBody == "" {
			expectedBody = response.Body.String()
		} else if expectedBody != response.Body.String() {
			t.Fatal("concurrent retries returned different receipts")
		}
	}
	var journal syncResponse
	decode(t, api.request(t, token, http.MethodGet, "/v1/sync", nil), &journal)
	if len(journal.Changes) != 1 {
		t.Fatalf("concurrent retry was committed more than once: %+v", journal)
	}
}

func TestDeleteRetainsTombstoneAndDetectsStaleResurrection(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	token := api.issuer.token(t, nil)
	status(t, api.request(t, token, http.MethodPost, "/v1/mutations", mutation(operationID(1), "note", "put", 0, map[string]any{"value": 1})), http.StatusOK)
	deleted := api.request(t, token, http.MethodPost, "/v1/mutations", mutation(operationID(2), "note", "delete", 1, nil))
	status(t, deleted, http.StatusOK)
	var receipt mutationResponse
	decode(t, deleted, &receipt)
	if !receipt.Document.Deleted || receipt.Document.Version != 2 || receipt.Document.Data != nil {
		t.Fatalf("delete was not a versioned tombstone: %+v", receipt)
	}
	errorCode(t, api.request(t, token, http.MethodPost, "/v1/mutations", mutation(operationID(3), "note", "put", 0, map[string]any{"value": "stale"})), http.StatusConflict, "conflict")
	var journal syncResponse
	decode(t, api.request(t, token, http.MethodGet, "/v1/sync", nil), &journal)
	if len(journal.Changes) != 2 || !journal.Changes[1].Deleted {
		t.Fatalf("offline bootstrap did not retain the deletion: %+v", journal)
	}
	status(t, api.request(t, token, http.MethodPost, "/v1/mutations", mutation(operationID(4), "note", "put", 2, map[string]any{"value": "explicit-recreate"})), http.StatusOK)
}

func TestSyncPaginationAndResume(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	token := api.issuer.token(t, nil)
	for index := 1; index <= 3; index++ {
		status(t, api.request(t, token, http.MethodPost, "/v1/mutations", mutation(operationID(index), fmt.Sprintf("note-%d", index), "put", 0, map[string]any{"value": index})), http.StatusOK)
	}
	cursor := ""
	for index := 1; index <= 3; index++ {
		response := api.request(t, token, http.MethodGet, syncPath(cursor, 1), nil)
		status(t, response, http.StatusOK)
		var page syncResponse
		decode(t, response, &page)
		if len(page.Changes) != 1 || page.Changes[0].ID != fmt.Sprintf("note-%d", index) || page.Changes[0].Version != int64(index) {
			t.Fatalf("resume skipped or duplicated a partition event: %+v", page)
		}
		if page.Cursor == "" || page.HasMore != (index < 3) {
			t.Fatalf("invalid page continuation: %+v", page)
		}
		cursor = page.Cursor
	}
	empty := api.request(t, token, http.MethodGet, syncPath(cursor, 1), nil)
	status(t, empty, http.StatusOK)
	var page syncResponse
	decode(t, empty, &page)
	if len(page.Changes) != 0 || page.HasMore || page.Cursor == "" {
		t.Fatalf("tail page is invalid: %+v", page)
	}
	var raw map[string]any
	decode(t, empty, &raw)
	if _, ok := raw["changes"].([]any); !ok {
		t.Fatal("empty changes must be a JSON array")
	}
	status(t, api.request(t, token, http.MethodPost, "/v1/mutations", mutation(operationID(4), "after-reconnect", "put", 0, map[string]any{"value": 4})), http.StatusOK)
	resumed := api.request(t, token, http.MethodGet, syncPath(page.Cursor, 100), nil)
	status(t, resumed, http.StatusOK)
	decode(t, resumed, &page)
	if len(page.Changes) != 1 || page.Changes[0].ID != "after-reconnect" {
		t.Fatalf("tail cursor missed subsequent committed changes: %+v", page)
	}
}

func TestCursorRejectsTamperingAndForeignIdentity(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	token := api.issuer.token(t, nil)
	var initial syncResponse
	decode(t, api.request(t, token, http.MethodGet, "/v1/sync", nil), &initial)
	if initial.Cursor == "" {
		t.Fatal("initial sync did not issue a durable cursor")
	}
	tampered := []byte(initial.Cursor)
	position := len(tampered) / 2
	if tampered[position] == 'A' {
		tampered[position] = 'B'
	} else {
		tampered[position] = 'A'
	}
	for _, cursor := range []string{"not-a-cursor", string(tampered)} {
		errorCode(t, api.request(t, token, http.MethodGet, syncPath(cursor, 100), nil), http.StatusGone, "resync_required")
	}
	for _, claims := range []map[string]any{{"sub": "bob"}, {"tid": "tenant-b"}} {
		other := api.issuer.token(t, claims)
		errorCode(t, api.request(t, other, http.MethodGet, syncPath(initial.Cursor, 100), nil), http.StatusGone, "resync_required")
	}
	config := api.config
	config.Grants = append([]syncbff.Grant(nil), config.Grants...)
	config.Grants[0].PermissionVersion = "permissions-v2"
	changed, err := syncbff.NewServer(config, api.store, api.issuer.verifier(t))
	if err != nil {
		t.Fatal(err)
	}
	changedAPI := &testAPI{handler: changed, issuer: api.issuer, config: config, store: api.store}
	errorCode(t, changedAPI.request(t, token, http.MethodGet, syncPath(initial.Cursor, 100), nil), http.StatusGone, "resync_required")
}

func TestMutationValidationRejectsUntrustedShapeAndPartitionFields(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	token := api.issuer.token(t, nil)
	tests := []struct {
		name string
		body map[string]any
	}{
		{"non-uuid", mutation("invalid", "note", "put", 0, map[string]any{"x": 1})},
		{"empty-id", mutation(operationID(1), "", "put", 0, map[string]any{"x": 1})},
		{"negative-version", mutation(operationID(1), "note", "put", -1, map[string]any{"x": 1})},
		{"unknown-kind", mutation(operationID(1), "note", "patch", 0, map[string]any{"x": 1})},
		{"put-null", mutation(operationID(1), "note", "put", 0, nil)},
		{"put-array", mutation(operationID(1), "note", "put", 0, []any{1, 2})},
		{"put-string", mutation(operationID(1), "note", "put", 0, "text")},
		{"delete-data", mutation(operationID(1), "note", "delete", 0, map[string]any{"x": 1})},
	}
	for _, field := range []string{"tenant", "owner", "partition", "scopeId"} {
		body := mutation(operationID(1), "note", "put", 0, map[string]any{"x": 1})
		body[field] = "attacker-selected"
		tests = append(tests, struct {
			name string
			body map[string]any
		}{"forged-" + field, body})
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			status(t, api.request(t, token, http.MethodPost, "/v1/mutations", test.body), http.StatusBadRequest)
		})
	}
	status(t, api.requestRaw(t, token, http.MethodPost, "/v1/mutations", []byte(`{"operationId":`), true), http.StatusBadRequest)
	var journal syncResponse
	decode(t, api.request(t, token, http.MethodGet, "/v1/sync", nil), &journal)
	if len(journal.Changes) != 0 {
		t.Fatalf("invalid mutation reached the journal: %+v", journal)
	}
}
