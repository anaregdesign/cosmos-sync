package integration

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
)

type restartMutationStore struct {
	*syncbff.MemoryStore
	mu      sync.Mutex
	scope   string
	input   syncbff.Mutation
	hash    string
	result  syncbff.Document
	success int
}

func (store *restartMutationStore) Mutate(ctx context.Context, scope string, mutation syncbff.Mutation, hash, session string) (syncbff.Document, string, error) {
	document, next, err := store.MemoryStore.Mutate(ctx, scope, mutation, hash, session)
	if err == nil {
		store.mu.Lock()
		store.scope, store.input, store.hash, store.result = scope, mutation, hash, document
		store.success++
		store.mu.Unlock()
	}
	return document, next, err
}

func TestDartRestartFixture(t *testing.T) {
	ready, stop := os.Getenv("COSMOS_SYNC_E2E_READY_FILE"), os.Getenv("COSMOS_SYNC_E2E_STOP_FILE")
	expected := os.Getenv("COSMOS_SYNC_RESTART_EXPECTATION_FILE")
	if ready == "" || stop == "" || expected == "" {
		t.Skip("explicit disposable Flutter OS restart fixture not requested")
	}
	api := newTestAPI(t, nil, func(config *syncbff.Config) {
		config.Snapshots = syncbff.SnapshotOptions{Enabled: true}
		for index := range config.Grants {
			config.Grants[index].ScopeMode = "user"
		}
	})
	store := &restartMutationStore{MemoryStore: syncbff.NewMemoryStore()}
	handler, err := syncbff.NewServer(api.config, store, api.issuer.verifier(t))
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	input, err := json.Marshal(map[string]string{"url": server.URL, "token": api.issuer.token(t, nil)})
	if err != nil || os.WriteFile(ready, input, 0600) != nil {
		t.Fatal("cannot write private restart fixture readiness")
	}
	t.Cleanup(func() { _ = os.Remove(ready) })
	deadline := time.NewTimer(180 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	waiting := true
	for waiting {
		select {
		case <-deadline.C:
			t.Fatal("restart fixture timed out")
		case <-ticker.C:
			if _, err := os.Stat(stop); err == nil {
				waiting = false
			} else if !os.IsNotExist(err) {
				t.Fatal("restart fixture stop signal rejected")
			}
		}
	}
	var expectation struct {
		OperationID string `json:"operationId"`
		ScopeID     string `json:"scopeId"`
	}
	data, err := os.ReadFile(expected)
	if err != nil || json.Unmarshal(data, &expectation) != nil || expectation.OperationID == "" || expectation.ScopeID == "" {
		t.Fatal("missing durable pre-termination operation expectation")
	}
	store.mu.Lock()
	defer store.mu.Unlock()
	if store.success != 1 || store.scope != expectation.ScopeID || store.input.OperationID != expectation.OperationID ||
		store.input.DocumentID != "restart-note" || store.input.BaseVersion != 0 || store.result.Version != 1 {
		t.Fatal("the pre-termination operation did not receive exactly one matching server ACK")
	}
	replayed, _, err := store.MemoryStore.Mutate(context.Background(), store.scope, store.input, store.hash, "")
	page, _, syncErr := store.MemoryStore.Sync(context.Background(), store.scope, 0, 10, "")
	if err != nil || syncErr != nil || replayed.Version != store.result.Version ||
		page.Sequence != 1 || len(page.Changes) != 1 || page.Changes[0].ID != "restart-note" {
		t.Fatal("exact operation replay was not deduplicated in the fixture store")
	}
	t.Log("COSMOS_SYNC_RESTART_BACKEND_PASS exactOperation=true singleVersion=true replayDeduplicated=true")
}
