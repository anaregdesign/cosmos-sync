package syncbff

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestCosmosAuthorizationFenceIsAtomicAndDeniesAfterRevocation(t *testing.T) {
	owner := namespacedID("test-owner")
	member := namespacedID("test-member")
	scopeID := namespacedID("test-shared")
	policy := newAuthorizationPolicy(scopeID, owner, "shared")
	policy.Revision = 2
	policy.Members[member] = ScopeMember{AccountID: member, Role: "writer", PermissionVersion: "2"}
	m := Mutation{OperationID: "11111111-1111-4111-8111-111111111111", DocumentID: "note", Kind: "put", Data: json.RawMessage(`{"title":"queued"}`), PrincipalID: member, AuthorizationVersion: "2"}
	hash, err := validateMutation(&m, scopeID)
	if err != nil {
		t.Fatal(err)
	}
	batchCount, policyReads := 0, 0
	store := testCosmos(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "" || request.URL.Path == "/" {
			return cosmosResponse(request, 200, `{"readableLocations":[{"name":"Test","databaseAccountEndpoint":"https://cosmos.test"}],"writableLocations":[{"name":"Test","databaseAccountEndpoint":"https://cosmos.test"}],"enableMultipleWriteLocations":false,"userConsistencyPolicy":{"defaultConsistencyLevel":"Session"}}`, ""), nil
		}
		if strings.HasSuffix(request.URL.Path, "/docs/"+authorizationPolicyItemID) {
			policyReads++
			body, _ := encodeJSON(storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: policy})
			return cosmosResponse(request, 200, string(body), "policy-session"), nil
		}
		if request.Method == "GET" {
			return cosmosResponse(request, 404, `{"code":"NotFound","message":"missing"}`, "data-session"), nil
		}
		batchCount++
		body, _ := io.ReadAll(request.Body)
		var operations []struct {
			Operation string     `json:"operationType"`
			ID        string     `json:"id"`
			IfMatch   string     `json:"ifMatch"`
			Item      storedItem `json:"resourceBody"`
		}
		if json.Unmarshal(body, &operations) != nil || len(operations) != 5 {
			t.Fatalf("builtin data commit needs five operations: %s", body)
		}
		fence := operations[4]
		if fence.Operation != "Replace" || fence.ID != authorizationPolicyItemID || fence.IfMatch != `"etag"` || !validAuthorizationPolicy(fence.Item.Policy, scopeID) || fence.Item.Policy.Members[member].Role != "writer" {
			t.Fatalf("policy ETag assertion missing from atomic batch: %+v", fence)
		}
		// Another replica's revoke committed after our reads, before this batch.
		policy.Revision = 3
		policy.Members[member] = ScopeMember{AccountID: member, Role: "none", PermissionVersion: "3"}
		return cosmosResponse(request, 200, `[{"statusCode":424},{"statusCode":424},{"statusCode":424},{"statusCode":424},{"statusCode":412}]`, "revoked-session"), nil
	})
	_, _, err = store.Mutate(context.Background(), scopeID, m, hash, "")
	if e, ok := err.(*ProtocolError); !ok || e.Status != 403 || batchCount != 1 || policyReads != 3 {
		t.Fatalf("stale writer was not denied after fence retry: batches=%d reads=%d err=%v", batchCount, policyReads, err)
	}
}

func TestCosmosRevocationRejectsExistingMutationReceiptBeforeReadingIt(t *testing.T) {
	owner, member, scopeID := namespacedID("owner"), namespacedID("member"), namespacedID("scope")
	policy := newAuthorizationPolicy(scopeID, owner, "shared")
	policy.Revision = 3
	policy.Members[member] = ScopeMember{AccountID: member, Role: "none", PermissionVersion: "3"}
	store := testCosmos(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "" || request.URL.Path == "/" {
			return cosmosResponse(request, 200, `{"readableLocations":[{"name":"Test","databaseAccountEndpoint":"https://cosmos.test"}],"writableLocations":[{"name":"Test","databaseAccountEndpoint":"https://cosmos.test"}],"enableMultipleWriteLocations":false,"userConsistencyPolicy":{"defaultConsistencyLevel":"Session"}}`, ""), nil
		}
		if !strings.HasSuffix(request.URL.Path, "/docs/"+authorizationPolicyItemID) {
			t.Fatal("revoked actor reached receipt, document or commit")
		}
		body, _ := encodeJSON(storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: policy})
		return cosmosResponse(request, 200, string(body), ""), nil
	})
	m := Mutation{OperationID: "11111111-1111-4111-8111-111111111111", DocumentID: "note", Kind: "put", Data: json.RawMessage(`{}`), PrincipalID: member, AuthorizationVersion: "2"}
	_, _, err := store.Mutate(context.Background(), scopeID, m, "previous-receipt-hash", "")
	if e, ok := err.(*ProtocolError); !ok || e.Status != 403 {
		t.Fatalf("revoked receipt replay accepted: %v", err)
	}
}

func TestAuthorizationPolicyMemberGenerationsAndStorageBounds(t *testing.T) {
	owner, member := namespacedID("owner"), namespacedID("member")
	policy := newAuthorizationPolicy(namespacedID("scope"), owner, "shared")
	change := MembershipChange{OperationID: "11111111-1111-4111-8111-111111111111", AccountID: member, Role: "writer", BaseRevision: 1}
	updated, audit, err := applyMembership(policy, owner, change)
	if err != nil || updated.Revision != 2 || audit.PreviousRole != "none" || audit.ActorAccountID != owner || policy.Revision != 1 || len(policy.Members) != 0 {
		t.Fatal("membership mutation did not preserve detached policy/audit")
	}
	if scope, _ := updated.scope(owner); scope.PermissionVersion != "1" || !scope.CanWrite {
		t.Fatal("membership edit invalidated immutable owner")
	}
	for number := 0; number < maxAuthorizationMembers; number++ {
		id := namespacedID("bounded", string(rune(number)))
		updated.Members[id] = ScopeMember{AccountID: id, Role: "none", PermissionVersion: "2"}
	}
	delete(updated.Members, member)
	change.BaseRevision = updated.Revision
	if _, _, err := applyMembership(updated, owner, change); err == nil {
		t.Fatal("removed-member tombstones were excluded from metadata cap")
	}
	updated.Members = map[string]ScopeMember{}
	updated.Revision = maxAuthorizationRevision
	change.BaseRevision = maxAuthorizationRevision
	if _, _, err := applyMembership(updated, owner, change); err == nil {
		t.Fatal("unbounded audit/receipt growth accepted")
	}
	updated.Revision = 2
	updated.Members[member] = ScopeMember{AccountID: member, Role: "writer", PermissionVersion: "01"}
	if validAuthorizationPolicy(updated, updated.ScopeID) {
		t.Fatal("malformed permission generation accepted")
	}
}

func TestAuthorizationCapacityReservesEnoughRevisionsToRevokeEveryMember(t *testing.T) {
	owner := namespacedID("owner")
	policy := newAuthorizationPolicy(namespacedID("full-scope"), owner, "shared")
	policy.Revision = authorizationGrantRevisionLimit
	ids := make([]string, 0, maxAuthorizationMembers)
	for index := 0; index < maxAuthorizationMembers; index++ {
		id := namespacedID("reserved-member", string(rune(index)))
		ids = append(ids, id)
		policy.Members[id] = ScopeMember{AccountID: id, Role: "writer", PermissionVersion: "2"}
	}
	if !validAuthorizationPolicy(policy, policy.ScopeID) {
		t.Fatal("full active policy should fit reserved reduction budget")
	}
	for _, id := range ids {
		change := MembershipChange{OperationID: "11111111-1111-4111-8111-111111111111", AccountID: id, Role: "writer", BaseRevision: policy.Revision}
		if _, _, err := applyMembership(policy, owner, change); err == nil {
			t.Fatal("same-role edit consumed reserved revocation budget")
		}
		for _, role := range []string{"reader", "none"} {
			change.Role, change.BaseRevision = role, policy.Revision
			updated, _, err := applyMembership(policy, owner, change)
			if err != nil || !validAuthorizationPolicy(updated, updated.ScopeID) {
				t.Fatalf("capacity prevented rights reduction at revision%d: %v", policy.Revision, err)
			}
			policy = updated
		}
	}
	if policy.Revision != maxAuthorizationRevision {
		t.Fatal("reduction reserve was not exactly bounded")
	}
	for _, member := range policy.Members {
		if member.Role != "none" {
			t.Fatal("active member survived maximum revision")
		}
	}
	change := MembershipChange{OperationID: "11111111-1111-4111-8111-111111111111", AccountID: ids[0], Role: "writer", BaseRevision: policy.Revision}
	if _, _, err := applyMembership(policy, owner, change); err == nil {
		t.Fatal("reactivation at full capacity accepted")
	}
	policy.Members[ids[0]] = ScopeMember{AccountID: ids[0], Role: "reader", PermissionVersion: "2"}
	if validAuthorizationPolicy(policy, policy.ScopeID) {
		t.Fatal("corrupt active member at full capacity did not fail closed")
	}
}
