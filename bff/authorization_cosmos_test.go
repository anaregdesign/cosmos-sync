package syncbff

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

const authorizationTestAccountMetadata = `{"readableLocations":[{"name":"Test","databaseAccountEndpoint":"https://cosmos.test"}],"writableLocations":[{"name":"Test","databaseAccountEndpoint":"https://cosmos.test"}],"enableMultipleWriteLocations":false,"userConsistencyPolicy":{"defaultConsistencyLevel":"Session"}}`

func authorizationItemResponse(t *testing.T, r *http.Request, item *storedItem, token string) *http.Response {
	t.Helper()
	if item == nil {
		return cosmosResponse(r, 404, `{"code":"NotFound"}`, token)
	}
	body, err := encodeJSON(item)
	if err != nil {
		t.Fatal(err)
	}
	return cosmosResponse(r, 200, string(body), token)
}

func authorizationTestAccount(identity AccountIdentity) (Account, *storedItem, *storedItem) {
	account := identityAccount(identity)
	return account,
		&storedItem{ID: authorizationAccountItemID, ScopeID: account.PersonalScopeID, Kind: "account", Account: &accountRecord{Account: account, Identity: identity}},
		&storedItem{ID: authorizationPolicyItemID, ScopeID: account.PersonalScopeID, Kind: "authorization", Policy: newAuthorizationPolicy(account.PersonalScopeID, account.AccountID, "user")}
}

func requireAuthorizationCode(t *testing.T, err error, code string) {
	t.Helper()
	var protocol *ProtocolError
	if !errors.As(err, &protocol) || protocol.Code != code {
		t.Fatalf("want %s, got %v", code, err)
	}
}

func TestCosmosBuiltinRegistrationReadsAcknowledgedAtomicPolicy(t *testing.T) {
	identity := AccountIdentity{Issuer: "https://issuer.test", Subject: "owner"}
	account, record, policy := authorizationTestAccount(identity)
	committed, postReads := false, 0
	store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/" || r.URL.Path == "" {
			return cosmosResponse(r, 200, authorizationTestAccountMetadata, ""), nil
		}
		if r.Method == http.MethodGet {
			if !committed {
				return authorizationItemResponse(t, r, nil, "pre-create"), nil
			}
			postReads++
			if r.Header.Get("x-ms-session-token") != "create-ack" || r.Header.Get("x-ms-documentdb-partitionkey") != `["`+account.PersonalScopeID+`"]` {
				t.Fatal("account/policy read did not observe its own atomic create session")
			}
			if strings.HasSuffix(r.URL.Path, "/docs/"+authorizationAccountItemID) {
				return authorizationItemResponse(t, r, record, "create-ack"), nil
			}
			return authorizationItemResponse(t, r, policy, "create-ack"), nil
		}
		if r.Header.Get("x-ms-session-token") != "pre-create" {
			t.Fatal("atomic create did not propagate preflight read session")
		}
		body, _ := io.ReadAll(r.Body)
		var operations []struct {
			Operation string     `json:"operationType"`
			Item      storedItem `json:"resourceBody"`
		}
		if json.Unmarshal(body, &operations) != nil || len(operations) != 2 || operations[0].Operation != "Create" || operations[1].Operation != "Create" || operations[0].Item.Kind != "account" || operations[1].Item.Kind != "authorization" {
			t.Fatal("account registration must atomically create account and policy")
		}
		committed = true
		return cosmosResponse(r, 200, `[{"statusCode":201},{"statusCode":201}]`, "create-ack"), nil
	})
	ctx := withAuthorizationSessions(context.Background())
	got, err := store.EnsureAccount(ctx, identity)
	if err != nil || got != account || postReads != 2 {
		t.Fatalf("registration did not prove complete metadata: %+v reads=%d err=%v", got, postReads, err)
	}
	if _, err := store.LoadAuthorizationPolicy(ctx, account.PersonalScopeID); err != nil || postReads != 3 {
		t.Fatalf("same-request authorization lost acknowledged session: %v", err)
	}
}

func TestCosmosBuiltinAccountMetadataFailsClosed(t *testing.T) {
	identity := AccountIdentity{Issuer: "https://issuer.test", Subject: "owner"}
	for _, name := range []string{"missing-policy", "missing-account", "wrong-owner", "empty-identity", "wrong-account-scope", "empty-policy-etag"} {
		t.Run(name, func(t *testing.T) {
			account, record, policy := authorizationTestAccount(identity)
			switch name {
			case "missing-policy":
				policy = nil
			case "missing-account":
				record = nil
			case "wrong-owner":
				policy.Policy.OwnerAccountID = namespacedID("wrong-owner")
			case "empty-identity":
				record.Account.Identity.Subject = ""
			case "wrong-account-scope":
				record.ScopeID = namespacedID("wrong-scope")
			}
			store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
				if r.URL.Path == "/" || r.URL.Path == "" {
					return cosmosResponse(r, 200, authorizationTestAccountMetadata, ""), nil
				}
				if r.Method != http.MethodGet {
					t.Fatal("corrupt authorization metadata must never be repaired by an implicit write")
				}
				if strings.HasSuffix(r.URL.Path, "/docs/"+authorizationAccountItemID) {
					return authorizationItemResponse(t, r, record, "read"), nil
				}
				response := authorizationItemResponse(t, r, policy, "read")
				if name == "empty-policy-etag" {
					response.Header.Del("Etag")
				}
				return response, nil
			})
			_, err := store.EnsureAccount(context.Background(), identity)
			requireAuthorizationCode(t, err, "authorization_store_unavailable")
			_ = account
		})
	}
}

func TestCosmosBuiltinAccountConcurrentCreateBetweenReads(t *testing.T) {
	identity := AccountIdentity{Issuer: "https://issuer.test", Subject: "owner"}
	account, record, policy := authorizationTestAccount(identity)
	accountReads := 0
	store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/" || r.URL.Path == "" {
			return cosmosResponse(r, 200, authorizationTestAccountMetadata, ""), nil
		}
		if r.Method != http.MethodGet {
			t.Fatal("already committed registration must not be created again")
		}
		if strings.HasSuffix(r.URL.Path, "/docs/"+authorizationAccountItemID) {
			accountReads++
			if accountReads == 1 {
				return authorizationItemResponse(t, r, nil, "before"), nil
			}
			if r.Header.Get("x-ms-session-token") != "concurrent-ack" {
				t.Fatal("reread did not carry newer policy session")
			}
			return authorizationItemResponse(t, r, record, "concurrent-ack"), nil
		}
		return authorizationItemResponse(t, r, policy, "concurrent-ack"), nil
	})
	got, err := store.EnsureAccount(context.Background(), identity)
	if err != nil || got != account || accountReads != 2 {
		t.Fatalf("concurrent registration: %+v %v", got, err)
	}
}

func TestCosmosMembershipContentionCarriesPartitionSessionAndReplays(t *testing.T) {
	owner, _, _ := authorizationTestAccount(AccountIdentity{Issuer: "https://issuer.test", Subject: "owner"})
	target, targetRecord, targetPolicy := authorizationTestAccount(AccountIdentity{Issuer: "https://issuer.test", Subject: "target"})
	scopeID := sharedScopeID(owner.AccountID, "11111111-1111-4111-8111-111111111111")
	change := MembershipChange{OperationID: "22222222-2222-4222-8222-222222222222", AccountID: target.AccountID, Role: "writer", BaseRevision: 1}
	initial := newAuthorizationPolicy(scopeID, owner.AccountID, "shared")
	updated, _, err := applyMembership(initial, owner.AccountID, change)
	if err != nil {
		t.Fatal(err)
	}
	result := updated.public()
	receiptID := "a:r:" + owner.AccountID + ":" + change.OperationID
	receipt := &storedItem{ID: receiptID, ScopeID: scopeID, Kind: "authorization-receipt", AuthorizationReceipt: &authorizationReceipt{Hash: membershipHash(scopeID, owner.AccountID, change), Result: result}}
	committed, batches := false, 0
	store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/" || r.URL.Path == "" {
			return cosmosResponse(r, 200, authorizationTestAccountMetadata, ""), nil
		}
		if r.Method == http.MethodGet {
			if r.Header.Get("x-ms-documentdb-partitionkey") == `["`+target.PersonalScopeID+`"]` {
				if strings.HasSuffix(r.URL.Path, "/docs/"+authorizationAccountItemID) {
					return authorizationItemResponse(t, r, targetRecord, "target-session"), nil
				}
				return authorizationItemResponse(t, r, targetPolicy, "target-session"), nil
			}
			if strings.HasSuffix(r.URL.Path, "/docs/"+authorizationPolicyItemID) {
				if committed {
					if r.Header.Get("x-ms-session-token") != "concurrent-commit" {
						t.Fatal("409 retry lost acknowledged shared partition token")
					}
					return authorizationItemResponse(t, r, &storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: updated}, "concurrent-commit"), nil
				}
				return authorizationItemResponse(t, r, &storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: initial}, "policy-session"), nil
			}
			if committed {
				return authorizationItemResponse(t, r, receipt, "concurrent-commit"), nil
			}
			return authorizationItemResponse(t, r, nil, "receipt-session"), nil
		}
		batches++
		if r.Header.Get("x-ms-session-token") != "receipt-session" {
			t.Fatal("membership batch mixed target-account token with shared partition token")
		}
		body, _ := io.ReadAll(r.Body)
		var operations []struct {
			Operation string     `json:"operationType"`
			ETag      string     `json:"ifMatch"`
			Item      storedItem `json:"resourceBody"`
		}
		if json.Unmarshal(body, &operations) != nil || len(operations) != 3 || operations[0].Operation != "Replace" || operations[0].ETag == "" || operations[0].Item.Kind != "authorization" || operations[1].Item.Kind != "authorization-audit" || operations[2].Item.Kind != "authorization-receipt" {
			t.Fatalf("membership needs policy CAS/audit/receipt, got %s", body)
		}
		for _, operation := range operations {
			if operation.Item.ScopeID != scopeID {
				t.Fatal("authorization batch crossed partition")
			}
		}
		committed = true
		return cosmosResponse(r, 409, `{"code":"Conflict"}`, "concurrent-commit"), nil
	})
	got, err := store.ChangeMembership(context.Background(), scopeID, owner.AccountID, change)
	if err != nil || !reflect.DeepEqual(got, result) || batches != 1 {
		t.Fatalf("contention exact replay: %+v batches=%d err=%v", got, batches, err)
	}
}

func TestCosmosMembershipReplayCommittedBetweenPolicyAndReceiptReads(t *testing.T) {
	owner := namespacedID("owner")
	target := namespacedID("target")
	scopeID := namespacedID("shared")
	change := MembershipChange{OperationID: "11111111-1111-4111-8111-111111111111", AccountID: target, Role: "reader", BaseRevision: 1}
	initial := newAuthorizationPolicy(scopeID, owner, "shared")
	updated, _, err := applyMembership(initial, owner, change)
	if err != nil {
		t.Fatal(err)
	}
	receiptID := "a:r:" + owner + ":" + change.OperationID
	policyReads := 0
	store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/" || r.URL.Path == "" {
			return cosmosResponse(r, 200, authorizationTestAccountMetadata, ""), nil
		}
		if r.Method != http.MethodGet {
			t.Fatal("exact replay must not issue a second mutation")
		}
		if strings.HasSuffix(r.URL.Path, "/docs/"+authorizationPolicyItemID) {
			policyReads++
			if policyReads == 1 {
				return authorizationItemResponse(t, r, &storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: initial}, "before-replay"), nil
			}
			if r.Header.Get("x-ms-session-token") != "replay-committed" {
				t.Fatal("policy reread lost newer receipt token")
			}
			return authorizationItemResponse(t, r, &storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: updated}, "replay-committed"), nil
		}
		return authorizationItemResponse(t, r, &storedItem{ID: receiptID, ScopeID: scopeID, Kind: "authorization-receipt", AuthorizationReceipt: &authorizationReceipt{Hash: membershipHash(scopeID, owner, change), Result: updated.public()}}, "replay-committed"), nil
	})
	result, err := store.ChangeMembership(context.Background(), scopeID, owner, change)
	if err != nil || policyReads != 2 || !reflect.DeepEqual(result, updated.public()) {
		t.Fatalf("concurrent exact replay: %+v reads=%d err=%v", result, policyReads, err)
	}
}

func TestCosmosSharedCreationReplayRequiresMatchingImmutableAudit(t *testing.T) {
	identity := AccountIdentity{Issuer: "https://issuer.test", Subject: "owner"}
	owner, record, personal := authorizationTestAccount(identity)
	operationID := "11111111-1111-4111-8111-111111111111"
	scopeID := sharedScopeID(owner.AccountID, operationID)
	for _, name := range []string{"valid", "missing", "wrong-operation", "wrong-actor", "wrong-kind", "missing-time", "non-utc-time"} {
		t.Run(name, func(t *testing.T) {
			audit := &storedItem{ID: "a:audit:00001", ScopeID: scopeID, Kind: "authorization-audit", Audit: &authorizationAudit{ActorAccountID: owner.AccountID, AccountID: owner.AccountID, OperationID: operationID, Role: "owner", Revision: 1, OccurredAt: "2026-10-03T10:00:00Z"}}
			switch name {
			case "missing":
				audit = nil
			case "wrong-operation":
				audit.Audit.OperationID = "22222222-2222-4222-8222-222222222222"
			case "wrong-actor":
				audit.Audit.ActorAccountID = namespacedID("other")
			case "wrong-kind":
				audit.Kind = "change"
			case "missing-time":
				audit.Audit.OccurredAt = ""
			case "non-utc-time":
				audit.Audit.OccurredAt = "2026-10-03T10:00:00+01:00"
			}
			store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
				if r.URL.Path == "/" || r.URL.Path == "" {
					return cosmosResponse(r, 200, authorizationTestAccountMetadata, ""), nil
				}
				if r.Method != http.MethodGet {
					t.Fatal("creation replay must not rewrite immutable audit")
				}
				if r.Header.Get("x-ms-documentdb-partitionkey") == `["`+owner.PersonalScopeID+`"]` {
					if strings.HasSuffix(r.URL.Path, "/docs/"+authorizationAccountItemID) {
						return authorizationItemResponse(t, r, record, "personal"), nil
					}
					return authorizationItemResponse(t, r, personal, "personal"), nil
				}
				if strings.HasSuffix(r.URL.Path, "/docs/"+authorizationPolicyItemID) {
					return authorizationItemResponse(t, r, &storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: newAuthorizationPolicy(scopeID, owner.AccountID, "shared")}, "shared"), nil
				}
				return authorizationItemResponse(t, r, audit, "shared"), nil
			})
			got, err := store.CreateSharedScope(context.Background(), owner.AccountID, operationID)
			if name == "valid" {
				if err != nil || got.Revision != 1 {
					t.Fatalf("valid creation replay: %+v %v", got, err)
				}
			} else {
				requireAuthorizationCode(t, err, "authorization_store_unavailable")
			}
		})
	}
}

func TestAuthorizationReceiptCorruptionAndResultBinding(t *testing.T) {
	owner := namespacedID("owner")
	target := namespacedID("target")
	scopeID := namespacedID("shared")
	change := MembershipChange{OperationID: "11111111-1111-4111-8111-111111111111", AccountID: target, Role: "writer", BaseRevision: 1}
	policy := newAuthorizationPolicy(scopeID, owner, "shared")
	updated, _, _ := applyMembership(policy, owner, change)
	for _, name := range []string{"valid", "wrong-id", "wrong-scope", "wrong-owner", "malformed-hash", "future-result", "duplicate-member", "invalid-generation", "nil-members", "wrong-role"} {
		t.Run(name, func(t *testing.T) {
			item := &storedItem{ID: "receipt", ScopeID: scopeID, Kind: "authorization-receipt", AuthorizationReceipt: &authorizationReceipt{Hash: membershipHash(scopeID, owner, change), Result: updated.public()}}
			switch name {
			case "wrong-id":
				item.ID = "other"
			case "wrong-scope":
				item.ScopeID = namespacedID("other")
			case "wrong-owner":
				item.AuthorizationReceipt.Result.OwnerAccountID = target
			case "malformed-hash":
				item.AuthorizationReceipt.Hash = "invalid"
			case "future-result":
				item.AuthorizationReceipt.Result.Revision = 3
			case "duplicate-member":
				item.AuthorizationReceipt.Result.Members = append(item.AuthorizationReceipt.Result.Members, item.AuthorizationReceipt.Result.Members[0])
			case "invalid-generation":
				item.AuthorizationReceipt.Result.Members[0].PermissionVersion = "1"
			case "nil-members":
				item.AuthorizationReceipt.Result.Members = nil
			case "wrong-role":
				item.AuthorizationReceipt.Result.Members[0].Role = "reader"
			}
			valid := validAuthorizationReceipt(item, scopeID, owner, "receipt", 2) && membershipResultMatches(item.AuthorizationReceipt.Result, change)
			if valid != (name == "valid") {
				t.Fatalf("corrupt receipt accepted=%v", valid)
			}
		})
	}
}

func TestAuthorizationSessionsAreRequestAndPartitionBoundAndBounded(t *testing.T) {
	ctx := withAuthorizationSessions(context.Background())
	if err := rememberAuthorizationSession(ctx, "one", "one-token"); err != nil {
		t.Fatal(err)
	}
	if token, _ := authorizationSession(ctx, "one", ""); token != "one-token" {
		t.Fatal("lost scoped token")
	}
	if token, _ := authorizationSession(ctx, "one", "older-client-token"); token != "one-token" {
		t.Fatal("an already observed request token was replaced by an older supplied client token")
	}
	if token, _ := authorizationSession(ctx, "two", ""); token != "" {
		t.Fatal("token crossed partition")
	}
	if token, _ := authorizationSession(withAuthorizationSessions(context.Background()), "one", ""); token != "" {
		t.Fatal("token crossed requests")
	}
	for _, scope := range []string{"two", "three", "four", "five", "six", "seven", "eight"} {
		if err := rememberAuthorizationSession(ctx, scope, scope); err != nil {
			t.Fatal(err)
		}
	}
	_, err := authorizationSession(ctx, "nine", "")
	requireAuthorizationCode(t, err, "authorization_store_unavailable")
	if err := rememberAuthorizationSession(ctx, "nine", "token"); err == nil {
		t.Fatal("unbounded request session storage")
	}
}

func TestCosmosBuiltinCanceledContextDoesNotIssueStorageRequests(t *testing.T) {
	store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
		t.Fatal("canceled authorization must not call Cosmos")
		return nil, nil
	})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := store.EnsureAccount(ctx, AccountIdentity{Issuer: "https://issuer.test", Subject: "owner"})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("want cancellation, got %v", err)
	}
}
