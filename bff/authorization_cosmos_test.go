package syncbff

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/coreos/go-oidc/v3/oidc"
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
	if token, _ := authorizationSession(ctx, "one", "earlier-authorization-token"); token != "one-token" {
		t.Fatal("an already observed authorization response was replaced by an earlier authorization read")
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

func TestCosmosDataClientSessionAndAuthorizationSessionStaySeparate(t *testing.T) {
	ctx := withAuthorizationSessions(context.Background())
	scopeID, owner := namespacedID("session-scope"), namespacedID("session-owner")
	if err := rememberAuthorizationSession(ctx, scopeID, "0:-1#5"); err != nil {
		t.Fatal(err)
	}
	seen := []string{}
	store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/" || r.URL.Path == "" {
			return cosmosResponse(r, 200, authorizationTestAccountMetadata, ""), nil
		}
		seen = append(seen, r.Header.Get("x-ms-session-token"))
		switch {
		case strings.HasSuffix(r.URL.Path, "/docs/head"):
			if seen[len(seen)-1] != "0:-1#10" {
				t.Fatal("earlier authorization LSN5 discarded signed client minimum LSN10")
			}
			return authorizationItemResponse(t, r, &storedItem{ID: "head", ScopeID: scopeID, Kind: "head", Sequence: 1}, "0:-1#11"), nil
		case strings.HasSuffix(r.URL.Path, "/docs/d:note"):
			if seen[len(seen)-1] != "0:-1#11" {
				t.Fatal("data reads lost their own response-token chain")
			}
			return authorizationItemResponse(t, r, nil, "0:-1#12"), nil
		case strings.HasSuffix(r.URL.Path, "/docs/"+authorizationPolicyItemID):
			if seen[len(seen)-1] != "0:-1#5" {
				t.Fatal("raw data response overwrote the separate authorization chain")
			}
			return authorizationItemResponse(t, r, &storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: newAuthorizationPolicy(scopeID, owner, "shared")}, "0:-1#6"), nil
		default:
			t.Fatalf("unexpected request %s", r.URL.Path)
		}
		return nil, nil
	})
	_, _, session, err := store.read(ctx, scopeID, "head", "0:-1#10")
	if err != nil || session != "0:-1#11" {
		t.Fatalf("client data session: %q %v", session, err)
	}
	_, _, session, err = store.read(ctx, scopeID, "d:note", session)
	if err != nil || session != "0:-1#12" {
		t.Fatalf("subsequent data session: %q %v", session, err)
	}
	if token, _ := authorizationSession(ctx, scopeID, ""); token != "0:-1#5" {
		t.Fatalf("data response leaked into authorization token: %q", token)
	}
	_, _, _, err = store.readAuthorizationPolicy(ctx, scopeID, "")
	if err != nil {
		t.Fatal(err)
	}
	if token, _ := authorizationSession(ctx, scopeID, ""); token != "0:-1#6" {
		t.Fatalf("authorization response did not advance its own chain: %q", token)
	}
	if !reflect.DeepEqual(seen, []string{"0:-1#10", "0:-1#11", "0:-1#5"}) {
		t.Fatalf("wrong SDK session headers: %+v", seen)
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

func TestCosmosAuthorizationPolicyHonorsBothIndependentCausalMinima(t *testing.T) {
	owner, member, scopeID := namespacedID("causal-owner"), namespacedID("causal-member"), namespacedID("causal-scope")
	for _, name := range []string{"data-newer-revoke", "auth-newer-regrant", "same-policy", "different-owner", "equal-revision-conflicting-body", "missing-auth", "missing-data", "both-missing"} {
		t.Run(name, func(t *testing.T) {
			authorization := newAuthorizationPolicy(scopeID, owner, "shared")
			authorization.Revision = 2
			authorization.Members[member] = ScopeMember{AccountID: member, Role: "writer", PermissionVersion: "2"}
			data := cloneAuthorizationPolicy(authorization)
			wantRevision, wantETag := int64(2), "\"auth\""
			wantUnavailable := false
			switch name {
			case "data-newer-revoke":
				data.Revision = 3
				data.Members[member] = ScopeMember{AccountID: member, Role: "none", PermissionVersion: "3"}
				wantRevision, wantETag = 3, "\"data\""
			case "auth-newer-regrant":
				authorization.Revision = 4
				authorization.Members[member] = ScopeMember{AccountID: member, Role: "writer", PermissionVersion: "4"}
				data.Revision = 3
				data.Members[member] = ScopeMember{AccountID: member, Role: "none", PermissionVersion: "3"}
				wantRevision = 4
			case "different-owner":
				data.OwnerAccountID = namespacedID("different-owner")
				wantUnavailable = true
			case "equal-revision-conflicting-body":
				data.Members[member] = ScopeMember{AccountID: member, Role: "reader", PermissionVersion: "2"}
				wantUnavailable = true
			case "missing-auth":
				authorization = nil
				wantUnavailable = true
			case "missing-data":
				data = nil
				wantUnavailable = true
			case "both-missing":
				authorization, data = nil, nil
			}
			ctx := withAuthorizationSessions(context.Background())
			if err := rememberAuthorizationSession(ctx, scopeID, "0:-1#5"); err != nil {
				t.Fatal(err)
			}
			seen := []string{}
			store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
				if r.URL.Path == "/" || r.URL.Path == "" {
					return cosmosResponse(r, 200, authorizationTestAccountMetadata, ""), nil
				}
				if !strings.HasSuffix(r.URL.Path, "/docs/"+authorizationPolicyItemID) {
					t.Fatal("causal policy check reached unrelated data")
				}
				token := r.Header.Get("x-ms-session-token")
				seen = append(seen, token)
				selected, responseToken, etag := authorization, "0:-1#6", "\"auth\""
				if token == "0:-1#10" {
					selected, responseToken, etag = data, "0:-1#11", "\"data\""
				} else if token != "0:-1#5" {
					t.Fatalf("wrong independent minimum %q", token)
				}
				var item *storedItem
				if selected != nil {
					item = &storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: selected}
				}
				response := authorizationItemResponse(t, r, item, responseToken)
				response.Header.Set("Etag", etag)
				return response, nil
			})
			selected, etag, err := store.readAuthorizationPolicyAt(ctx, scopeID, "0:-1#10")
			if !reflect.DeepEqual(seen, []string{"0:-1#5", "0:-1#10"}) {
				t.Fatalf("one causal minimum was discarded: %+v", seen)
			}
			if token, _ := authorizationSession(ctx, scopeID, ""); token != "0:-1#6" {
				t.Fatalf("data-causal probe overwrote auth chain: %q", token)
			}
			if wantUnavailable {
				requireAuthorizationCode(t, err, "authorization_store_unavailable")
				return
			}
			if name == "both-missing" {
				if err != nil || selected != nil {
					t.Fatalf("unknown scope: %+v %v", selected, err)
				}
				return
			}
			if err != nil || selected == nil || selected.Revision != wantRevision || string(etag) != wantETag {
				t.Fatalf("wrong trusted revision or its fence ETag: %+v %s %v", selected, etag, err)
			}
			if name == "data-newer-revoke" {
				_, err := selected.scope(member)
				requireAuthorizationCode(t, err, "forbidden")
			}
			if name == "auth-newer-regrant" {
				scope, err := selected.scope(member)
				if err != nil || scope.PermissionVersion != "4" {
					t.Fatalf("stale generation revived: %+v %v", scope, err)
				}
				if err := checkAuthorizationWrite(selected, scopeID, Mutation{PrincipalID: member, AuthorizationVersion: "2"}); err == nil {
					t.Fatal("old-generation mutation accepted after regrant")
				}
			}
		})
	}
}

func TestCosmosAuthorizationPolicyCannotRegressAfterNewerDataObservation(t *testing.T) {
	owner, member, scopeID := namespacedID("watermark-owner"), namespacedID("watermark-member"), namespacedID("watermark-scope")
	makePolicy := func(revision int64, role, version string) *AuthorizationPolicy {
		policy := newAuthorizationPolicy(scopeID, owner, "shared")
		policy.Revision = revision
		policy.Members[member] = ScopeMember{AccountID: member, Role: role, PermissionVersion: version}
		return policy
	}
	for _, name := range []string{"regression", "same-revision-body-change", "immutable-owner-change", "both-disappear", "valid-forward"} {
		t.Run(name, func(t *testing.T) {
			ctx := withAuthorizationSessions(context.Background())
			if err := rememberAuthorizationSession(ctx, scopeID, "0:-1#5"); err != nil {
				t.Fatal(err)
			}
			call := 0
			store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
				if r.URL.Path == "/" || r.URL.Path == "" {
					return cosmosResponse(r, 200, authorizationTestAccountMetadata, ""), nil
				}
				if !strings.HasSuffix(r.URL.Path, "/docs/"+authorizationPolicyItemID) {
					t.Fatal("watermark check reached unrelated data")
				}
				call++
				token := r.Header.Get("x-ms-session-token")
				var policy *AuthorizationPolicy
				responseToken := "0:-1#5"
				switch call {
				case 1:
					if token != "0:-1#5" {
						t.Fatal("initial auth minimum lost")
					}
					policy = makePolicy(2, "writer", "2")
				case 2:
					if token != "0:-1#10" {
						t.Fatal("initial data minimum lost")
					}
					policy, responseToken = makePolicy(4, "writer", "4"), "0:-1#20"
				default:
					wantToken := "0:-1#5"
					if call == 4 {
						wantToken, responseToken = "0:-1#10", "0:-1#10"
					}
					if token != wantToken {
						t.Fatalf("independent opaque minimum changed: got %q want %q", token, wantToken)
					}
					switch name {
					case "regression":
						policy = makePolicy(3, "none", "3")
						if call == 4 {
							policy = makePolicy(2, "writer", "2")
						}
					case "same-revision-body-change":
						policy = makePolicy(4, "reader", "4")
					case "immutable-owner-change":
						policy = makePolicy(5, "writer", "4")
						policy.OwnerAccountID = namespacedID("changed-owner")
					case "both-disappear":
						policy = nil
					case "valid-forward":
						policy = makePolicy(5, "writer", "4")
						other := namespacedID("other-member")
						policy.Members[other] = ScopeMember{AccountID: other, Role: "reader", PermissionVersion: "5"}
					}
				}
				var item *storedItem
				if policy != nil {
					item = &storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: policy}
				}
				return authorizationItemResponse(t, r, item, responseToken), nil
			})
			first, _, err := store.readAuthorizationPolicyAt(ctx, scopeID, "0:-1#10")
			if err != nil || first == nil || first.Revision != 4 {
				t.Fatalf("newer data policy not observed: %+v %v", first, err)
			}
			second, etag, err := store.readAuthorizationPolicyAt(ctx, scopeID, "0:-1#10")
			if name == "valid-forward" {
				if err != nil || second == nil || second.Revision != 5 || second.Members[member].PermissionVersion != "4" {
					t.Fatalf("legitimate unrelated membership edit rejected: %+v %v", second, err)
				}
			} else {
				requireAuthorizationCode(t, err, "authorization_store_unavailable")
				if second != nil || etag != "" {
					t.Fatal("regressed policy or ETag escaped fail-closed check")
				}
			}
			if call != 4 {
				t.Fatalf("watermark became a permission cache: reads=%d", call)
			}
		})
	}
}

func TestAuthorizationPolicyHighWaterIsRequestLocalAndBounded(t *testing.T) {
	ctx := withAuthorizationSessions(context.Background())
	owner := namespacedID("watermark-owner")
	for n := 0; n < 8; n++ {
		scope := namespacedID("watermark", string(rune('a'+n)))
		if err := observeAuthorizationPolicy(ctx, scope, newAuthorizationPolicy(scope, owner, "shared")); err != nil {
			t.Fatal(err)
		}
	}
	ninth := namespacedID("watermark-ninth")
	requireAuthorizationCode(t, observeAuthorizationPolicy(ctx, ninth, newAuthorizationPolicy(ninth, owner, "shared")), "authorization_store_unavailable")
	if err := observeAuthorizationPolicy(withAuthorizationSessions(context.Background()), ninth, newAuthorizationPolicy(ninth, owner, "shared")); err != nil {
		t.Fatal("high-water leaked across requests", err)
	}
}

func TestCosmosDataBatchFailureMinimumRejectsOldReceiptAfterRevocation(t *testing.T) {
	owner, member, scopeID := namespacedID("fence-owner"), namespacedID("fence-member"), namespacedID("fence-scope")
	policy := newAuthorizationPolicy(scopeID, owner, "shared")
	policy.Revision = 2
	policy.Members[member] = ScopeMember{AccountID: member, Role: "writer", PermissionVersion: "2"}
	revoked := cloneAuthorizationPolicy(policy)
	revoked.Revision = 3
	revoked.Members[member] = ScopeMember{AccountID: member, Role: "none", PermissionVersion: "3"}
	mutation := Mutation{OperationID: "33333333-3333-4333-8333-333333333333", DocumentID: "note", Kind: "put", Data: json.RawMessage("{\"private\":\"receipt\"}"), PrincipalID: member, AuthorizationVersion: "2"}
	hash, err := validateMutation(&mutation, scopeID)
	if err != nil {
		t.Fatal(err)
	}
	batches, receipts, policyProbes := 0, 0, []string{}
	store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/" || r.URL.Path == "" {
			return cosmosResponse(r, 200, authorizationTestAccountMetadata, ""), nil
		}
		if strings.HasSuffix(r.URL.Path, "/docs/"+authorizationPolicyItemID) {
			token := r.Header.Get("x-ms-session-token")
			policyProbes = append(policyProbes, token)
			selected, responseToken := policy, "0:-1#5"
			if token == "0:-1#10" {
				selected, responseToken = revoked, "0:-1#10"
			}
			return authorizationItemResponse(t, r, &storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: selected}, responseToken), nil
		}
		if r.Method == http.MethodGet {
			if strings.Contains(r.URL.Path, "/docs/r:") {
				receipts++
				if batches > 0 {
					document := Document{ID: mutation.DocumentID, Version: 1, Data: mutation.Data}
					receipt := &storedItem{ID: "r:" + mutationReceiptKey(mutation), ScopeID: scopeID, Kind: "receipt", RequestHash: hash, Document: &document}
					return authorizationItemResponse(t, r, receipt, "0:-1#10"), nil
				}
			}
			return authorizationItemResponse(t, r, nil, "0:-1#7"), nil
		}
		batches++
		return cosmosResponse(r, 200, "[{\"statusCode\":424},{\"statusCode\":424},{\"statusCode\":424},{\"statusCode\":424},{\"statusCode\":412}]", "0:-1#10"), nil
	})
	document, _, err := store.Mutate(context.Background(), scopeID, mutation, hash, "")
	requireAuthorizationCode(t, err, "forbidden")
	if document.ID != "" || batches != 1 || receipts != 1 || !reflect.DeepEqual(policyProbes, []string{"", "0:-1#5", "0:-1#10"}) {
		t.Fatalf("retry lost data causal minimum: batches=%d receipts=%d probes=%v", batches, receipts, policyProbes)
	}
}

func TestCosmosBuiltinDataMinimumConstrainsPostReadAuthorization(t *testing.T) {
	issuer := "https://review.test"
	account := identityAccount(AccountIdentity{Issuer: issuer, Subject: "member"})
	scope := strings.Repeat("c", 64)
	owner := strings.Repeat("a", 64)
	auth := newAuthorizationPolicy(scope, owner, "shared")
	auth.Revision = 2
	auth.Members[account.AccountID] = ScopeMember{AccountID: account.AccountID, Role: "writer", PermissionVersion: "2"}
	revoked := cloneAuthorizationPolicy(auth)
	revoked.Revision = 3
	revoked.Members[account.AccountID] = ScopeMember{AccountID: account.AccountID, Role: "none", PermissionVersion: "3"}
	policyTokens := []string{}
	queryDone := false
	respond := func(r *http.Request, item *storedItem, token string) *http.Response {
		body, _ := encodeJSON(item)
		return cosmosResponse(r, 200, string(body), token)
	}
	store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "" || r.URL.Path == "/" {
			return cosmosResponse(r, 200, `{"readableLocations":[{"name":"Test","databaseAccountEndpoint":"https://cosmos.test"}],"writableLocations":[{"name":"Test","databaseAccountEndpoint":"https://cosmos.test"}],"enableMultipleWriteLocations":false,"userConsistencyPolicy":{"defaultConsistencyLevel":"Session"}}`, ""), nil
		}
		if strings.Contains(r.Header.Get("x-ms-documentdb-partitionkey"), account.PersonalScopeID) {
			if strings.HasSuffix(r.URL.Path, "/docs/a:account") {
				return respond(r, &storedItem{ID: authorizationAccountItemID, ScopeID: account.PersonalScopeID, Kind: "account", Account: &accountRecord{Account: account, Identity: AccountIdentity{Issuer: issuer, Subject: "member"}}}, "1:-1#2"), nil
			}
			return respond(r, &storedItem{ID: authorizationPolicyItemID, ScopeID: account.PersonalScopeID, Kind: "authorization", Policy: newAuthorizationPolicy(account.PersonalScopeID, account.AccountID, "user")}, "1:-1#2"), nil
		}
		if strings.HasSuffix(r.URL.Path, "/docs/a:policy") {
			token := r.Header.Get("x-ms-session-token")
			policyTokens = append(policyTokens, token)
			policy := auth
			resultToken := "0:-1#5"
			if token == "0:-1#10" {
				policy = revoked
				resultToken = "0:-1#10"
			}
			return respond(r, &storedItem{ID: authorizationPolicyItemID, ScopeID: scope, Kind: "authorization", Policy: policy}, resultToken), nil
		}
		if strings.HasSuffix(r.URL.Path, "/docs/head") {
			return respond(r, &storedItem{ID: "head", ScopeID: scope, Kind: "head", Sequence: 1}, "0:-1#10"), nil
		}
		if r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/docs") {
			queryDone = true
			body, _ := encodeJSON(map[string]any{"Documents": []storedItem{{ID: "c:0000000000000001", ScopeID: scope, Kind: "change", Sequence: 1, Document: &Document{ID: "note", Version: 1, Data: json.RawMessage(`{"secret":"must be denied after observed data LSN10"}`)}}}, "_count": 1})
			return cosmosResponse(r, 200, string(body), "0:-1#10"), nil
		}
		t.Fatalf("unexpected SDK route: %s %s", r.Method, r.URL.Path)
		return nil, nil
	})
	key, e := rsa.GenerateKey(rand.Reader, 2048)
	if e != nil {
		t.Fatal(e)
	}
	verifier := oidc.NewVerifier(issuer, &oidc.StaticKeySet{PublicKeys: []crypto.PublicKey{&key.PublicKey}}, &oidc.Config{ClientID: "cosmos-sync-emulator-tests", SupportedSigningAlgs: []string{"RS256"}})
	config := Config{Development: true, Storage: "Cosmos", CursorKeyBase64: base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{42}, 32)), Authorization: AuthorizationOptions{Mode: "builtin"}, OIDC: OIDCConfig{Issuer: issuer, Audience: "cosmos-sync-emulator-tests", RequiredScope: "cosmos_sync"}}
	server, e := NewServer(config, store, verifier)
	if e != nil {
		t.Fatal(e)
	}
	req := httptest.NewRequest("GET", "https://review.test/v1/sync", nil)
	req.Header.Set("Authorization", "Bearer "+signEmulatorJWT(t, key, issuer, "member"))
	req.Header.Set(ScopeHeader, scope)
	req.Header.Set(PrincipalHeader, account.AccountID)
	req.Header.Set(PermissionHeader, "2")
	req.Header.Set(ScopeModeHeader, "shared")
	response := httptest.NewRecorder()
	server.ServeHTTP(response, req)
	if !queryDone {
		t.Fatalf("proof never reached slow data work: %d %s", response.Code, response.Body.String())
	}
	if response.Code != 403 || strings.Contains(response.Body.String(), "secret") {
		t.Fatalf("dataLSN10 must constrain post-policy check: status%d policytokens%v body%s", response.Code, policyTokens, response.Body.String())
	}
}
