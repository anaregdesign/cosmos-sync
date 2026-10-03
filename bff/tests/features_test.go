package integration

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
)

func scopeBinding(t *testing.T, api *testAPI, token, mode string) syncbff.Scope {
	t.Helper()
	response := api.requestRaw(t, token, http.MethodGet, "/v1/session?scope="+mode, nil, false)
	status(t, response, 200)
	var scope syncbff.Scope
	decode(t, response, &scope)
	return scope
}
func bindScope(request *http.Request, scope syncbff.Scope) {
	request.Header.Set(syncbff.ScopeHeader, scope.ID)
	request.Header.Set(syncbff.PrincipalHeader, scope.PrincipalID)
	request.Header.Set(syncbff.PermissionHeader, scope.PermissionVersion)
	request.Header.Set(syncbff.ScopeModeHeader, scope.ScopeMode)
}
func requestScope(t *testing.T, api *testAPI, token, mode, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	scope := scopeBinding(t, api, token, mode)
	var data []byte
	if body != nil {
		var err error
		data, err = json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
	}
	request := httptest.NewRequest(method, "https://api.test"+path, bytes.NewReader(data))
	request.Header.Set("Authorization", "Bearer "+token)
	bindScope(request, scope)
	response := httptest.NewRecorder()
	api.handler.ServeHTTP(response, request)
	return response
}
func tenantGrants(config *syncbff.Config) {
	for _, grant := range []syncbff.Grant{
		{Tenant: "tenant-a", Subject: "alice", ScopeMode: "tenant", PermissionVersion: "shared-1", Active: true, CanRead: true, CanWrite: true},
		{Tenant: "tenant-a", Subject: "bob", ScopeMode: "tenant", PermissionVersion: "shared-1", Active: true, CanRead: true, CanWrite: true},
		{Tenant: "tenant-a", Subject: "reader", ScopeMode: "tenant", PermissionVersion: "shared-1", Active: true, CanRead: true},
		{Tenant: "tenant-b", Subject: "alice", ScopeMode: "tenant", PermissionVersion: "shared-1", Active: true, CanRead: true, CanWrite: true},
	} {
		config.Grants = append(config.Grants, grant)
	}
}

func TestSharedTenantMembershipAndPrincipalBoundReplay(t *testing.T) {
	api := newTestAPI(t, nil, tenantGrants)
	alice := api.issuer.token(t, nil)
	bob := api.issuer.token(t, map[string]any{"sub": "bob"})
	reader := api.issuer.token(t, map[string]any{"sub": "reader"})
	a, b := scopeBinding(t, api, alice, "tenant"), scopeBinding(t, api, bob, "tenant")
	if a.ID != b.ID || a.PrincipalID == b.PrincipalID {
		t.Fatalf("bad shared scope %+v %+v", a, b)
	}
	if scopeBinding(t, api, alice, "user").ID == a.ID {
		t.Fatal("personal and tenant scopes collided")
	}
	put := mutation(operationID(1), "shared", "put", 0, map[string]any{"title": "alice"})
	status(t, requestScope(t, api, alice, "tenant", "POST", "/v1/mutations", put), 200)
	var page syncResponse
	decode(t, requestScope(t, api, bob, "tenant", "GET", "/v1/sync", nil), &page)
	if len(page.Changes) != 1 {
		t.Fatal("member cannot read tenant data")
	}
	status(t, requestScope(t, api, reader, "tenant", "POST", "/v1/mutations", mutation(operationID(2), "denied", "put", 0, map[string]any{})), 403)
	// The same operation UUID belongs to each actor independently in one partition.
	status(t, requestScope(t, api, bob, "tenant", "POST", "/v1/mutations", mutation(operationID(1), "bob-note", "put", 0, map[string]any{"owner": "bob"})), 200)
	status(t, requestScope(t, api, alice, "tenant", "POST", "/v1/mutations", put), 200)
	request := httptest.NewRequest("POST", "https://api.test/v1/mutations", strings.NewReader(`{"operationId":"11111111-1111-4111-8111-111111111111","documentId":"wrong-actor","kind":"put","data":{},"baseVersion":0}`))
	request.Header.Set("Authorization", "Bearer "+bob)
	bindScope(request, a)
	recorder := httptest.NewRecorder()
	api.handler.ServeHTTP(recorder, request)
	errorCode(t, recorder, 403, "session_mismatch")
	decode(t, requestScope(t, api, bob, "tenant", "GET", "/v1/sync", nil), &page)
	if len(page.Changes) != 2 {
		t.Fatal("actor swap changed shared data")
	}
	other := api.issuer.token(t, map[string]any{"tid": "tenant-b"})
	var isolated syncResponse
	decode(t, requestScope(t, api, other, "tenant", "GET", "/v1/sync", nil), &isolated)
	if len(isolated.Changes) != 0 {
		t.Fatal("shared scope crossed tenants")
	}
	decode(t, requestScope(t, api, alice, "tenant", "GET", "/v1/sync", nil), &page)
	errorCode(t, requestScope(t, api, bob, "tenant", "GET", syncPath(page.Cursor, 100), nil), 410, "resync_required")
	status(t, api.requestRaw(t, alice, "GET", "/v1/session?scope=arbitrary-partition", nil, false), 400)
}

func TestWriteCapabilityRequiresReadInEveryGrantSource(t *testing.T) {
	api := newTestAPI(t, nil, nil)
	token := api.issuer.token(t, nil)
	invalid := syncbff.Grant{Tenant: "tenant-a", Subject: "alice", PermissionVersion: "1", Active: true, CanWrite: true}
	config := api.config
	config.Grants = []syncbff.Grant{invalid}
	if _, err := syncbff.NewServer(config, api.store, api.issuer.verifier(t)); err == nil {
		t.Fatal("write-only inline grant accepted")
	}
	file := filepath.Join(t.TempDir(), "grants.json")
	body, _ := json.Marshal([]syncbff.Grant{invalid})
	if err := os.WriteFile(file, body, 0600); err != nil {
		t.Fatal(err)
	}
	config = api.config
	config.GrantsFile = file
	handler, err := syncbff.NewServer(config, api.store, api.issuer.verifier(t))
	if err != nil {
		t.Fatal(err)
	}
	api.handler = handler
	for _, path := range []string{"/v1/session", "/v1/sync", "/v1/snapshot", "/v1/events"} {
		errorCode(t, api.requestRaw(t, token, "GET", path, nil, false), 503, "grant_store_unavailable")
	}
	errorCode(t, api.requestRaw(t, token, "POST", "/v1/mutations", nil, false), 503, "grant_store_unavailable")
	api = newTestAPI(t, nil, nil)
	denied := api.issuer.token(t, map[string]any{"sub": "no-access"})
	errorCode(t, api.requestRaw(t, denied, "GET", "/v1/session", nil, false), 403, "forbidden")
}

func TestHTTPRejectsRoundedUnsafeNumbersBeforeSharedScopeWrite(t *testing.T) {
	api := newTestAPI(t, nil, tenantGrants)
	token := api.issuer.token(t, nil)
	binding := scopeBinding(t, api, token, "tenant")
	for _, number := range []string{"9007199254740991.5", "9007199254740992.1", "100000000000000000000.1", "-9007199254740991.5", "90071992547409915e-1"} {
		t.Run(number, func(t *testing.T) {
			body := `{"operationId":"11111111-1111-4111-8111-111111111111","documentId":"poison","kind":"put","baseVersion":0,"data":{"nested":[{"number":` + number + `}]}}`
			request := httptest.NewRequest("POST", "https://api.test/v1/mutations", strings.NewReader(body))
			request.Header.Set("Authorization", "Bearer "+token)
			bindScope(request, binding)
			response := httptest.NewRecorder()
			api.handler.ServeHTTP(response, request)
			errorCode(t, response, 400, "invalid_number")
		})
	}
	bob := api.issuer.token(t, map[string]any{"sub": "bob"})
	var page syncResponse
	decode(t, requestScope(t, api, bob, "tenant", "GET", "/v1/sync", nil), &page)
	if len(page.Changes) != 0 {
		t.Fatal("unsafe numbers poisoned the shared journal")
	}
	// Rejected payloads reserve neither the operation UUID nor document ID.
	status(t, requestScope(t, api, token, "tenant", "POST", "/v1/mutations", mutation("11111111-1111-4111-8111-111111111111", "poison", "put", 0, map[string]any{"number": 1.5})), 200)
	decode(t, requestScope(t, api, bob, "tenant", "GET", "/v1/sync", nil), &page)
	if len(page.Changes) != 1 || page.Changes[0].Data["number"] != 1.5 {
		t.Fatal("representable replacement did not synchronize across members")
	}
}

type snapshotResponse struct {
	Documents  []syncbff.Document `json:"documents"`
	Cursor     string             `json:"cursor"`
	SyncCursor string             `json:"syncCursor"`
	Cutover    int64              `json:"cutoverSequence"`
	HasMore    bool               `json:"hasMore"`
}

func TestSnapshotFixedCutoverResumeTombstonesAndEpoch(t *testing.T) {
	api := newTestAPI(t, nil, func(c *syncbff.Config) { c.Snapshots.Enabled = true })
	token := api.issuer.token(t, nil)
	for i, id := range []string{"z", "a", "deleted"} {
		status(t, api.request(t, token, "POST", "/v1/mutations", mutation(operationID(i+1), id, "put", 0, map[string]any{"value": i})), 200)
	}
	status(t, api.request(t, token, "POST", "/v1/mutations", mutation(operationID(4), "deleted", "delete", 3, nil)), 200)
	var first snapshotResponse
	decode(t, api.request(t, token, "GET", "/v1/snapshot?limit=1", nil), &first)
	if first.Cutover != 4 || len(first.Documents) != 1 || first.Documents[0].ID != "a" || !first.HasMore {
		t.Fatalf("first snapshot %+v", first)
	}
	status(t, api.request(t, token, "POST", "/v1/mutations", mutation(operationID(5), "z", "put", 1, map[string]any{"value": "after-cutover"})), 200)
	// Restart the handler while resuming a stable cutover through immutable history.
	handler, err := syncbff.NewServer(api.config, api.store, api.issuer.verifier(t))
	if err != nil {
		t.Fatal(err)
	}
	api.handler = handler
	var second, last snapshotResponse
	decode(t, api.request(t, token, "GET", "/v1/snapshot?limit=1&cursor="+url.QueryEscape(first.Cursor), nil), &second)
	decode(t, api.request(t, token, "GET", "/v1/snapshot?limit=1&cursor="+url.QueryEscape(second.Cursor), nil), &last)
	if second.Documents[0].ID != "deleted" || !second.Documents[0].Deleted || last.Documents[0].ID != "z" || last.Documents[0].Version != 1 || last.HasMore || last.Cutover != 4 {
		t.Fatalf("snapshot drift %+v %+v", second, last)
	}
	var tail syncResponse
	decode(t, api.request(t, token, "GET", syncPath(last.SyncCursor, 100), nil), &tail)
	if len(tail.Changes) != 1 || tail.Changes[0].Version != 5 {
		t.Fatalf("cutover missed concurrent change %+v", tail)
	}
	config := api.config
	config.HistoryEpoch = "new-history"
	handler, err = syncbff.NewServer(config, api.store, api.issuer.verifier(t))
	if err != nil {
		t.Fatal(err)
	}
	api.handler = handler
	errorCode(t, api.request(t, token, "GET", "/v1/snapshot?cursor="+url.QueryEscape(first.Cursor), nil), 410, "resync_required")
	errorCode(t, api.request(t, token, "GET", syncPath(last.SyncCursor, 100), nil), 410, "resync_required")
}

func TestSnapshotBudgetAndCapacityNeverDeleteAcceptedReceipts(t *testing.T) {
	api := newTestAPI(t, nil, func(c *syncbff.Config) {
		c.Snapshots = syncbff.SnapshotOptions{Enabled: true, MaxChanges: 1}
		c.Retention = syncbff.RetentionOptions{MaxJournalEvents: 2, MaxEstimatedRetainedBytes: 128 * 1024 * 1024}
	})
	token := api.issuer.token(t, nil)
	first := mutation(operationID(1), "a", "put", 0, map[string]any{"value": 1})
	status(t, api.request(t, token, "POST", "/v1/mutations", first), 200)
	status(t, api.request(t, token, "POST", "/v1/mutations", mutation(operationID(2), "a", "delete", 1, nil)), 200)
	errorCode(t, api.request(t, token, "POST", "/v1/mutations", mutation(operationID(3), "b", "put", 0, map[string]any{})), 507, "scope_capacity_exceeded")
	status(t, api.request(t, token, "POST", "/v1/mutations", first), 200)
	errorCode(t, api.request(t, token, "GET", "/v1/snapshot", nil), 413, "snapshot_limit_exceeded")
	var journal syncResponse
	decode(t, api.request(t, token, "GET", "/v1/sync", nil), &journal)
	if len(journal.Changes) != 2 || !journal.Changes[1].Deleted {
		t.Fatal("capacity discarded journal/tombstone")
	}
	api = newTestAPI(t, nil, func(c *syncbff.Config) {
		c.Retention = syncbff.RetentionOptions{MaxJournalEvents: 100, MaxEstimatedRetainedBytes: 8192}
	})
	token = api.issuer.token(t, nil)
	status(t, api.request(t, token, "POST", "/v1/mutations", first), 200)
	errorCode(t, api.request(t, token, "POST", "/v1/mutations", mutation(operationID(2), "b", "put", 0, map[string]any{})), 507, "scope_capacity_exceeded")
}

func TestExplicitCORSPreflightAndRedactedMetrics(t *testing.T) {
	api := newTestAPI(t, nil, func(c *syncbff.Config) {
		c.AllowedOrigins = []string{"https://app.example"}
		c.MetricsToken = "test-metrics-secret"
	})
	token := api.issuer.token(t, nil)
	preflight := func(origin string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("OPTIONS", "https://api.test/v1/events", nil)
		r.Header.Set("Origin", origin)
		r.Header.Set("Access-Control-Request-Method", "GET")
		r.Header.Set("Access-Control-Request-Headers", "authorization,x-cosmos-sync-principal,last-event-id")
		w := httptest.NewRecorder()
		api.handler.ServeHTTP(w, r)
		return w
	}
	response := preflight("https://app.example")
	status(t, response, 204)
	if response.Header().Get("Access-Control-Allow-Origin") != "https://app.example" || !strings.Contains(response.Header().Get("Access-Control-Allow-Headers"), syncbff.PrincipalHeader) {
		t.Fatal("missing explicit preflight headers")
	}
	status(t, preflight("https://evil.example"), 403)
	status(t, api.request(t, token, "GET", "/v1/session", nil), 200)
	response = api.requestRaw(t, "test-metrics-secret", "GET", "/metrics", nil, false)
	status(t, response, 200)
	text := response.Body.String()
	for _, secret := range []string{"alice", "tenant-a", "test-metrics-secret", token} {
		if strings.Contains(text, secret) {
			t.Fatal("metrics contains principal/credential material")
		}
	}
	if !strings.Contains(text, "cosmos_sync_requests_total") {
		t.Fatal("metrics missing")
	}
	status(t, api.requestRaw(t, token, "GET", "/metrics", nil, false), 401)
}

func TestRateAndDocumentLimitsAreBounded(t *testing.T) {
	api := newTestAPI(t, nil, func(c *syncbff.Config) {
		c.Limits = syncbff.LimitOptions{Enabled: true, Burst: 1, RequestsPerMinute: 1}
	})
	token := api.issuer.token(t, nil)
	status(t, api.requestRaw(t, token, "GET", "/v1/session", nil, false), 200)
	response := api.requestRaw(t, token, "GET", "/v1/session", nil, false)
	errorCode(t, response, 429, "rate_limit")
	if response.Header().Get("Retry-After") == "" {
		t.Fatal("rate-limit retry missing")
	}
	api = newTestAPI(t, nil, func(c *syncbff.Config) { c.Limits.MaxDocumentBytes = 16 })
	token = api.issuer.token(t, nil)
	errorCode(t, api.request(t, token, "POST", "/v1/mutations", mutation(operationID(1), "note", "put", 0, map[string]any{"text": strings.Repeat("x", 20)})), 400, "document_too_large")
}

type blockedSyncStore struct {
	syncbff.Store
	entered chan struct{}
	release chan struct{}
}

func (s *blockedSyncStore) Sync(ctx context.Context, scope string, after int64, limit int, session string) (syncbff.StorePage, string, error) {
	close(s.entered)
	select {
	case <-ctx.Done():
		return syncbff.StorePage{}, session, ctx.Err()
	case <-s.release:
		return s.Store.Sync(ctx, scope, after, limit, session)
	}
}

func TestConcurrentRequestsAndPageBudgetNeverSkip(t *testing.T) {
	api := newTestAPI(t, nil, func(c *syncbff.Config) {
		c.Limits = syncbff.LimitOptions{Enabled: true, MaxConcurrentRequests: 1}
	})
	token := api.issuer.token(t, nil)
	binding := scopeBinding(t, api, token, "user")
	blocked := &blockedSyncStore{Store: api.store, entered: make(chan struct{}), release: make(chan struct{})}
	handler, err := syncbff.NewServer(api.config, blocked, api.issuer.verifier(t))
	if err != nil {
		t.Fatal(err)
	}
	api.handler = handler
	request := httptest.NewRequest("GET", "https://api.test/v1/sync", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	bindScope(request, binding)
	first := httptest.NewRecorder()
	done := make(chan struct{})
	go func() { api.handler.ServeHTTP(first, request); close(done) }()
	select {
	case <-blocked.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("first request did not reach storage")
	}
	errorCode(t, api.requestRaw(t, token, "GET", "/v1/session", nil, false), 429, "concurrency_limit")
	close(blocked.release)
	<-done
	status(t, first, 200)

	api = newTestAPI(t, nil, func(c *syncbff.Config) { c.Limits.MaxSyncPageBytes = syncbff.MaxDocumentBytes + 4096 })
	token = api.issuer.token(t, nil)
	for i, id := range []string{"a", "b", "c"} {
		status(t, api.request(t, token, "POST", "/v1/mutations", mutation(operationID(i+1), id, "put", 0, map[string]any{"text": strings.Repeat("x", 100000)})), 200)
	}
	var page syncResponse
	decode(t, api.request(t, token, "GET", "/v1/sync", nil), &page)
	if len(page.Changes) != 2 || !page.HasMore || page.Changes[1].Version != 2 {
		t.Fatal("response size budget did not stop at an applied position")
	}
	decode(t, api.request(t, token, "GET", syncPath(page.Cursor, 100), nil), &page)
	if len(page.Changes) != 1 || page.Changes[0].Version != 3 || page.HasMore {
		t.Fatal("response size budget skipped a change")
	}
}

func readSSEEvent(t *testing.T, reader *bufio.Reader) (string, string, string) {
	t.Helper()
	event, id, data := "", "", ""
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("SSE read failed: %v", err)
		}
		line = strings.TrimSuffix(line, "\n")
		if line == "" && event != "" {
			return event, id, data
		}
		if strings.HasPrefix(line, "event: ") {
			event = strings.TrimPrefix(line, "event: ")
		}
		if strings.HasPrefix(line, "id: ") {
			id = strings.TrimPrefix(line, "id: ")
		}
		if strings.HasPrefix(line, "data: ") {
			data = strings.TrimPrefix(line, "data: ")
		}
	}
}
func TestSSEHintsResumeAndGrantRevocation(t *testing.T) {
	grantFile := filepath.Join(t.TempDir(), "grants.json")
	var grants []syncbff.Grant
	api := newTestAPI(t, nil, func(c *syncbff.Config) {
		grants = append(grants, c.Grants...)
		body, _ := json.Marshal(grants)
		if os.WriteFile(grantFile, body, 0600) != nil {
			t.Fatal("grants write")
		}
		c.GrantsFile = grantFile
		c.Events = syncbff.EventOptions{Enabled: true, PollMilliseconds: 5, HeartbeatMilliseconds: 20, MaxStreamSeconds: 3}
	})
	token := api.issuer.token(t, nil)
	status(t, api.request(t, token, "POST", "/v1/mutations", mutation(operationID(1), "note", "put", 0, map[string]any{"value": 1})), 200)
	binding := scopeBinding(t, api, token, "user")
	server := httptest.NewTLSServer(api.handler)
	defer server.Close()
	client := server.Client()
	client.Timeout = 5 * time.Second
	connect := func(resume string) *http.Response {
		request, _ := http.NewRequest("GET", server.URL+"/v1/events", nil)
		request.Header.Set("Authorization", "Bearer "+token)
		bindScope(request, binding)
		if resume != "" {
			request.Header.Set("Last-Event-ID", resume)
		}
		response, err := client.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		if response.StatusCode != 200 {
			body, _ := io.ReadAll(response.Body)
			response.Body.Close()
			t.Fatalf("SSE %d %s", response.StatusCode, body)
		}
		return response
	}
	stream := connect("")
	event, resume, data := readSSEEvent(t, bufio.NewReader(stream.Body))
	if event != "change" || resume == "" || !strings.Contains(data, resume) {
		t.Fatalf("bad SSE event %s %s %s", event, resume, data)
	}
	stream.Body.Close()
	status(t, api.request(t, token, "POST", "/v1/mutations", mutation(operationID(2), "note", "put", 1, map[string]any{"value": 2})), 200)
	stream = connect(resume)
	defer stream.Body.Close()
	reader := bufio.NewReader(stream.Body)
	event, next, _ := readSSEEvent(t, reader)
	if event != "change" || next == resume {
		t.Fatal("SSE did not resume durable journal hints")
	}
	// A hint token must never be accepted as the client's applied sync position.
	errorCode(t, api.request(t, token, "GET", syncPath(next, 100), nil), 410, "resync_required")
	for i := range grants {
		if grants[i].Subject == "alice" && grants[i].Tenant == "tenant-a" {
			grants[i].Active = false
		}
	}
	body, _ := json.Marshal(grants)
	replacement := grantFile + ".next"
	if os.WriteFile(replacement, body, 0600) != nil || os.Rename(replacement, grantFile) != nil {
		t.Fatal("atomic grant revoke")
	}
	event, _, data = readSSEEvent(t, reader)
	if event != "error" || !strings.Contains(data, "forbidden") {
		t.Fatalf("stream failed to recheck grant %s %s", event, data)
	}
}

func TestSSEStreamBoundAndTokenExpiry(t *testing.T) {
	api := newTestAPI(t, nil, func(c *syncbff.Config) {
		c.Events = syncbff.EventOptions{Enabled: true, PollMilliseconds: 10, HeartbeatMilliseconds: 20, MaxStreamSeconds: 4}
		c.Limits.MaxConcurrentStreams = 1
	})
	token := api.issuer.token(t, map[string]any{"exp": time.Now().Add(2 * time.Second).Unix()})
	binding := scopeBinding(t, api, token, "user")
	server := httptest.NewTLSServer(api.handler)
	defer server.Close()
	client := server.Client()
	client.Timeout = 5 * time.Second
	connect := func() *http.Response {
		request, _ := http.NewRequest("GET", server.URL+"/v1/events", nil)
		request.Header.Set("Authorization", "Bearer "+token)
		bindScope(request, binding)
		response, err := client.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		return response
	}
	stream := connect()
	defer stream.Body.Close()
	if stream.StatusCode != 200 {
		t.Fatalf("stream status %d", stream.StatusCode)
	}
	second := connect()
	defer second.Body.Close()
	if second.StatusCode != 429 || second.Header.Get("Retry-After") == "" {
		t.Fatal("second stream exceeded concurrency cap")
	}
	event, _, data := readSSEEvent(t, bufio.NewReader(stream.Body))
	if event != "error" || !strings.Contains(data, "unauthorized") {
		t.Fatalf("expired token retained stream: %s %s", event, data)
	}
	if _, err := io.ReadAll(stream.Body); err != nil {
		t.Fatal(err)
	}
}

func TestSSESlowPollRechecksGrantAndHonorsLifetime(t *testing.T) {
	for _, revoke := range []bool{true, false} {
		name := "lifetime-cancels-query"
		if revoke {
			name = "revocation-during-query"
		}
		t.Run(name, func(t *testing.T) {
			grantFile := filepath.Join(t.TempDir(), "grants.json")
			grants := []syncbff.Grant{{Tenant: "tenant-a", Subject: "alice", PermissionVersion: "1", Active: true, CanRead: true, CanWrite: true}}
			body, _ := json.Marshal(grants)
			if err := os.WriteFile(grantFile, body, 0600); err != nil {
				t.Fatal(err)
			}
			api := newTestAPI(t, nil, func(c *syncbff.Config) {
				c.GrantsFile = grantFile
				c.Events = syncbff.EventOptions{Enabled: true, PollMilliseconds: 10, HeartbeatMilliseconds: 20, MaxStreamSeconds: 1}
			})
			token := api.issuer.token(t, nil)
			status(t, api.request(t, token, "POST", "/v1/mutations", mutation(operationID(1), "note", "put", 0, map[string]any{})), 200)
			binding := scopeBinding(t, api, token, "user")
			blocked := &blockedSyncStore{Store: api.store, entered: make(chan struct{}), release: make(chan struct{})}
			handler, err := syncbff.NewServer(api.config, blocked, api.issuer.verifier(t))
			if err != nil {
				t.Fatal(err)
			}
			server := httptest.NewTLSServer(handler)
			defer server.Close()
			client := server.Client()
			client.Timeout = 4 * time.Second
			request, _ := http.NewRequest("GET", server.URL+"/v1/events", nil)
			request.Header.Set("Authorization", "Bearer "+token)
			bindScope(request, binding)
			stream, err := client.Do(request)
			if err != nil {
				t.Fatal(err)
			}
			defer stream.Body.Close()
			<-blocked.entered
			if revoke {
				grants[0].Active = false
				body, _ = json.Marshal(grants)
				replacement := grantFile + ".next"
				if os.WriteFile(replacement, body, 0600) != nil || os.Rename(replacement, grantFile) != nil {
					t.Fatal("atomic grant revoke")
				}
				close(blocked.release)
			}
			body, err = io.ReadAll(stream.Body)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(body), "event: change") {
				t.Fatal("slow query emitted a hint beyond authorization/lifetime")
			}
			if revoke && !strings.Contains(string(body), `"code":"forbidden"`) {
				t.Fatalf("revoked slow query did not close with forbidden: %s", body)
			}
		})
	}
}
