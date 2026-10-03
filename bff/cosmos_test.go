package syncbff

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/runtime"
	"github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"
)

type transportFunc func(*http.Request) (*http.Response, error)

func (f transportFunc) Do(r *http.Request) (*http.Response, error) { return f(r) }
func cosmosResponse(r *http.Request, status int, body, token string) *http.Response {
	return &http.Response{Request: r, StatusCode: status, Header: http.Header{"Content-Type": []string{"application/json"}, "X-Ms-Session-Token": []string{token}, "Etag": []string{"\"etag\""}}, Body: io.NopCloser(strings.NewReader(body))}
}
func testCosmos(t *testing.T, transport transportFunc) *CosmosStore {
	t.Helper()
	key, err := azcosmos.NewKeyCredential(base64.StdEncoding.EncodeToString(make([]byte, 32)))
	if err != nil {
		t.Fatal(err)
	}
	client, err := azcosmos.NewClientWithKey("https://cosmos.test", key, &azcosmos.ClientOptions{ClientOptions: azcore.ClientOptions{Transport: transport, Retry: policy.RetryOptions{MaxRetries: -1}, PerCallPolicies: []policy.Policy{batchWirePolicy{}, accountGuard{}}}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Close)
	container, err := client.NewContainer("db", "sync")
	if err != nil {
		t.Fatal(err)
	}
	return &CosmosStore{container: container, client: client}
}

func TestCosmosActualBatchWireBoundaryAndAtomicOperations(t *testing.T) {
	m := Mutation{OperationID: "11111111-1111-4111-8111-111111111111", DocumentID: "note", Kind: "put", Data: json.RawMessage(`{"text":"` + strings.Repeat("<", MaxDocumentBytes-len(`{"text":""}`)) + `"}`)}
	hash, err := validateMutation(&m, "scope")
	if err != nil {
		t.Fatal(err)
	}
	var batchCount int
	store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "" || r.URL.Path == "/" {
			return cosmosResponse(r, 200, `{"readableLocations":[{"name":"Test","databaseAccountEndpoint":"https://cosmos.test"}],"writableLocations":[{"name":"Test","databaseAccountEndpoint":"https://cosmos.test"}],"enableMultipleWriteLocations":false,"userConsistencyPolicy":{"defaultConsistencyLevel":"Session"}}`, ""), nil
		}
		if r.Method == http.MethodGet {
			return cosmosResponse(r, 404, `{"code":"NotFound","message":"missing"}`, "read-session"), nil
		}
		batchCount++
		if r.Header.Get("x-ms-documentdb-partitionkey") != `["scope"]` || !strings.EqualFold(r.Header.Get("x-ms-cosmos-batch-atomic"), "true") {
			t.Fatal("unscoped/non-atomic batch")
		}
		if r.Header.Get("x-ms-session-token") != "read-session" {
			t.Fatal("batch did not propagate read session")
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatal(err)
		}
		if len(body) > 2*1024*1024 || strings.Contains(string(body), `\u003c`) {
			t.Fatalf("actual SDK batch size/escaping wrong: %d", len(body))
		}
		var operations []struct {
			Operation string     `json:"operationType"`
			Item      storedItem `json:"resourceBody"`
		}
		if json.Unmarshal(body, &operations) != nil || len(operations) != 4 {
			t.Fatal("batch must have four operations")
		}
		for i, kind := range []string{"head", "document", "change", "receipt"} {
			if operations[i].Operation != "Create" || operations[i].Item.Kind != kind || operations[i].Item.ScopeID != "scope" {
				t.Fatalf("wrong atomic member %+v", operations[i])
			}
		}
		return cosmosResponse(r, 200, `[{"statusCode":201},{"statusCode":201},{"statusCode":201},{"statusCode":201}]`, "write-session"), nil
	})
	doc, session, err := store.Mutate(context.Background(), "scope", m, hash, "")
	if err != nil || doc.Version != 1 || session != "write-session" || batchCount != 1 {
		t.Fatalf("mutation result %+v %s batches%d err%v", doc, session, batchCount, err)
	}
}

func TestCosmosOverlappingReceiptReplayAndSessionPropagation(t *testing.T) {
	m := Mutation{OperationID: "11111111-1111-4111-8111-111111111111", DocumentID: "note", Kind: "put", Data: json.RawMessage(`{"title":"accepted"}`)}
	hash, err := validateMutation(&m, "scope")
	if err != nil {
		t.Fatal(err)
	}
	doc := Document{ID: "note", Data: m.Data, Version: 1}
	receiptReads := 0
	calls := 0
	store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "" || r.URL.Path == "/" {
			return cosmosResponse(r, 200, `{"readableLocations":[{"name":"Test","databaseAccountEndpoint":"https://cosmos.test"}],"writableLocations":[{"name":"Test","databaseAccountEndpoint":"https://cosmos.test"}],"enableMultipleWriteLocations":false,"userConsistencyPolicy":{"defaultConsistencyLevel":"Session"}}`, ""), nil
		}
		calls++
		if r.Header.Get("x-ms-documentdb-partitionkey") != `["scope"]` {
			t.Errorf("not scoped: %s", r.Header.Get("x-ms-documentdb-partitionkey"))
		}
		wantToken := []string{"initial", "receipt404", "head", "document"}[calls-1]
		if token := r.Header.Get("x-ms-session-token"); token != wantToken {
			t.Errorf("session call %d got %q want %q", calls, token, wantToken)
		}
		var body []byte
		switch {
		case strings.Contains(r.URL.Path, "/docs/r:"):
			receiptReads++
			if receiptReads == 1 {
				return cosmosResponse(r, 404, `{"code":"NotFound","message":"missing"}`, "receipt404"), nil
			}
			body, _ = encodeJSON(storedItem{ID: "r:" + m.OperationID, ScopeID: "scope", Kind: "receipt", RequestHash: hash, Document: &doc})
			return cosmosResponse(r, 200, string(body), "receipt-final"), nil
		case strings.HasSuffix(r.URL.Path, "/docs/head"):
			body, _ = encodeJSON(storedItem{ID: "head", ScopeID: "scope", Kind: "head", Sequence: 1})
			return cosmosResponse(r, 200, string(body), "head"), nil
		case strings.HasSuffix(r.URL.Path, "/docs/d:note"):
			body, _ = encodeJSON(storedItem{ID: "d:note", ScopeID: "scope", Kind: "document", Document: &doc})
			return cosmosResponse(r, 200, string(body), "document"), nil
		default:
			t.Fatalf("unexpected Cosmos request %s %s", r.Method, r.URL.Path)
			return nil, nil
		}
	})
	got, token, err := store.Mutate(context.Background(), "scope", m, hash, "initial")
	if err != nil || got.Version != 1 || token != "receipt-final" || receiptReads != 2 {
		t.Fatalf("replay got %+v token=%s reads=%d err=%v", got, token, receiptReads, err)
	}
}

func TestBatchCausalStatus(t *testing.T) {
	for _, tc := range []struct {
		name    string
		success bool
		codes   []int32
		want    int
	}{
		{"committed", true, []int32{200, 201, 201, 201}, 200}, {"etag", false, []int32{424, 412, 424, 424}, 412}, {"receipt_conflict", false, []int32{424, 424, 424, 409}, 409},
		{"throttle", false, []int32{424, 429, 424, 424}, 429}, {"incomplete", true, []int32{200}, 503}, {"dependencies", false, []int32{424, 424, 424, 424}, 503}, {"failed_even_when_success_true", true, []int32{424, 412, 424, 424}, 412},
	} {
		t.Run(tc.name, func(t *testing.T) {
			response := azcosmos.TransactionalBatchResponse{Success: tc.success}
			for _, code := range tc.codes {
				response.OperationResults = append(response.OperationResults, azcosmos.TransactionalBatchResult{StatusCode: code})
			}
			if got := batchStatus(response); got != tc.want {
				t.Fatalf("status %d want%d", got, tc.want)
			}
		})
	}
}

func TestDocumentBoundaryAndBatchWireSize(t *testing.T) {
	data := json.RawMessage(`{"text":"` + strings.Repeat("<", MaxDocumentBytes-len(`{"text":""}`)) + `"}`)
	m := Mutation{OperationID: "11111111-1111-4111-8111-111111111111", DocumentID: "note", Kind: "put", Data: data}
	if _, err := validateMutation(&m, "scope"); err != nil {
		t.Fatal(err)
	}
	doc := Document{ID: "note", Data: m.Data, Version: 1}
	var total int
	for _, kind := range []string{"document", "change", "receipt"} {
		body, err := encodeJSON(storedItem{ID: kind, ScopeID: "scope", Kind: kind, Document: &doc})
		if err != nil {
			t.Fatal(err)
		}
		total += len(body)
		if strings.Contains(string(body), `\u003c`) {
			t.Fatal("HTML escaping expands payload")
		}
	}
	if total >= 2*1024*1024 {
		t.Fatalf("batch %d exceeds2MiB", total)
	}
	m.Data = json.RawMessage(`{"text":"` + strings.Repeat("<", MaxDocumentBytes) + `"}`)
	if _, err := validateMutation(&m, "scope"); err == nil {
		t.Fatal("oversized document accepted")
	}
}

func TestSignedContextsSeparatePurposesScopesAndGrants(t *testing.T) {
	s := &Server{key: make([]byte, 32)}
	scope := Scope{ID: "alice", PermissionVersion: "1"}
	token := s.sign("session-v1", signedContext{Version: 1, Scope: scope.ID, Permission: scope.PermissionVersion, Token: "nonprivileged-session"})
	if _, err := s.verifyContext("session-v1", token, scope); err != nil {
		t.Fatal(err)
	}
	for _, value := range []struct {
		purpose string
		scope   Scope
	}{{"cursor-v1", scope}, {"session-v1", Scope{ID: "bob", PermissionVersion: "1"}}, {"session-v1", Scope{ID: "alice", PermissionVersion: "2"}}} {
		if _, err := s.verifyContext(value.purpose, token, value.scope); err == nil {
			t.Fatal("context accepted under wrong binding")
		}
	}
}

func TestAccountGuardRejectsUnsafeCosmosConfiguration(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		ok         bool
	}{
		{"session", `{"enableMultipleWriteLocations":false,"writableLocations":[{}],"userConsistencyPolicy":{"defaultConsistencyLevel":"Session"}}`, true},
		{"strong", `{"enableMultipleWriteLocations":false,"writableLocations":[{}],"userConsistencyPolicy":{"defaultConsistencyLevel":"Strong"}}`, true},
		{"multiwrite", `{"enableMultipleWriteLocations":true,"writableLocations":[{},{}],"userConsistencyPolicy":{"defaultConsistencyLevel":"Session"}}`, false},
		{"eventual", `{"enableMultipleWriteLocations":false,"writableLocations":[{}],"userConsistencyPolicy":{"defaultConsistencyLevel":"Eventual"}}`, false},
		{"malformed", `{}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pipeline := runtime.NewPipeline("test", "v1.0.0", runtime.PipelineOptions{}, &policy.ClientOptions{PerCallPolicies: []policy.Policy{accountGuard{}}, Retry: policy.RetryOptions{MaxRetries: -1}, Transport: transportFunc(func(r *http.Request) (*http.Response, error) { return cosmosResponse(r, 200, tc.body, ""), nil })})
			request, err := runtime.NewRequest(context.Background(), http.MethodGet, "https://cosmos.test")
			if err != nil {
				t.Fatal(err)
			}
			response, err := pipeline.Do(request)
			if (err == nil) != tc.ok {
				t.Fatalf("guard error %v wantOK %v", err, tc.ok)
			}
			if tc.ok {
				defer response.Body.Close()
				body, _ := io.ReadAll(response.Body)
				if string(body) != tc.body {
					t.Fatal("policy damaged response for SDK")
				}
			}
		})
	}
}
