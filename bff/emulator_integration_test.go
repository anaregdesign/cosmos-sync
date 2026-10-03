package syncbff

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"
	"github.com/coreos/go-oidc/v3/oidc"
)

// This is the public, well-known emulator key, never an Azure account credential.
// The test factory refuses non-loopback hosts and is absent from production builds.
const localEmulatorKey = "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw=="

// vNext EN20260907 advertises Eventual consistency. Observe only that level;
// never weaken the production Session-or-stronger account guard for this emulator.
type emulatorMetadataObserver struct{ t *testing.T }

func (p emulatorMetadataObserver) Do(request *policy.Request) (*http.Response, error) {
	response, err := request.Next()
	if err != nil || response == nil || (request.Raw().URL.Path != "/" && request.Raw().URL.Path != "") {
		return response, err
	}
	body, err := io.ReadAll(response.Body)
	_ = response.Body.Close()
	if err != nil {
		return nil, err
	}
	response.Body = io.NopCloser(bytes.NewReader(body))
	var properties struct {
		Consistency struct {
			Level string `json:"defaultConsistencyLevel"`
		} `json:"userConsistencyPolicy"`
	}
	if err := json.Unmarshal(body, &properties); err != nil {
		return nil, err
	}
	p.t.Logf("emulator advertised account consistency: %q (not production consistency evidence)", properties.Consistency.Level)
	return response, nil
}

type emulatorSessionProbe struct {
	token    string
	observed *atomic.Bool
}

func (p emulatorSessionProbe) Do(request *policy.Request) (*http.Response, error) {
	if strings.HasSuffix(request.Raw().URL.Path, "/docs/head") && request.Raw().Header.Get("x-ms-session-token") == p.token {
		p.observed.Store(true)
	}
	return request.Next()
}

func emulatorClient(t *testing.T, endpoint string, extra ...policy.Policy) *azcosmos.Client {
	t.Helper()
	u, err := url.Parse(endpoint)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		t.Fatal("integration endpoint must be a loopback emulator URL")
	}
	ip := net.ParseIP(u.Hostname())
	if u.Hostname() != "localhost" && (ip == nil || !ip.IsLoopback()) {
		t.Fatal("integration tests refuse to create databases outside a local emulator")
	}
	key, err := azcosmos.NewKeyCredential(localEmulatorKey)
	if err != nil {
		t.Fatal(err)
	}
	policies := append([]policy.Policy{batchWirePolicy{}, emulatorMetadataObserver{t}}, extra...)
	client, err := azcosmos.NewClientWithKey(endpoint, key, &azcosmos.ClientOptions{ClientOptions: azcore.ClientOptions{
		Retry:           policy.RetryOptions{MaxRetries: -1},
		PerCallPolicies: policies,
	}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(client.Close)
	return client
}

func TestCosmosEmulatorIntegration(t *testing.T) {
	endpoint := os.Getenv("COSMOS_SYNC_EMULATOR_ENDPOINT")
	if endpoint == "" {
		t.Skip("set COSMOS_SYNC_EMULATOR_ENDPOINT to opt in to real local emulator tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	client := emulatorClient(t, endpoint)
	databaseID := fmt.Sprintf("cosmos-sync-integration-%d", time.Now().UnixNano())
	if _, err := client.CreateDatabase(ctx, azcosmos.DatabaseProperties{ID: databaseID}, nil); err != nil {
		t.Fatalf("create isolated emulator database: %v", err)
	}
	database, err := client.NewDatabase(databaseID)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cleanupCancel()
		if _, err := database.Delete(cleanupCtx, nil); err != nil {
			t.Errorf("cleanup isolated emulator database: %v", err)
		}
	})
	if _, err := database.CreateContainer(ctx, azcosmos.ContainerProperties{ID: "sync", PartitionKeyDefinition: azcosmos.PartitionKeyDefinition{Paths: []string{"/scopeId"}}}, nil); err != nil {
		t.Fatalf("create isolated /scopeId container: %v", err)
	}
	newStore := func() *CosmosStore {
		fresh := emulatorClient(t, endpoint)
		container, err := fresh.NewContainer(databaseID, "sync")
		if err != nil {
			t.Fatal(err)
		}
		return &CosmosStore{container: container, client: fresh}
	}
	writer, reader := newStore(), newStore()
	mutate := func(t *testing.T, store *CosmosStore, scope string, mutation Mutation, session string) (Document, string) {
		t.Helper()
		hash, err := validateMutation(&mutation, scope)
		if err != nil {
			t.Fatal(err)
		}
		document, session, err := store.Mutate(ctx, scope, mutation, hash, session)
		if err != nil {
			t.Fatalf("mutate %s/%s: %v", scope, mutation.DocumentID, err)
		}
		return document, session
	}
	operation := func(n int, id, kind string, base int64, data string) Mutation {
		return Mutation{OperationID: fmt.Sprintf("00000000-0000-4000-8000-%012d", n), DocumentID: id, Kind: kind, BaseVersion: base, Data: json.RawMessage(data)}
	}
	assertCode := func(t *testing.T, err error, code string) {
		t.Helper()
		var protocol *ProtocolError
		if !errors.As(err, &protocol) || protocol.Code != code {
			t.Fatalf("want protocol error %s, got %v", code, err)
		}
	}

	t.Run("production guard rejects Eventual emulator metadata", func(t *testing.T) {
		guarded := emulatorClient(t, endpoint, accountGuard{})
		container, err := guarded.NewContainer(databaseID, "sync")
		if err != nil {
			t.Fatal(err)
		}
		_, err = container.Read(ctx, nil)
		if err == nil || !strings.Contains(err.Error(), "requires Session or stronger account consistency") {
			t.Fatalf("production consistency guard must reject pinned Eventual emulator metadata: %v", err)
		}
	})

	t.Run("atomic receipt replay and journal", func(t *testing.T) {
		mutation := operation(1, "note", "put", 0, `{"text":"first < & >","n":9007199254740991}`)
		first, session := mutate(t, writer, "replay", mutation, "")
		if session == "" || first.Version != 1 {
			t.Fatalf("missing mutation session token/version: %+v", first)
		}
		t.Logf("actual emulator mutation response session token: %q", session)
		// A new client and a repeated request model a lost BFF ACK and restart.
		replay, replaySession := mutate(t, newStore(), "replay", mutation, session)
		if !equivalentEmulatorDocument(replay, first) || replaySession == "" {
			t.Fatalf("replay changed accepted mutation: %+v", replay)
		}
		mismatch := mutation
		mismatch.Data = json.RawMessage(`{"text":"different"}`)
		hash, _ := validateMutation(&mismatch, "replay")
		_, _, err := reader.Mutate(ctx, "replay", mismatch, hash, replaySession)
		assertCode(t, err, "idempotency_mismatch")
		page, _, err := reader.Sync(ctx, "replay", 0, 10, replaySession)
		if err != nil || page.Sequence != 1 || page.HasMore || len(page.Changes) != 1 || !equivalentEmulatorDocument(page.Changes[0], first) {
			t.Fatalf("replay must leave exactly one journal entry: %+v, %v", page, err)
		}
		for _, id := range []string{"head", "d:note", "c:0000000000000001", "r:" + mutation.OperationID} {
			item, _, _, err := reader.read(ctx, "replay", id, replaySession)
			if err != nil || item == nil {
				t.Fatalf("missing atomic item %s: %v", id, err)
			}
		}
		// A fresh SDK client has no internal session cache. Confirm that the token
		// transferred by the BFF layer reaches its actual network request.
		observed := &atomic.Bool{}
		freshClient := emulatorClient(t, endpoint, emulatorSessionProbe{replaySession, observed})
		freshContainer, err := freshClient.NewContainer(databaseID, "sync")
		if err != nil {
			t.Fatal(err)
		}
		freshStore := &CosmosStore{container: freshContainer, client: freshClient}
		page, _, err = freshStore.Sync(ctx, "replay", 0, 10, replaySession)
		if err != nil || page.Sequence != 1 || !observed.Load() {
			t.Fatalf("session token was not propagated across fresh SDK clients: %v", err)
		}
		t.Log("captured session token reached the fresh SDK client's actual head read request")
	})

	t.Run("failed ETag batch rolls back every operation", func(t *testing.T) {
		_, session := mutate(t, writer, "rollback", operation(2, "note", "put", 0, `{"n":1}`), "")
		old, staleETag, session, err := reader.read(ctx, "rollback", "head", session)
		if err != nil || old == nil {
			t.Fatal("read ETag head", err)
		}
		_, session = mutate(t, writer, "rollback", operation(3, "note", "put", 1, `{"n":2}`), session)
		old.Sequence = 999
		body, _ := encodeJSON(old)
		batch := reader.container.NewTransactionalBatch(azcosmos.NewPartitionKeyString("rollback"))
		batch.CreateItem([]byte(`{"id":"rollback-sentinel","scopeId":"rollback","kind":"probe"}`), nil)
		batch.ReplaceItem("head", body, &azcosmos.TransactionalBatchItemOptions{IfMatchETag: &staleETag})
		response, err := reader.container.ExecuteTransactionalBatch(ctx, batch, &azcosmos.TransactionalBatchOptions{SessionToken: session})
		if err != nil {
			var service *azcore.ResponseError
			if !errors.As(err, &service) || service.StatusCode != http.StatusPreconditionFailed {
				t.Fatal("failed ETag batch", err)
			}
		} else {
			found := false
			for _, result := range response.OperationResults {
				found = found || result.StatusCode == http.StatusPreconditionFailed
			}
			if response.Success || !found {
				t.Fatalf("stale ETag batch unexpectedly accepted: success=%v", response.Success)
			}
		}
		sentinel, _, session, err := reader.read(ctx, "rollback", "rollback-sentinel", session)
		if err != nil || sentinel != nil {
			t.Fatalf("failed batch left a partial write: %v", err)
		}
		head, _, _, err := reader.read(ctx, "rollback", "head", session)
		if err != nil || head == nil || head.Sequence != 2 {
			t.Fatalf("failed batch changed head: %+v, %v", head, err)
		}
	})

	t.Run("bootstrap pagination concurrent writes tombstone and scope isolation", func(t *testing.T) {
		_, session := mutate(t, writer, "pages", operation(10, "note", "put", 0, `{"n":1}`), "")
		_, session = mutate(t, writer, "pages", operation(11, "note", "delete", 1, ""), session)
		firstPage, session, err := reader.Sync(ctx, "pages", 0, 1, session)
		if err != nil || !firstPage.HasMore || firstPage.Sequence != 1 || len(firstPage.Changes) != 1 {
			t.Fatalf("initial page: %+v, %v", firstPage, err)
		}
		_, session = mutate(t, writer, "pages", operation(12, "note", "put", 2, `{"n":3}`), session)
		secondPage, session, err := newStore().Sync(ctx, "pages", firstPage.Sequence, 1, session)
		if err != nil || !secondPage.HasMore || secondPage.Sequence != 2 || len(secondPage.Changes) != 1 || !secondPage.Changes[0].Deleted {
			t.Fatalf("tombstone incremental page: %+v, %v", secondPage, err)
		}
		thirdPage, session, err := newStore().Sync(ctx, "pages", secondPage.Sequence, 1, session)
		if err != nil || thirdPage.HasMore || thirdPage.Sequence != 3 || len(thirdPage.Changes) != 1 || thirdPage.Changes[0].Deleted {
			t.Fatalf("recreated page: %+v, %v", thirdPage, err)
		}
		emptyPage, _, err := newStore().Sync(ctx, "pages", thirdPage.Sequence, 1, session)
		if err != nil || len(emptyPage.Changes) != 0 || emptyPage.Sequence != 3 {
			t.Fatalf("resume after final cursor: %+v, %v", emptyPage, err)
		}
		other, _, err := newStore().Sync(ctx, "other-scope", 0, 10, "")
		if err != nil || len(other.Changes) != 0 || other.Sequence != 0 {
			t.Fatalf("scope leaked: %+v, %v", other, err)
		}
		stale := operation(13, "note", "put", 1, `{"n":4}`)
		hash, _ := validateMutation(&stale, "pages")
		_, _, err = reader.Mutate(ctx, "pages", stale, hash, session)
		assertCode(t, err, "conflict")
	})

	t.Run("concurrent fresh replicas serialize a partition", func(t *testing.T) {
		const count = 8
		var wg sync.WaitGroup
		errors := make(chan error, count)
		for i := 0; i < count; i++ {
			store := newStore()
			mutation := operation(100+i, fmt.Sprintf("note-%d", i), "put", 0, `{"ok":true}`)
			hash, err := validateMutation(&mutation, "concurrent")
			if err != nil {
				t.Fatal(err)
			}
			wg.Add(1)
			go func() {
				defer wg.Done()
				_, _, err := store.Mutate(ctx, "concurrent", mutation, hash, "")
				errors <- err
			}()
		}
		wg.Wait()
		close(errors)
		for err := range errors {
			if err != nil {
				t.Fatal("concurrent mutation", err)
			}
		}
		page, _, err := newStore().Sync(ctx, "concurrent", 0, count, "")
		if err != nil || len(page.Changes) != count || page.Sequence != count || page.HasMore {
			t.Fatalf("non-contiguous concurrent journal: %+v, %v", page, err)
		}
	})

	t.Run("TLS JWT BFF replicas use real Cosmos storage", func(t *testing.T) {
		key, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			t.Fatal(err)
		}
		var issuer *httptest.Server
		issuer = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			switch r.URL.Path {
			case "/.well-known/openid-configuration":
				_ = json.NewEncoder(w).Encode(map[string]any{"issuer": issuer.URL, "jwks_uri": issuer.URL + "/jwks", "authorization_endpoint": issuer.URL + "/authorize", "token_endpoint": issuer.URL + "/token", "id_token_signing_alg_values_supported": []string{"RS256"}})
			case "/jwks":
				_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]any{"kty": "RSA", "kid": "emulator-test-key", "alg": "RS256", "use": "sig", "n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()), "e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes())}}})
			default:
				http.NotFound(w, r)
			}
		}))
		defer issuer.Close()
		config := Config{Storage: "Cosmos", CursorKeyBase64: base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{42}, 32)), OIDC: OIDCConfig{Issuer: issuer.URL, Audience: "cosmos-sync-emulator-tests", TenantClaim: "tid", RequiredScope: "cosmos_sync"}, Grants: []Grant{
			{Tenant: "emulator-tenant", Subject: "alice", ScopeMode: "tenant", PermissionVersion: "v1", Active: true, CanRead: true, CanWrite: true},
			{Tenant: "emulator-tenant", Subject: "bob", ScopeMode: "tenant", PermissionVersion: "v1", Active: true, CanRead: true, CanWrite: true},
		}}
		verifier, err := NewOIDCVerifier(oidc.ClientContext(ctx, issuer.Client()), config.OIDC)
		if err != nil {
			t.Fatal(err)
		}
		newReplica := func() *httptest.Server {
			handler, err := NewServer(config, newStore(), verifier)
			if err != nil {
				t.Fatal(err)
			}
			replica := httptest.NewTLSServer(handler)
			t.Cleanup(replica.Close)
			return replica
		}
		firstReplica, secondReplica := newReplica(), newReplica()
		alice := signEmulatorJWT(t, key, issuer.URL, "alice")
		bob := signEmulatorJWT(t, key, issuer.URL, "bob")
		call := func(replica *httptest.Server, token, method, path string, binding Scope, session string, body any, expected int) ([]byte, string) {
			t.Helper()
			var raw []byte
			if body != nil {
				raw, err = json.Marshal(body)
				if err != nil {
					t.Fatal(err)
				}
			}
			request, err := http.NewRequestWithContext(ctx, method, replica.URL+path, bytes.NewReader(raw))
			if err != nil {
				t.Fatal(err)
			}
			request.Header.Set("Authorization", "Bearer "+token)
			request.Header.Set("Content-Type", "application/json")
			request.Header.Set(ScopeHeader, binding.ID)
			request.Header.Set(PermissionHeader, binding.PermissionVersion)
			request.Header.Set(PrincipalHeader, binding.PrincipalID)
			request.Header.Set(ScopeModeHeader, binding.ScopeMode)
			request.Header.Set(SessionHeader, session)
			response, err := replica.Client().Do(request)
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			value, err := io.ReadAll(response.Body)
			if err != nil {
				t.Fatal(err)
			}
			if response.StatusCode != expected {
				t.Fatalf("HTTP %s expected %d got %d: %s", path, expected, response.StatusCode, value)
			}
			return value, response.Header.Get(SessionHeader)
		}
		sessionFor := func(token string) Scope {
			raw, _ := call(firstReplica, token, "GET", "/v1/session?scope=tenant", Scope{}, "", nil, 200)
			var binding Scope
			if err := json.Unmarshal(raw, &binding); err != nil {
				t.Fatal(err)
			}
			return binding
		}
		aliceScope, bobScope := sessionFor(alice), sessionFor(bob)
		if aliceScope.ID != bobScope.ID || aliceScope.PrincipalID == bobScope.PrincipalID {
			t.Fatal("shared scope must keep separate actor identity")
		}
		firstMutation := operation(200, "alice-note", "put", 0, `{"from":"alice"}`)
		raw, signedSession := call(firstReplica, alice, "POST", "/v1/mutations", aliceScope, "", firstMutation, 200)
		var ack struct {
			Document Document `json:"document"`
		}
		if err := json.Unmarshal(raw, &ack); err != nil || ack.Document.Version != 1 || signedSession == "" {
			t.Fatalf("real Cosmos BFF ACK/session invalid: %v", err)
		}
		// Same operationId by a different authenticated actor must not reuse Alice's receipt.
		call(secondReplica, bob, "POST", "/v1/mutations", bobScope, "", operation(200, "bob-note", "put", 0, `{"from":"bob"}`), 200)
		replayed, _ := call(secondReplica, alice, "POST", "/v1/mutations", aliceScope, signedSession, firstMutation, 200)
		var replay struct {
			Document Document `json:"document"`
		}
		if err := json.Unmarshal(replayed, &replay); err != nil || !equivalentEmulatorDocument(replay.Document, ack.Document) {
			t.Fatal("cross-BFF exact replay failed", err)
		}
		pageRaw, _ := call(secondReplica, alice, "GET", "/v1/sync?limit=10", aliceScope, signedSession, nil, 200)
		var page struct {
			Changes []Document `json:"changes"`
			Cursor  string     `json:"cursor"`
		}
		if err := json.Unmarshal(pageRaw, &page); err != nil || len(page.Changes) != 2 || page.Cursor == "" {
			t.Fatalf("BFF replica bootstrap missing real changes: %v", err)
		}
		call(secondReplica, alice, "GET", "/v1/sync", bobScope, "", nil, 403)
		call(secondReplica, "invalid.jwt.signature", "GET", "/v1/session?scope=tenant", Scope{}, "", nil, 401)
		// Cursor generated by one BFF is authenticated and resumed by another.
		resume, _ := call(firstReplica, alice, "GET", "/v1/sync?cursor="+url.QueryEscape(page.Cursor), aliceScope, signedSession, nil, 200)
		var empty struct {
			Changes []Document `json:"changes"`
		}
		if err := json.Unmarshal(resume, &empty); err != nil || len(empty.Changes) != 0 {
			t.Fatal("cross-BFF cursor resume failed", err)
		}
	})
}

func signEmulatorJWT(t *testing.T, key *rsa.PrivateKey, issuer, subject string) string {
	t.Helper()
	encode := func(value any) string {
		raw, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		return base64.RawURLEncoding.EncodeToString(raw)
	}
	now := time.Now()
	unsigned := encode(map[string]string{"alg": "RS256", "typ": "at+jwt", "kid": "emulator-test-key"}) + "." + encode(map[string]any{"iss": issuer, "aud": "cosmos-sync-emulator-tests", "sub": subject, "tid": "emulator-tenant", "scp": "cosmos_sync", "iat": now.Add(-time.Minute).Unix(), "nbf": now.Add(-time.Minute).Unix(), "exp": now.Add(time.Hour).Unix()})
	digest := sha256.Sum256([]byte(unsigned))
	signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return unsigned + "." + base64.RawURLEncoding.EncodeToString(signature)
}

// Cosmos service/emulator response formatting is not a document-data contract.
func equivalentEmulatorDocument(a, b Document) bool {
	if a.ID != b.ID || a.Version != b.Version || a.Deleted != b.Deleted {
		return false
	}
	decode := func(raw json.RawMessage) (any, error) {
		if len(raw) == 0 {
			return nil, nil
		}
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.UseNumber()
		var value any
		err := decoder.Decode(&value)
		return value, err
	}
	left, leftErr := decode(a.Data)
	right, rightErr := decode(b.Data)
	return leftErr == nil && rightErr == nil && reflect.DeepEqual(left, right)
}
