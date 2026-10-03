package syncbff

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestCosmosCapacityChecksReceiptBeforeRefusingNewWrites(t *testing.T) {
	mutation := Mutation{OperationID: "11111111-1111-4111-8111-111111111111", DocumentID: "note", Kind: "put", Data: json.RawMessage(`{"value":1}`)}
	hash, err := validateMutation(&mutation, "scope")
	if err != nil {
		t.Fatal(err)
	}
	document := Document{ID: "note", Data: mutation.Data, Version: 1}
	receipt, _ := encodeJSON(storedItem{ID: "r:" + mutation.OperationID, ScopeID: "scope", Kind: "receipt", RequestHash: hash, Document: &document})
	replay := false
	store := testCosmos(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "" || request.URL.Path == "/" {
			return cosmosResponse(request, 200, `{"enableMultipleWriteLocations":false,"writableLocations":[{"databaseAccountEndpoint":"https://cosmos.test"}],"userConsistencyPolicy":{"defaultConsistencyLevel":"Session"}}`, ""), nil
		}
		if request.Method != http.MethodGet {
			t.Fatal("capacity refusal sent a write batch")
		}
		if strings.HasSuffix(request.URL.Path, "/docs/head") {
			return cosmosResponse(request, 200, `{"id":"head","scopeId":"scope","kind":"head","sequence":1,"estimatedRetainedBytes":5000}`, "head-session"), nil
		}
		if replay && strings.Contains(request.URL.Path, "/docs/r:") {
			return cosmosResponse(request, 200, string(receipt), "receipt-session"), nil
		}
		return cosmosResponse(request, 404, `{"code":"NotFound"}`, "read-session"), nil
	})
	if err := store.ConfigureRetention(RetentionOptions{MaxJournalEvents: 1}); err != nil {
		t.Fatal(err)
	}
	_, _, err = store.Mutate(context.Background(), "scope", mutation, hash, "")
	if failure, ok := err.(*ProtocolError); !ok || failure.Status != 507 || failure.Code != "scope_capacity_exceeded" {
		t.Fatalf("capacity not enforced: %v", err)
	}
	replay = true
	accepted, session, err := store.Mutate(context.Background(), "scope", mutation, hash, "")
	if err != nil || accepted.Version != 1 || session != "receipt-session" {
		t.Fatalf("capacity blocked accepted replay: %+v %q %v", accepted, session, err)
	}
}

func TestRetentionBoundsAndLegacyEstimate(t *testing.T) {
	for _, options := range []RetentionOptions{{MaxJournalEvents: -1}, {MaxJournalEvents: MaxSequence + 1}, {MaxEstimatedRetainedBytes: 4095}, {MaxEstimatedRetainedBytes: 17 * 1024 * 1024 * 1024}} {
		if _, err := normalizeRetention(options); err == nil {
			t.Fatalf("unsafe capacity accepted: %+v", options)
		}
	}
	var controls retentionControls
	if err := controls.configure(RetentionOptions{}); err != nil {
		t.Fatal(err)
	}
	if !controls.allows(0, 0, 4096) || controls.allows(10000, 0, 1) || controls.allows(1, legacyRetainedEstimate(10000), 1) || legacyRetainedEstimate(MaxSequence) <= 16*1024*1024*1024 {
		t.Fatal("retention defaults/legacy accounting allow unbounded storage")
	}
}
