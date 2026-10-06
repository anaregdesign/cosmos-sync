package syncbff

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

type identityHTTPFixture struct {
	broker  *brokerProofFixture
	handler *Server
	server  *httptest.Server
	options *IdentityDirectoryOptions
}

type identityDiscoveryTransport struct {
	broker *brokerProofFixture
}

func (transport identityDiscoveryTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if request.Method == http.MethodGet && request.URL.String() == transport.broker.signed.target.Issuer+"/.well-known/openid-configuration" {
		body, _ := json.Marshal(map[string]any{"issuer": transport.broker.signed.target.Issuer,
			"authorization_endpoint": transport.broker.signed.target.Issuer + "/authorize",
			"token_endpoint":         transport.broker.signed.target.Issuer + "/token",
			"jwks_uri":               transport.broker.signed.server.URL + "/jwks"})
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}},
			Body: io.NopCloser(bytes.NewReader(body)), Request: request}, nil
	}
	if request.URL.String() == transport.broker.signed.server.URL+"/jwks" {
		return transport.broker.signed.server.Client().Transport.RoundTrip(request)
	}
	return nil, errors.New("fixture refuses an unexpected discovery destination")
}

func newIdentityHTTPFixture(t *testing.T) *identityHTTPFixture {
	t.Helper()
	return startIdentityHTTPFixture(t, newBrokerProofFixture(t), NewMemoryStore(), "")
}

func startIdentityHTTPFixture(t *testing.T, broker *brokerProofFixture, store Store, namespace string) *identityHTTPFixture {
	t.Helper()
	f := &identityHTTPFixture{broker: broker}
	options := brokerTestOptions()
	directory := &IdentityDirectoryOptions{
		TenantID: options.TenantID, InitialDomain: options.InitialDomain,
		ReaderClientID: options.ReaderClientID, ManagedIdentityClientID: options.ManagedIdentityClientID,
		WorkforceTenantIDs: append([]string(nil), options.WorkforceTenantIDs...),
		Namespace:          f.broker.signed.target.Namespace,
		Callbacks:          []string{f.broker.signed.target.Callback, "https://app.invalid/auth-redirect.html"},
	}
	if namespace != "" {
		directory.Namespace = namespace
	}
	f.options = directory
	config := Config{Development: true, OIDC: f.broker.verifier.api.config.OIDC,
		Authorization:   AuthorizationOptions{Mode: "directory", Directory: directory},
		CursorKeyBase64: base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{42}, 32)), AllowedOrigins: []string{"https://app.invalid"},
		Snapshots: SnapshotOptions{Enabled: true},
		Events:    EventOptions{Enabled: true, PollMilliseconds: 10, HeartbeatMilliseconds: 10, MaxStreamSeconds: 1}}
	client := &http.Client{Timeout: 3 * time.Second, Transport: identityDiscoveryTransport{f.broker}}
	ctx := oidc.ClientContext(context.Background(), client)
	var err error
	f.handler, err = NewServerContext(ctx, config, store, f.broker.verifier.api.verifier)
	if err != nil {
		t.Fatal("explicit production factory rejected the signed local fixture configuration", err)
	}
	for _, proof := range f.handler.directory.proofs {
		proof.idProof.now = func() time.Time { return f.broker.signed.now }
		proof.directory.credential = f.broker.reader.credential
		proof.directory.client = f.broker.reader.client
	}
	f.handler.directory.directory.now = func() time.Time { return f.broker.signed.now }
	f.server = httptest.NewTLSServer(f.handler)
	t.Cleanup(f.server.Close)
	return f
}

func (f *identityHTTPFixture) request(t *testing.T, token, method, path string, scope *Scope, body any, want int) map[string]json.RawMessage {
	t.Helper()
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequest(method, f.server.URL+path, reader)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	if scope != nil {
		bindIdentityTestScope(request, *scope)
	}
	response, err := f.server.Client().Do(request)
	if err != nil {
		t.Fatal("TLS fixture request failed", err)
	}
	defer response.Body.Close()
	encoded, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != want {
		t.Fatalf("%s %s: want HTTP%d, got HTTP%d: %s", method, path, want, response.StatusCode, encoded)
	}
	var result map[string]json.RawMessage
	if json.Unmarshal(encoded, &result) != nil {
		t.Fatal("invalid fixture response")
	}
	return result
}

func bindIdentityTestScope(request *http.Request, scope Scope) {
	request.Header.Set(ScopeHeader, scope.ID)
	request.Header.Set(PermissionHeader, scope.PermissionVersion)
	request.Header.Set(PrincipalHeader, scope.PrincipalID)
	request.Header.Set(ScopeModeHeader, scope.ScopeMode)
	if scope.IdentityGeneration != 0 {
		request.Header.Set(IdentityGenerationHeader, strconv.FormatInt(scope.IdentityGeneration, 10))
		request.Header.Set(IdentityHeader, scope.IdentityID)
	}
}

func identityHTTPDecode[T any](t *testing.T, value map[string]json.RawMessage) T {
	t.Helper()
	encoded, _ := json.Marshal(value)
	var result T
	if json.Unmarshal(encoded, &result) != nil {
		t.Fatal("fixture could not decode the public response")
	}
	return result
}

func (f *identityHTTPFixture) challenge(t *testing.T, token string, scope *Scope, operation, removed, callback string) string {
	t.Helper()
	request := map[string]string{"operation": operation, "callback": callback}
	if removed != "" {
		request["removeIdentityId"] = removed
	}
	response := f.request(t, token, "POST", "/v1/identity/challenges", scope, request, 200)
	var raw string
	if json.Unmarshal(response["challenge"], &raw) != nil || !accountIDPattern.MatchString(raw) {
		t.Fatal("server did not issue a bounded random challenge")
	}
	return raw
}

func (f *identityHTTPFixture) register(t *testing.T, object string) (string, identityAccountResponse, Scope) {
	t.Helper()
	token := f.broker.access(t, map[string]any{"oid": object}, 0)
	challenge := f.challenge(t, token, nil, "register", "", f.broker.signed.target.Callback)
	response := f.request(t, token, "POST", "/v1/identity/register", nil,
		map[string]string{"challenge": challenge, "idToken": f.broker.id(t, challenge, map[string]any{"oid": object}, 0)}, 200)
	account := identityHTTPDecode[identityAccountResponse](t, response)
	scope := identityHTTPDecode[Scope](t, f.request(t, token, "GET", "/v1/session?scope=user", nil, nil, 200))
	if account.AccountID != scope.PrincipalID || account.PersonalScopeID != scope.ID ||
		scope.IdentityGeneration != 1 || account.CurrentIdentityID != scope.IdentityID {
		t.Fatal("registered random account did not establish an exact server-derived data session")
	}
	return token, account, scope
}

func (f *identityHTTPFixture) addProfile(object, upstream string) {
	profile := brokerTestProfile()
	profile["id"] = object
	profile["identities"].([]map[string]any)[0]["issuerAssignedId"] = upstream
	f.broker.graphMu.Lock()
	defer f.broker.graphMu.Unlock()
	f.broker.profiles[object] = profile
}

func TestDirectoryHTTPExplicitSignedLifecyclePreservesOwnershipAndRevokesEverySurface(t *testing.T) {
	f := newIdentityHTTPFixture(t)
	f.addProfile(brokerTestOther, brokerProofSecondUser)
	f.addProfile(brokerProofThirdObject, "dddddddd-dddd-4ddd-8ddd-dddddddddddd")
	token := f.broker.access(t, nil, 0)
	f.request(t, token, "GET", "/v1/session?scope=user", nil, nil, 401)
	capabilities := f.request(t, token, "GET", "/v1/identity/capabilities", nil, nil, 200)
	var targets []identityProofTarget
	if json.Unmarshal(capabilities["targets"], &targets) != nil || len(targets) != 2 {
		t.Fatal("native/Web callbacks did not share the approved server client namespace")
	}
	token, account, original := f.register(t, brokerTestObject)
	if account.AccountID == identityAccount(AccountIdentity{f.broker.signed.target.Issuer, "api-specific-subject"}).AccountID {
		t.Fatal("registration continued to hash the API audience-specific subject")
	}
	mutation := Mutation{OperationID: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", DocumentID: "stable",
		Kind: "put", Data: json.RawMessage(`{"value":"owned-before-link"}`)}
	f.request(t, token, "POST", "/v1/mutations", &original, mutation, 200)
	initial := f.request(t, token, "GET", "/v1/sync", &original, nil, 200)
	var oldCursor string
	if json.Unmarshal(initial["cursor"], &oldCursor) != nil || oldCursor == "" {
		t.Fatal("fixture did not obtain a real signed journal cursor")
	}
	challenge := f.challenge(t, token, &original, "link", "", f.broker.signed.target.Callback)
	otherToken := f.broker.access(t, map[string]any{"oid": brokerTestOther}, 0)
	oldProof := identityProofRequest{token, f.broker.id(t, challenge, nil, 0)}
	newProof := identityProofRequest{otherToken, f.broker.id(t, challenge, map[string]any{"oid": brokerTestOther}, 0)}
	linked := identityHTTPDecode[identityAccountResponse](t, f.request(t, token, "POST", "/v1/identities/link", &original,
		map[string]any{"challenge": challenge, "reauthentication": oldProof, "identity": newProof}, 200))
	if linked.Account != account.Account || linked.IdentityGeneration != 2 || len(linked.Identities) != 2 {
		t.Fatal("explicit fresh linking moved ownership or failed to rotate the generation")
	}
	for _, action := range []struct {
		method, path string
		body         any
	}{
		{"GET", "/v1/sync", nil}, {"GET", "/v1/snapshot", nil}, {"GET", "/v1/events", nil},
		{"POST", "/v1/mutations", mutation}, {"GET", "/v1/account", nil}, {"POST", "/v1/scopes", map[string]string{"operationId": mutation.OperationID}},
		{"GET", "/v1/identities", nil},
		{"POST", "/v1/identity/challenges", map[string]string{"operation": "link", "callback": f.broker.signed.target.Callback}},
	} {
		response := f.request(t, token, action.method, action.path, &original, action.body, 401)
		if string(response["code"]) != `"identity_session_invalid"` {
			t.Fatal("old identity generation reached data or account management")
		}
	}
	primary := identityHTTPDecode[Scope](t, f.request(t, token, "GET", "/v1/session?scope=user", nil, nil, 200))
	second := identityHTTPDecode[Scope](t, f.request(t, otherToken, "GET", "/v1/session?scope=user", nil, nil, 200))
	if second.ID != original.ID || second.PrincipalID != original.PrincipalID ||
		second.IdentityGeneration != 2 || second.IdentityID == original.IdentityID || second.PermissionVersion != "1" {
		t.Fatal("independent linked API credential failed the stable personal partition/numeric fence")
	}
	f.request(t, otherToken, "GET", "/v1/sync?cursor="+oldCursor, &second, nil, 410)
	covered := f.request(t, otherToken, "GET", "/v1/sync", &second, nil, 200)
	if !bytes.Contains(covered["changes"], []byte("owned-before-link")) {
		t.Fatal("linked credential lost the original personal documents")
	}
	challenge = f.challenge(t, token, &primary, "unlink", second.IdentityID, f.broker.signed.target.Callback)
	retainedProof := identityProofRequest{token, f.broker.id(t, challenge, nil, 0)}
	unlinked := identityHTTPDecode[identityAccountResponse](t, f.request(t, token, "POST", "/v1/identities/unlink", &primary,
		map[string]any{"challenge": challenge, "reauthentication": retainedProof, "identity": retainedProof}, 200))
	if unlinked.IdentityGeneration != 3 || unlinked.Account != account.Account || len(unlinked.Identities) != 1 {
		t.Fatal("unlink did not preserve the stable account/remaining credential")
	}
	f.request(t, otherToken, "GET", "/v1/session?scope=user", nil, nil, 401)
	f.request(t, otherToken, "POST", "/v1/identity/challenges", nil,
		map[string]string{"operation": "register", "callback": f.broker.signed.target.Callback}, 409)
	primary = identityHTTPDecode[Scope](t, f.request(t, token, "GET", "/v1/session?scope=user", nil, nil, 200))
	challenge = f.challenge(t, token, &primary, "link", "", targets[1].Callback)
	linked = identityHTTPDecode[identityAccountResponse](t, f.request(t, token, "POST", "/v1/identities/link", &primary,
		map[string]any{"challenge": challenge,
			"reauthentication": identityProofRequest{token, f.broker.id(t, challenge, nil, 0)},
			"identity":         identityProofRequest{otherToken, f.broker.id(t, challenge, map[string]any{"oid": brokerTestOther}, 0)}}, 200))
	if linked.IdentityGeneration != 4 || linked.Account != account.Account {
		t.Fatal("the second approved callback changed identity ownership")
	}
	primary = identityHTTPDecode[Scope](t, f.request(t, token, "GET", "/v1/session?scope=user", nil, nil, 200))
	challenge = f.challenge(t, token, &primary, "unlink", primary.IdentityID, targets[1].Callback)
	unlinked = identityHTTPDecode[identityAccountResponse](t, f.request(t, token, "POST", "/v1/identities/unlink", &primary,
		map[string]any{"challenge": challenge,
			"reauthentication": identityProofRequest{token, f.broker.id(t, challenge, nil, 0)},
			"identity":         identityProofRequest{otherToken, f.broker.id(t, challenge, map[string]any{"oid": brokerTestOther}, 0)}}, 200))
	if unlinked.IdentityGeneration != 5 || unlinked.CurrentIdentityID != "" {
		t.Fatal("removing the current credential reported a usable old session")
	}
	f.request(t, token, "GET", "/v1/session?scope=user", nil, nil, 401)
	second = identityHTTPDecode[Scope](t, f.request(t, otherToken, "GET", "/v1/session?scope=user", nil, nil, 200))
	if second.ID != original.ID || second.IdentityGeneration != 5 {
		t.Fatal("remaining-identity recovery changed the immutable account")
	}
	f.request(t, otherToken, "POST", "/v1/identity/challenges", &second,
		map[string]string{"operation": "unlink", "callback": targets[1].Callback, "removeIdentityId": second.IdentityID}, 409)
	thirdToken, third, thirdScope := f.register(t, brokerProofThirdObject)
	if third.Account == account.Account {
		t.Fatal("unrelated source object adopted another account")
	}
	f.request(t, thirdToken, "GET", "/v1/session?scope=user&scopeId="+original.ID, nil, nil, 403)
	shared := identityHTTPDecode[SharedScope](t, f.request(t, otherToken, "POST", "/v1/scopes", &second,
		map[string]string{"operationId": "ffffffff-ffff-4fff-8fff-ffffffffffff"}, 200))
	f.request(t, otherToken, "POST", "/v1/scopes/"+shared.ScopeID+"/members", &second, MembershipChange{
		OperationID: "abababab-abab-4bab-8bab-abababababab", AccountID: third.AccountID, Role: "reader", BaseRevision: 1}, 200)
	member := identityHTTPDecode[Scope](t, f.request(t, thirdToken, "GET", "/v1/session?scope=shared&scopeId="+shared.ScopeID, nil, nil, 200))
	if member.IdentityGeneration != thirdScope.IdentityGeneration || member.IdentityID != thirdScope.IdentityID ||
		member.PermissionVersion != "2" {
		t.Fatal("shared policy did not preserve independently bound directory identity")
	}
	f.request(t, thirdToken, "POST", "/v1/mutations", &member, mutation, 403)
}

func TestDirectoryHTTPRejectsUntrustedFreshnessCallbackClaimsAndMalformedAssertions(t *testing.T) {
	f := newIdentityHTTPFixture(t)
	token := f.broker.access(t, nil, 0)
	f.request(t, f.broker.id(t, strings.Repeat("a", 64), nil, 0), "GET", "/v1/identity/capabilities", nil, nil, 401)
	f.request(t, token, "POST", "/v1/identity/challenges", nil,
		map[string]string{"operation": "register", "callback": "com.attacker://auth/redirect"}, 400)
	challenge := f.challenge(t, token, nil, "register", "", f.broker.signed.target.Callback)
	for _, changes := range []map[string]any{
		{"auth_time": nil}, {"auth_time": f.broker.signed.now.Add(-time.Second).Unix()},
		{"auth_time": strconv.FormatInt(f.broker.signed.now.Unix(), 10)},
		{"nonce": strings.Repeat("f", 64)}, {"aud": brokerProofAPI}, {"oid": brokerTestOther},
	} {
		f.request(t, token, "POST", "/v1/identity/register", nil,
			map[string]string{"challenge": challenge, "idToken": f.broker.id(t, challenge, changes, 0)}, 401)
	}
	state, _, err := f.handler.directory.directory.load(withAuthorizationSessions(context.Background()))
	if err != nil || len(state.Accounts) != 0 || len(state.Proofs) != 0 || len(state.Audits) != 0 {
		t.Fatal("untrusted/stale proof changed account ownership, replay or audit metadata", err)
	}
}

type failingDirectoryAuthorization struct {
	*MemoryStore
	fail bool
}

func (store *failingDirectoryAuthorization) ensureDirectoryAccount(ctx context.Context, account directoryAccount) (Account, error) {
	if store.fail {
		return Account{}, protocolError(503, "authorization_store_unavailable")
	}
	return store.MemoryStore.ensureDirectoryAccount(ctx, account)
}

func TestDirectoryHTTPSeparatePersonalInitializationFailureHasExplicitRecovery(t *testing.T) {
	f := newIdentityHTTPFixture(t)
	store := &failingDirectoryAuthorization{MemoryStore: f.handler.store.(*MemoryStore), fail: true}
	f.handler.directory.authorization = store
	token := f.broker.access(t, nil, 0)
	challenge := f.challenge(t, token, nil, "register", "", f.broker.signed.target.Callback)
	response := f.request(t, token, "POST", "/v1/identity/register", nil,
		map[string]string{"challenge": challenge, "idToken": f.broker.id(t, challenge, nil, 0)}, 503)
	if string(response["code"]) != `"authorization_store_unavailable"` || len(store.accounts) != 0 {
		t.Fatal("failed separate personal initialization reported successful signup")
	}
	state, _, err := f.handler.directory.directory.load(withAuthorizationSessions(context.Background()))
	if err != nil || len(state.Accounts) != 1 || len(state.Audits) != 1 {
		t.Fatal("failed personal initialization falsely rolled back the committed directory", err)
	}
	store.fail = false
	scope := identityHTTPDecode[Scope](t, f.request(t, token, "GET", "/v1/session?scope=user", nil, nil, 200))
	if state.Accounts[scope.PrincipalID].Generation != scope.IdentityGeneration || len(store.accounts) != 1 {
		t.Fatal("ordinary fresh session verification failed idempotent personal initialization")
	}
	after, _, _ := f.handler.directory.directory.load(withAuthorizationSessions(context.Background()))
	if !reflect.DeepEqual(state, after) {
		t.Fatal("recovery silently re-registered or rewrote the identity directory")
	}
}

type blockedDirectoryRead struct {
	*MemoryStore
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (store *blockedDirectoryRead) Sync(ctx context.Context, scope string, after int64, limit int, session string) (StorePage, string, error) {
	store.once.Do(func() {
		close(store.entered)
		select {
		case <-store.release:
		case <-ctx.Done():
		}
	})
	return store.MemoryStore.Sync(ctx, scope, after, limit, session)
}

func TestDirectoryHTTPGenerationChangesFenceSlowReadsAndActiveEvents(t *testing.T) {
	for _, events := range []bool{false, true} {
		name := "slow-read"
		if events {
			name = "active-events"
		}
		t.Run(name, func(t *testing.T) {
			f := newIdentityHTTPFixture(t)
			f.addProfile(brokerTestOther, brokerProofSecondUser)
			token, _, scope := f.register(t, brokerTestObject)
			read := &blockedDirectoryRead{MemoryStore: f.handler.store.(*MemoryStore), entered: make(chan struct{}), release: make(chan struct{})}
			if !events {
				f.handler.store = read
			}
			path := "/v1/sync"
			if events {
				path = "/v1/events"
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			request, err := http.NewRequestWithContext(ctx, "GET", f.server.URL+path, nil)
			if err != nil {
				t.Fatal(err)
			}
			request.Header.Set("Authorization", "Bearer "+token)
			bindIdentityTestScope(request, scope)
			type outcome struct {
				code int
				body string
				err  error
			}
			done := make(chan outcome, 1)
			connected := make(chan struct{})
			go func() {
				response, err := f.server.Client().Do(request)
				if err != nil {
					done <- outcome{err: err}
					return
				}
				defer response.Body.Close()
				if events {
					close(connected)
				}
				body, err := io.ReadAll(response.Body)
				done <- outcome{response.StatusCode, string(body), err}
			}()
			if events {
				select {
				case <-connected:
				case <-time.After(5 * time.Second):
					t.Fatal("active event stream did not connect")
				}
			} else {
				select {
				case <-read.entered:
				case <-time.After(5 * time.Second):
					t.Fatal("slow data read did not enter storage")
				}
			}
			challenge := f.challenge(t, token, &scope, "link", "", f.broker.signed.target.Callback)
			f.request(t, token, "POST", "/v1/identities/link", &scope,
				map[string]any{"challenge": challenge,
					"reauthentication": identityProofRequest{token, f.broker.id(t, challenge, nil, 0)},
					"identity": identityProofRequest{f.broker.access(t, map[string]any{"oid": brokerTestOther}, 0),
						f.broker.id(t, challenge, map[string]any{"oid": brokerTestOther}, 0)}}, 200)
			if !events {
				close(read.release)
			}
			select {
			case result := <-done:
				if result.err != nil || !strings.Contains(result.body, "identity_session_invalid") ||
					(!events && result.code != 401) || strings.Contains(result.body, `"changes"`) {
					t.Fatal("generation change escaped post-read or active-SSE reauthorization", result.err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("old data request/event stream failed to stop")
			}
		})
	}
}

func TestDirectoryFactoryRequiresExactOptInAndImmutableTrustedSettings(t *testing.T) {
	f := newIdentityHTTPFixture(t)
	for _, name := range []string{"missing", "unused", "empty-callbacks", "duplicate-callback", "invalid-callback", "wrong-tenant", "empty-namespace", "foreign-workforce", "multiple-clients", "ID-audience"} {
		t.Run(name, func(t *testing.T) {
			config := f.handler.config
			copy := *config.Authorization.Directory
			copy.Callbacks = append([]string(nil), copy.Callbacks...)
			copy.WorkforceTenantIDs = append([]string(nil), copy.WorkforceTenantIDs...)
			config.Authorization.Directory = &copy
			switch name {
			case "missing":
				config.Authorization.Directory = nil
			case "unused":
				config.Authorization.Mode = "builtin"
			case "empty-callbacks":
				copy.Callbacks = nil
			case "duplicate-callback":
				copy.Callbacks = append(copy.Callbacks, copy.Callbacks[0])
			case "invalid-callback":
				copy.Callbacks[0] = "https://user:password@app.invalid/auth-redirect.html"
			case "wrong-tenant":
				copy.TenantID = brokerTestSource
			case "empty-namespace":
				copy.Namespace = ""
			case "foreign-workforce":
				copy.WorkforceTenantIDs[0] = copy.TenantID
			case "multiple-clients":
				config.OIDC.AllowedClientIDs = []string{brokerProofClient, brokerTestOther}
			case "ID-audience":
				config.OIDC.Audience = brokerProofClient
			}
			f.options.Callbacks[0] = "com.changed://auth/redirect"
			f.options.WorkforceTenantIDs[0] = brokerTestTenant
			capabilities := f.request(t, f.broker.access(t, nil, 0), "GET", "/v1/identity/capabilities", nil, nil, 200)
			var targets []identityProofTarget
			if json.Unmarshal(capabilities["targets"], &targets) != nil || targets[0].Callback != f.broker.signed.target.Callback {
				t.Fatal("caller mutation changed the retained trusted directory configuration")
			}
			_, err := NewServerContext(context.Background(), config, NewMemoryStore(), f.broker.verifier.api.verifier)
			if err == nil {
				t.Fatal("unsafe/incomplete directory configuration activated a runtime")
			}
		})
	}
	request := httptest.NewRequest("OPTIONS", "https://api.fixture/v1/identities/link", nil)
	request.Header.Set("Origin", "https://app.invalid")
	request.Header.Set("Access-Control-Request-Method", "POST")
	request.Header.Set("Access-Control-Request-Headers", "authorization,content-type,x-cosmos-sync-principal,x-cosmos-sync-identity,x-cosmos-sync-identity-generation")
	recorder := httptest.NewRecorder()
	f.handler.ServeHTTP(recorder, request)
	if recorder.Code != 204 {
		t.Fatal("explicit lifecycle browser preflight is unavailable")
	}
	request.Header.Set("Origin", "https://other.invalid")
	recorder = httptest.NewRecorder()
	f.handler.ServeHTTP(recorder, request)
	if recorder.Code != 403 {
		t.Fatal("foreign browser origin reached the lifecycle API")
	}
}

func TestDirectoryHTTPReplayAssertionsAndSelfServiceRebinding(t *testing.T) {
	f := newIdentityHTTPFixture(t)
	token := f.broker.access(t, nil, 0)
	challenge := f.challenge(t, token, nil, "register", "", f.broker.signed.target.Callback)
	state, _, err := f.handler.directory.directory.load(withAuthorizationSessions(context.Background()))
	if err != nil || len(state.Accounts) != 0 || len(state.Proofs) != 0 || len(state.Audits) != 0 {
		t.Fatal("untrusted/stale proof changed account ownership, replay or audit metadata", err)
	}
	f.request(t, token, "POST", "/v1/identity/register", nil,
		map[string]any{"challenge": challenge, "idToken": f.broker.id(t, challenge, nil, 0), "accountId": "UNTRUSTED_SENTINEL"}, 400)
	f.request(t, token, "POST", "/v1/identity/register", nil,
		map[string]string{"challenge": challenge, "idToken": f.broker.id(t, challenge, nil, 0)}, 200)
	f.request(t, token, "POST", "/v1/identity/register", nil,
		map[string]string{"challenge": challenge, "idToken": f.broker.id(t, challenge, nil, 0)}, 409)
	scope := identityHTTPDecode[Scope](t, f.request(t, token, "GET", "/v1/session?scope=user", nil, nil, 200))
	for _, name := range []string{"missing", "leading-zero", "foreign-identity", "duplicate-generation", "duplicate-principal"} {
		t.Run(name, func(t *testing.T) {
			request := httptest.NewRequest("GET", "https://api.fixture/v1/account", nil)
			request.Header.Set("Authorization", "Bearer "+token)
			bindIdentityTestScope(request, scope)
			switch name {
			case "missing":
				request.Header.Del(IdentityGenerationHeader)
			case "leading-zero":
				request.Header.Set(IdentityGenerationHeader, "01")
			case "foreign-identity":
				request.Header.Set(IdentityHeader, strings.Repeat("f", 64))
			case "duplicate-generation":
				request.Header.Add(IdentityGenerationHeader, "1")
			case "duplicate-principal":
				request.Header.Add(PrincipalHeader, scope.PrincipalID)
			}
			recorder := httptest.NewRecorder()
			f.handler.ServeHTTP(recorder, request)
			if recorder.Code != 401 || !strings.Contains(recorder.Body.String(), `"identity_session_invalid"`) {
				t.Fatal("ambiguous management assertions bypassed identity binding")
			}
		})
	}
	before, _, _ := f.handler.directory.directory.load(withAuthorizationSessions(context.Background()))
	f.broker.graphMu.Lock()
	f.broker.profile["identities"].([]map[string]any)[0]["issuerAssignedId"] = brokerProofSecondUser
	f.broker.graphMu.Unlock()
	f.request(t, token, "GET", "/v1/session?scope=user", nil, nil, 401)
	after, _, _ := f.handler.directory.directory.load(withAuthorizationSessions(context.Background()))
	if !reflect.DeepEqual(before, after) {
		t.Fatal("broker self-service credential replacement was adopted by an ordinary API token")
	}
}

func TestDirectoryHTTPBrokerSelfServiceChangesDenyOriginalDataAndOwnership(t *testing.T) {
	for _, change := range []string{"added", "removed", "replaced", "disabled", "deleted"} {
		t.Run(change, func(t *testing.T) {
			f := newIdentityHTTPFixture(t)
			token, _, scope := f.register(t, brokerTestObject)
			f.request(t, token, "POST", "/v1/mutations", &scope, Mutation{
				OperationID: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", DocumentID: "owned",
				Kind: "put", Data: json.RawMessage(`{"value":"original-owner"}`),
			}, 200)
			before, _, err := f.handler.directory.directory.load(withAuthorizationSessions(context.Background()))
			if err != nil {
				t.Fatal(err)
			}

			f.broker.graphMu.Lock()
			identities := f.broker.profile["identities"].([]map[string]any)
			switch change {
			case "added":
				f.broker.profile["identities"] = append(identities, map[string]any{
					"signInType": "federated", "issuer": brokerTestIssuer(), "issuerAssignedId": brokerProofSecondUser,
				})
			case "removed":
				f.broker.profile["identities"] = identities[1:]
			case "replaced":
				identities[0]["issuerAssignedId"] = brokerProofSecondUser
			case "disabled":
				f.broker.profile["accountEnabled"] = false
			case "deleted":
				delete(f.broker.profiles, brokerTestObject)
			}
			f.broker.graphMu.Unlock()

			token = f.broker.access(t, nil, 0)
			f.request(t, token, "GET", "/v1/session?scope=user", nil, nil, 401)
			for _, path := range []string{"/v1/account", "/v1/identities", "/v1/sync", "/v1/snapshot"} {
				f.request(t, token, "GET", path, &scope, nil, 401)
			}
			f.request(t, token, "POST", "/v1/identity/challenges", &scope, map[string]any{
				"operation": "link", "callback": f.broker.signed.target.Callback,
				"providerData": map[string]string{"issuerAssignedId": brokerTestUser},
			}, 400)
			f.request(t, token, "POST", "/v1/identity/challenges", nil, map[string]string{
				"operation": "register", "callback": f.broker.signed.target.Callback,
			}, 401)
			after, _, err := f.handler.directory.directory.load(withAuthorizationSessions(context.Background()))
			if err != nil || !reflect.DeepEqual(before, after) {
				t.Fatal("out-of-band broker mutation changed directory ownership, proofs or audit", err)
			}

			f.broker.graphMu.Lock()
			f.broker.profile = brokerTestProfile()
			f.broker.profiles[brokerTestObject] = f.broker.profile
			f.broker.graphMu.Unlock()
			retained := f.request(t, token, "GET", "/v1/sync", &scope, nil, 200)
			if !bytes.Contains(retained["changes"], []byte(`"original-owner"`)) {
				t.Fatal("denied broker mutation removed or reassigned the original owner's data")
			}
		})
	}
}
