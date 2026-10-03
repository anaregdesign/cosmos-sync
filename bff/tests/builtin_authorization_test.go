package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
)

func builtinAPI(t *testing.T) *testAPI {
	return newTestAPI(t, nil, func(config *syncbff.Config) {
		config.Grants = nil
		config.Authorization.Mode = "builtin"
		config.Events = syncbff.EventOptions{Enabled: true, PollMilliseconds: 10, HeartbeatMilliseconds: 20, MaxStreamSeconds: 1}
		config.Snapshots.Enabled = true
	})
}

func builtinAccount(t *testing.T, api *testAPI, token string) syncbff.Account {
	t.Helper()
	response := api.requestRaw(t, token, "GET", "/v1/account", nil, false)
	status(t, response, 200)
	var result syncbff.Account
	decode(t, response, &result)
	return result
}

func builtinManage(t *testing.T, api *testAPI, token, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var raw []byte
	if body != nil {
		raw, _ = json.Marshal(body)
	}
	return api.requestRaw(t, token, method, path, raw, false)
}

func builtinCreate(t *testing.T, api *testAPI, token string, number int) syncbff.SharedScope {
	t.Helper()
	response := builtinManage(t, api, token, "POST", "/v1/scopes", map[string]any{"operationId": operationID(number)})
	status(t, response, 200)
	var result syncbff.SharedScope
	decode(t, response, &result)
	return result
}

func builtinMembership(t *testing.T, api *testAPI, token string, scope syncbff.SharedScope, accountID, role string, number int) syncbff.SharedScope {
	t.Helper()
	change := syncbff.MembershipChange{OperationID: operationID(number), AccountID: accountID, Role: role, BaseRevision: scope.Revision}
	response := builtinManage(t, api, token, "POST", "/v1/scopes/"+scope.ScopeID+"/members", change)
	status(t, response, 200)
	var result syncbff.SharedScope
	decode(t, response, &result)
	return result
}

func builtinBinding(t *testing.T, api *testAPI, token, scopeID string) syncbff.Scope {
	t.Helper()
	response := api.requestRaw(t, token, "GET", "/v1/session?scope=shared&scopeId="+scopeID, nil, false)
	status(t, response, 200)
	var result syncbff.Scope
	decode(t, response, &result)
	return result
}

func builtinData(t *testing.T, handler http.Handler, token, method, path string, scope syncbff.Scope, body any) *httptest.ResponseRecorder {
	t.Helper()
	var raw []byte
	if body != nil {
		raw, _ = json.Marshal(body)
	}
	request := httptest.NewRequest(method, "https://api.example.test"+path, bytes.NewReader(raw))
	request.Header.Set("Authorization", "Bearer "+token)
	bindScope(request, scope)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	return recorder
}

func TestBuiltinPersonalIdentityRequiresTrustedAPIProofWithoutTenantOrRoles(t *testing.T) {
	api := builtinAPI(t)
	alice := api.issuer.token(t, map[string]any{"tid": nil, "roles": []string{"admin"}, "email": "same@example.test"})
	account := builtinAccount(t, api, alice)
	if len(account.AccountID) != 64 || len(account.PersonalScopeID) != 64 || account.AccountID == account.PersonalScopeID {
		t.Fatal("account and personal namespaces must differ")
	}
	changedTenant := api.issuer.token(t, map[string]any{"tid": "unrelated", "email": "different@example.test"})
	if builtinAccount(t, api, changedTenant) != account {
		t.Fatal("tenant/email/role claims changed issuer+subject account")
	}
	bob := api.issuer.token(t, map[string]any{"sub": "bob", "tid": nil, "email": "same@example.test"})
	if builtinAccount(t, api, bob).AccountID == account.AccountID {
		t.Fatal("email matching merged independent accounts")
	}
	var binding syncbff.Scope
	decode(t, api.request(t, alice, "GET", "/v1/session", nil), &binding)
	if binding.ID != account.PersonalScopeID || binding.PrincipalID != account.AccountID || binding.ScopeMode != "user" || binding.PermissionVersion != "1" {
		t.Fatal("personal session is not registered identity")
	}
	status(t, builtinData(t, api.handler, alice, "POST", "/v1/mutations", binding, mutation(operationID(1), "note", "put", 0, map[string]any{"owner": "bob"})), 200)
	status(t, builtinData(t, api.handler, bob, "GET", "/v1/sync", binding, nil), 403)
	for _, claims := range []map[string]any{{"aud": "different-api"}, {"iss": "https://wrong.example.test"}, {"scp": "other"}, {"sub": ""}, {"exp": time.Now().Add(-time.Hour).Unix()}} {
		response := api.requestRaw(t, api.issuer.token(t, claims), "GET", "/v1/account", nil, false)
		if response.Code != 401 && response.Code != 403 {
			t.Fatalf("untrusted API proof accepted: %d", response.Code)
		}
	}
	status(t, api.requestRaw(t, alice, "GET", "/v1/session?scope=tenant", nil, false), 400)
}

func TestBuiltinSharedOwnerMembershipCASAndExactReplay(t *testing.T) {
	api := builtinAPI(t)
	alice, bob := api.issuer.token(t, nil), api.issuer.token(t, map[string]any{"sub": "bob", "roles": []string{"owner", "admin"}})
	owner, member := builtinAccount(t, api, alice), builtinAccount(t, api, bob)
	shared := builtinCreate(t, api, alice, 100)
	if shared.OwnerAccountID != owner.AccountID || shared.Revision != 1 || len(shared.Members) != 0 {
		t.Fatal("creator must be only fixed owner")
	}
	status(t, api.requestRaw(t, bob, "GET", "/v1/session?scope=shared&scopeId="+shared.ScopeID, nil, false), 403)
	path := "/v1/scopes/" + shared.ScopeID + "/members"
	change := syncbff.MembershipChange{OperationID: operationID(101), AccountID: member.AccountID, Role: "reader", BaseRevision: 1}
	errorCode(t, builtinManage(t, api, bob, "POST", path, change), 403, "forbidden")
	errorCode(t, builtinManage(t, api, alice, "POST", path, syncbff.MembershipChange{OperationID: operationID(102), AccountID: owner.AccountID, Role: "none", BaseRevision: 1}), 409, "immutable_owner")
	errorCode(t, builtinManage(t, api, alice, "POST", path, syncbff.MembershipChange{OperationID: operationID(103), AccountID: strings.Repeat("f", 64), Role: "writer", BaseRevision: 1}), 404, "account_not_found")
	shared = builtinMembership(t, api, alice, shared, member.AccountID, "reader", 101)
	reader := builtinBinding(t, api, bob, shared.ScopeID)
	status(t, builtinData(t, api.handler, bob, "GET", "/v1/sync", reader, nil), 200)
	status(t, builtinData(t, api.handler, bob, "GET", "/v1/snapshot", reader, nil), 200)
	status(t, builtinData(t, api.handler, bob, "POST", "/v1/mutations", reader, mutation(operationID(1), "denied", "put", 0, map[string]any{})), 403)
	status(t, builtinManage(t, api, bob, "GET", path, nil), 403)
	shared = builtinMembership(t, api, alice, shared, member.AccountID, "writer", 104)
	replay := builtinManage(t, api, alice, "POST", path, change)
	status(t, replay, 200)
	var old syncbff.SharedScope
	decode(t, replay, &old)
	if old.Revision != 2 || old.Members[0].Role != "reader" {
		t.Fatal("replay response changed with later membership")
	}
	change.Role = "writer"
	errorCode(t, builtinManage(t, api, alice, "POST", path, change), 409, "idempotency_mismatch")
	change.OperationID = operationID(105)
	errorCode(t, builtinManage(t, api, alice, "POST", path, change), 409, "membership_conflict")
	recreated := builtinCreate(t, api, alice, 100)
	if recreated.Revision != 1 || len(recreated.Members) != 0 || recreated.ScopeID != shared.ScopeID {
		t.Fatal("creation replay must remain initial snapshot")
	}
	writer := builtinBinding(t, api, bob, shared.ScopeID)
	status(t, builtinData(t, api.handler, bob, "POST", "/v1/mutations", writer, mutation(operationID(1), "note", "put", 0, map[string]any{})), 200)
	status(t, builtinData(t, api.handler, bob, "POST", "/v1/mutations", writer, mutation(operationID(2), "note", "delete", 1, nil)), 200)
	for _, body := range []string{`{"operationId":"` + operationID(110) + `","ownerAccountId":"` + member.AccountID + `"}`, `{"operationId":"` + operationID(110) + `","operationId":"` + operationID(111) + `"}`} {
		errorCode(t, api.requestRaw(t, alice, "POST", "/v1/scopes", []byte(body), false), 400, "invalid_authorization_request")
	}
}

func TestBuiltinRemovalReadditionKeepsOtherMembersAndRejectsOldCursor(t *testing.T) {
	api := builtinAPI(t)
	alice, bob, carol := api.issuer.token(t, nil), api.issuer.token(t, map[string]any{"sub": "bob"}), api.issuer.token(t, map[string]any{"sub": "carol"})
	member, other := builtinAccount(t, api, bob), builtinAccount(t, api, carol)
	shared := builtinCreate(t, api, alice, 1)
	shared = builtinMembership(t, api, alice, shared, member.AccountID, "writer", 2)
	old := builtinBinding(t, api, bob, shared.ScopeID)
	var page syncResponse
	decode(t, builtinData(t, api.handler, bob, "GET", "/v1/sync", old, nil), &page)
	shared = builtinMembership(t, api, alice, shared, other.AccountID, "reader", 3)
	if builtinBinding(t, api, bob, shared.ScopeID).PermissionVersion != old.PermissionVersion {
		t.Fatal("unrelated membership purges authorized member")
	}
	shared = builtinMembership(t, api, alice, shared, member.AccountID, "none", 4)
	for _, path := range []string{"/v1/sync", "/v1/snapshot", "/v1/events"} {
		errorCode(t, builtinData(t, api.handler, bob, "GET", path, old, nil), 403, "forbidden")
	}
	shared = builtinMembership(t, api, alice, shared, member.AccountID, "writer", 5)
	fresh := builtinBinding(t, api, bob, shared.ScopeID)
	if fresh.PermissionVersion == old.PermissionVersion {
		t.Fatal("remove/readd resurrected old generation")
	}
	errorCode(t, builtinData(t, api.handler, bob, "GET", syncPath(page.Cursor, 100), fresh, nil), 410, "resync_required")
	status(t, builtinData(t, api.handler, bob, "GET", "/v1/sync", old, nil), 403)
	status(t, builtinData(t, api.handler, carol, "GET", "/v1/sync", builtinBinding(t, api, carol, shared.ScopeID), nil), 200)
}

type blockedAuthorizedMutation struct {
	*syncbff.MemoryStore
	entered chan struct{}
	release chan struct{}
}

func (s *blockedAuthorizedMutation) Mutate(ctx context.Context, scopeID string, mutation syncbff.Mutation, hash, session string) (syncbff.Document, string, error) {
	close(s.entered)
	select {
	case <-s.release:
	case <-ctx.Done():
		return syncbff.Document{}, session, ctx.Err()
	}
	return s.MemoryStore.Mutate(ctx, scopeID, mutation, hash, session)
}

func TestBuiltinRevocationFencesAlreadyAuthorizedMutationAndReceiptReplay(t *testing.T) {
	api := builtinAPI(t)
	alice, bob := api.issuer.token(t, nil), api.issuer.token(t, map[string]any{"sub": "bob"})
	member := builtinAccount(t, api, bob)
	shared := builtinMembership(t, api, alice, builtinCreate(t, api, alice, 1), member.AccountID, "writer", 2)
	old := builtinBinding(t, api, bob, shared.ScopeID)
	blocked := &blockedAuthorizedMutation{MemoryStore: api.store.(*syncbff.MemoryStore), entered: make(chan struct{}), release: make(chan struct{})}
	handler, err := syncbff.NewServer(api.config, blocked, api.issuer.verifier(t))
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- builtinData(t, handler, bob, "POST", "/v1/mutations", old, mutation(operationID(10), "queued", "put", 0, map[string]any{}))
	}()
	<-blocked.entered
	shared = builtinMembership(t, api, alice, shared, member.AccountID, "none", 3)
	close(blocked.release)
	errorCode(t, <-done, 403, "forbidden")
	page, _, err := api.store.Sync(context.Background(), shared.ScopeID, 0, 100, "")
	if err != nil || len(page.Changes) != 0 {
		t.Fatal("post-revoke stale mutation committed")
	}
	shared = builtinMembership(t, api, alice, shared, member.AccountID, "writer", 4)
	active := builtinBinding(t, api, bob, shared.ScopeID)
	put := mutation(operationID(11), "ack", "put", 0, map[string]any{})
	status(t, builtinData(t, api.handler, bob, "POST", "/v1/mutations", active, put), 200)
	shared = builtinMembership(t, api, alice, shared, member.AccountID, "none", 5)
	status(t, builtinData(t, api.handler, bob, "POST", "/v1/mutations", active, put), 403)
	var internal syncbff.Mutation
	raw, _ := json.Marshal(put)
	_ = json.Unmarshal(raw, &internal)
	internal.PrincipalID, internal.AuthorizationVersion = active.PrincipalID, active.PermissionVersion
	_, _, err = api.store.Mutate(context.Background(), shared.ScopeID, internal, "not-used-before-policy-denial", "")
	if p, ok := err.(*syncbff.ProtocolError); !ok || p.Status != 403 {
		t.Fatal("receipt replay bypassed current authorization")
	}
}

type afterAuthorizedMutation struct {
	*syncbff.MemoryStore
	after func()
}

func (s *afterAuthorizedMutation) Mutate(ctx context.Context, scopeID string, mutation syncbff.Mutation, hash, session string) (syncbff.Document, string, error) {
	document, token, err := s.MemoryStore.Mutate(ctx, scopeID, mutation, hash, session)
	s.after()
	return document, token, err
}

func TestBuiltinMutationDataResponsesRecheckObservedRevocation(t *testing.T) {
	for _, outcome := range []string{"receipt", "conflict", "committed"} {
		t.Run(outcome, func(t *testing.T) {
			api := builtinAPI(t)
			alice, bob := api.issuer.token(t, nil), api.issuer.token(t, map[string]any{"sub": "bob"})
			member := builtinAccount(t, api, bob)
			shared := builtinMembership(t, api, alice, builtinCreate(t, api, alice, 1), member.AccountID, "writer", 2)
			binding := builtinBinding(t, api, bob, shared.ScopeID)
			accepted := mutation(operationID(10), "original", "put", 0, map[string]any{"secret": "response-must-not-leak"})
			status(t, builtinData(t, api.handler, bob, "POST", "/v1/mutations", binding, accepted), 200)
			request := accepted
			wantChanges := 1
			if outcome == "conflict" {
				request = mutation(operationID(11), "original", "put", 0, map[string]any{})
			}
			if outcome == "committed" {
				request = mutation(operationID(12), "new-document", "put", 0, map[string]any{"secret": "new-response"})
				wantChanges = 2
			}
			store := &afterAuthorizedMutation{MemoryStore: api.store.(*syncbff.MemoryStore), after: func() { builtinMembership(t, api, alice, shared, member.AccountID, "none", 3) }}
			handler, err := syncbff.NewServer(api.config, store, api.issuer.verifier(t))
			if err != nil {
				t.Fatal(err)
			}
			response := builtinData(t, handler, bob, "POST", "/v1/mutations", binding, request)
			errorCode(t, response, 403, "forbidden")
			if strings.Contains(response.Body.String(), "document") || strings.Contains(response.Body.String(), "current") || strings.Contains(response.Body.String(), "secret") {
				t.Fatal("post-store revocation leaked a data response")
			}
			page, _, err := api.store.Sync(context.Background(), shared.ScopeID, 0, 100, "")
			if err != nil || len(page.Changes) != wantChanges {
				t.Fatal("response denial incorrectly implied rollback or duplicated receipt")
			}
		})
	}
}

func TestBuiltinSSERechecksMembershipWhileConnected(t *testing.T) {
	api := builtinAPI(t)
	alice, bob := api.issuer.token(t, nil), api.issuer.token(t, map[string]any{"sub": "bob"})
	member := builtinAccount(t, api, bob)
	shared := builtinMembership(t, api, alice, builtinCreate(t, api, alice, 1), member.AccountID, "reader", 2)
	binding := builtinBinding(t, api, bob, shared.ScopeID)
	server := httptest.NewTLSServer(api.handler)
	defer server.Close()
	client := server.Client()
	client.Timeout = 4 * time.Second
	request, _ := http.NewRequest("GET", server.URL+"/v1/events", nil)
	request.Header.Set("Authorization", "Bearer "+bob)
	bindScope(request, binding)
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	builtinMembership(t, api, alice, shared, member.AccountID, "none", 3)
	body, err := io.ReadAll(response.Body)
	if err != nil || !strings.Contains(string(body), `"code":"forbidden"`) {
		t.Fatalf("stream retained removed reader: %v %s", err, body)
	}
}

func TestBuiltinLegacyDataIsNeverImplicitlyAdoptedAndModeFailsClosed(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	token := api.issuer.token(t, nil)
	status(t, api.request(t, token, "POST", "/v1/mutations", mutation(operationID(1), "legacy", "put", 0, map[string]any{})), 200)
	legacy := scopeBinding(t, api, token, "user")
	config := api.config
	config.Grants = nil
	config.Authorization.Mode = "builtin"
	handler, err := syncbff.NewServer(config, api.store, api.issuer.verifier(t))
	if err != nil {
		t.Fatal(err)
	}
	api.handler = handler
	fresh := scopeBinding(t, api, token, "user")
	if legacy.ID == fresh.ID || legacy.PrincipalID == fresh.PrincipalID {
		t.Fatal("new mode silently adopted legacy namespace")
	}
	var page syncResponse
	decode(t, builtinData(t, handler, token, "GET", "/v1/sync", fresh, nil), &page)
	if len(page.Changes) != 0 {
		t.Fatal("legacy data leaked into builtin scope")
	}
	config.Grants = api.config.Grants
	if _, err := syncbff.NewServer(config, api.store, api.issuer.verifier(t)); err == nil {
		t.Fatal("builtin+legacy grants ambiguity accepted")
	}
	config.Grants = nil
	config.Authorization.Mode = "unknown"
	if _, err := syncbff.NewServer(config, api.store, api.issuer.verifier(t)); err == nil {
		t.Fatal("unknown authorization mode accepted")
	}
}

func TestBuiltinManagementIdentityAssertionAndCORS(t *testing.T) {
	api := builtinAPI(t)
	alice, bob := api.issuer.token(t, nil), api.issuer.token(t, map[string]any{"sub": "bob"})
	owner := builtinAccount(t, api, alice)
	request := httptest.NewRequest("POST", "https://api.example.test/v1/scopes", strings.NewReader(`{"operationId":"`+operationID(1)+`"}`))
	request.Header.Set("Authorization", "Bearer "+bob)
	request.Header.Set(syncbff.PrincipalHeader, owner.AccountID)
	response := httptest.NewRecorder()
	api.handler.ServeHTTP(response, request)
	errorCode(t, response, 403, "session_mismatch")
	config := api.config
	config.AllowedOrigins = []string{"https://app.example.test"}
	handler, err := syncbff.NewServer(config, api.store, api.issuer.verifier(t))
	if err != nil {
		t.Fatal(err)
	}
	shared := builtinCreate(t, api, alice, 2)
	for _, path := range []string{"/v1/account", "/v1/scopes", "/v1/scopes/" + shared.ScopeID + "/members"} {
		method := "POST"
		if path == "/v1/account" {
			method = "GET"
		}
		preflight := httptest.NewRequest("OPTIONS", "https://api.example.test"+path, nil)
		preflight.Header.Set("Origin", "https://app.example.test")
		preflight.Header.Set("Access-Control-Request-Method", method)
		preflight.Header.Set("Access-Control-Request-Headers", "authorization,content-type,x-cosmos-sync-principal")
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, preflight)
		status(t, response, 204)
	}
	status(t, api.requestRaw(t, alice, "GET", "/v1/session?scope=shared&scopeId="+url.QueryEscape("not-a-scope"), nil, false), 400)
}

func TestBuiltinAuthorizationMetadataCannotBeMutatedOrSyncedAsDocuments(t *testing.T) {
	api := builtinAPI(t)
	alice, bob := api.issuer.token(t, nil), api.issuer.token(t, map[string]any{"sub": "bob"})
	member := builtinAccount(t, api, bob)
	shared := builtinMembership(t, api, alice, builtinCreate(t, api, alice, 1), member.AccountID, "reader", 2)
	owner := builtinBinding(t, api, alice, shared.ScopeID)
	for _, id := range []string{"a:policy", "a:account", "a:audit:00001", "a:r:operation"} {
		errorCode(t, builtinData(t, api.handler, alice, "POST", "/v1/mutations", owner, mutation(operationID(10), id, "put", 0, map[string]any{})), 400, "invalid_mutation")
	}
	var page syncResponse
	decode(t, builtinData(t, api.handler, alice, "GET", "/v1/sync", owner, nil), &page)
	if len(page.Changes) != 0 {
		t.Fatal("authorization metadata entered document journal")
	}
	var snapshot struct {
		Documents []syncbff.Document `json:"documents"`
	}
	decode(t, builtinData(t, api.handler, alice, "GET", "/v1/snapshot", owner, nil), &snapshot)
	if len(snapshot.Documents) != 0 {
		t.Fatal("authorization metadata entered snapshot")
	}
	status(t, builtinData(t, api.handler, alice, "POST", "/v1/mutations", owner, mutation(operationID(11), "head", "put", 0, map[string]any{"ownerAccountId": member.AccountID, "role": "writer"})), 200)
	reader := builtinBinding(t, api, bob, shared.ScopeID)
	status(t, builtinData(t, api.handler, bob, "POST", "/v1/mutations", reader, mutation(operationID(12), "head", "delete", 1, nil)), 403)
	for _, field := range []string{"principalId", "authorizationVersion", "ownerAccountId"} {
		body := mutation(operationID(13), "untrusted", "put", 0, map[string]any{})
		raw, _ := json.Marshal(body)
		var fields map[string]any
		_ = json.Unmarshal(raw, &fields)
		fields[field] = member.AccountID
		raw, _ = json.Marshal(fields)
		errorCode(t, builtinDataRaw(t, api.handler, alice, owner, raw), 400, "invalid_mutation")
	}
}

func builtinDataRaw(t *testing.T, handler http.Handler, token string, scope syncbff.Scope, raw []byte) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest("POST", "https://api.example.test/v1/mutations", bytes.NewReader(raw))
	request.Header.Set("Authorization", "Bearer "+token)
	bindScope(request, scope)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}
