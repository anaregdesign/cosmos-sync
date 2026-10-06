package syncbff

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"reflect"
	"strings"
	"sync"
	"testing"
)

func testDirectoryAccount(label string) directoryAccount {
	id := namespacedID("random-account-test-fixture", label)
	return directoryAccount{
		Account:    Account{AccountID: id, PersonalScopeID: personalScopeID(id)},
		Generation: 1, IdentityIDs: []string{namespacedID("credential-test-fixture", label)},
	}
}

func TestDirectoryPersonalPolicyPreservesRandomOwnershipAndNumericFence(t *testing.T) {
	ctx := context.Background()
	store := NewMemoryStore()
	owner, member := testDirectoryAccount("owner"), testDirectoryAccount("member")
	var workers sync.WaitGroup
	for range 12 {
		workers.Go(func() {
			got, err := store.ensureDirectoryAccount(ctx, owner)
			if err != nil || got != owner.Account {
				t.Error("concurrent exact directory account initialization", err)
			}
		})
	}
	workers.Wait()
	if _, err := store.ensureDirectoryAccount(ctx, member); err != nil {
		t.Fatal(err)
	}
	initial, err := store.LoadAuthorizationPolicy(ctx, owner.PersonalScopeID)
	if err != nil || !validPersonalPolicy(initial, owner.AccountID) || len(store.accounts) != 2 {
		t.Fatal("random accounts did not receive independent personal policies", err)
	}
	owner.Generation, owner.IdentityIDs = maxIdentityGeneration, append(owner.IdentityIDs, namespacedID("added-credential"))
	got, err := store.ensureDirectoryAccount(ctx, owner)
	after, policyErr := store.LoadAuthorizationPolicy(ctx, owner.PersonalScopeID)
	if err != nil || policyErr != nil || got != owner.Account || !reflect.DeepEqual(initial, after) {
		t.Fatal("identity generation changed or reset the personal policy", err, policyErr)
	}
	mutation := Mutation{OperationID: "11111111-1111-4111-8111-111111111111",
		DocumentID: "note", Kind: "put", Data: json.RawMessage(`{"value":"stable"}`),
		PrincipalID: owner.AccountID, AuthorizationVersion: "1"}
	hash, err := validateMutation(&mutation, owner.PersonalScopeID)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Mutate(ctx, owner.PersonalScopeID, mutation, hash, ""); err != nil {
		t.Fatal("directory identity changed the numeric data-partition fence", err)
	}
	policy, err := store.CreateSharedScope(ctx, owner.AccountID, "22222222-2222-4222-8222-222222222222")
	if err != nil {
		t.Fatal(err)
	}
	policy, err = store.ChangeMembership(ctx, policy.ScopeID, owner.AccountID, MembershipChange{
		OperationID: "33333333-3333-4333-8333-333333333333", AccountID: member.AccountID, Role: "writer", BaseRevision: 1,
	})
	if err != nil || len(policy.Members) != 1 || policy.Members[0].PermissionVersion != "2" {
		t.Fatal("registered random accounts could not use the existing shared membership policy", err)
	}
	mutation.PrincipalID = member.AccountID
	_, _, err = store.Mutate(ctx, owner.PersonalScopeID, mutation, hash, "")
	requireAuthorizationCode(t, err, "forbidden")
}

func TestAccountProvenanceCannotImplicitlyAdoptAnotherNamespace(t *testing.T) {
	ctx := context.Background()
	identity := AccountIdentity{Issuer: "https://namespace-fixture.invalid", Subject: "same-human"}
	builtin := identityAccount(identity)
	directory := testDirectoryAccount("collision")
	directory.Account = builtin
	for _, builtinFirst := range []bool{true, false} {
		store := NewMemoryStore()
		if builtinFirst {
			if _, err := store.EnsureAccount(ctx, identity); err != nil {
				t.Fatal(err)
			}
			_, err := store.ensureDirectoryAccount(ctx, directory)
			requireAuthorizationCode(t, err, "authorization_store_unavailable")
		} else {
			if _, err := store.ensureDirectoryAccount(ctx, directory); err != nil {
				t.Fatal(err)
			}
			_, err := store.EnsureAccount(ctx, identity)
			requireAuthorizationCode(t, err, "authorization_store_unavailable")
		}
		if len(store.accounts) != 1 || len(store.policies) != 1 {
			t.Fatal("provenance mismatch wrote or migrated another namespace")
		}
	}
}

func TestDirectoryPersonalMetadataFailsClosedWithoutRepair(t *testing.T) {
	for _, name := range []string{"missing-marker", "unknown-marker", "legacy-identity", "wrong-scope", "missing-policy", "missing-account", "foreign-owner", "shared-personal-policy"} {
		t.Run(name, func(t *testing.T) {
			store := NewMemoryStore()
			account := testDirectoryAccount(name)
			if _, err := store.ensureDirectoryAccount(context.Background(), account); err != nil {
				t.Fatal(err)
			}
			record := store.accounts[account.AccountID]
			switch name {
			case "missing-marker":
				record.DirectoryVersion = ""
			case "unknown-marker":
				record.DirectoryVersion = "future-directory-v2"
			case "legacy-identity":
				record.Identity = AccountIdentity{Issuer: "https://fixture.invalid", Subject: "unapproved"}
			case "wrong-scope":
				record.PersonalScopeID = namespacedID("wrong")
			case "missing-policy":
				delete(store.policies, account.PersonalScopeID)
			case "missing-account":
				delete(store.accounts, account.AccountID)
			case "foreign-owner":
				store.policies[account.PersonalScopeID].OwnerAccountID = namespacedID("foreign")
			case "shared-personal-policy":
				store.policies[account.PersonalScopeID].Mode = "shared"
			}
			if name != "missing-account" {
				store.accounts[account.AccountID] = record
			}
			accounts, _ := encodeJSON(store.accounts)
			policies, _ := encodeJSON(store.policies)
			_, err := store.ensureDirectoryAccount(context.Background(), account)
			requireAuthorizationCode(t, err, "authorization_store_unavailable")
			afterAccounts, _ := encodeJSON(store.accounts)
			afterPolicies, _ := encodeJSON(store.policies)
			if string(accounts) != string(afterAccounts) || string(policies) != string(afterPolicies) {
				t.Fatal("implicit initialization repaired corrupt account/policy metadata")
			}
		})
	}
}

func TestDirectoryPersonalInitializationRejectsInvalidTrustedValuesBeforeStorage(t *testing.T) {
	for _, name := range []string{"bad-account", "bad-scope", "zero-generation", "large-generation", "missing-identity", "bad-identity", "duplicate-identity"} {
		t.Run(name, func(t *testing.T) {
			account := testDirectoryAccount(name)
			switch name {
			case "bad-account":
				account.AccountID = "client-selected"
			case "bad-scope":
				account.PersonalScopeID = namespacedID("foreign-partition")
			case "zero-generation":
				account.Generation = 0
			case "large-generation":
				account.Generation = maxIdentityGeneration + 1
			case "missing-identity":
				account.IdentityIDs = nil
			case "bad-identity":
				account.IdentityIDs[0] = "unsigned-claim"
			case "duplicate-identity":
				account.IdentityIDs = append(account.IdentityIDs, account.IdentityIDs[0])
			}
			store := NewMemoryStore()
			_, err := store.ensureDirectoryAccount(context.Background(), account)
			requireAuthorizationCode(t, err, "invalid_authorization_request")
			if len(store.accounts) != 0 || len(store.policies) != 0 {
				t.Fatal("invalid trusted directory values reached storage")
			}
		})
	}
}

func TestCosmosDirectoryPersonalInitializationUsesExactAtomicOriginAndAcknowledgedRead(t *testing.T) {
	account := testDirectoryAccount("cosmos-personal")
	record := &storedItem{ID: authorizationAccountItemID, ScopeID: account.PersonalScopeID, Kind: "account",
		Account: &accountRecord{Account: account.Account, DirectoryVersion: directoryAccountVersion}}
	policy := &storedItem{ID: authorizationPolicyItemID, ScopeID: account.PersonalScopeID, Kind: "authorization",
		Policy: newAuthorizationPolicy(account.PersonalScopeID, account.AccountID, "user")}
	committed, writes, postReads := false, 0, 0
	store := testCosmos(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/" || r.URL.Path == "" {
			return cosmosResponse(r, 200, authorizationTestAccountMetadata, ""), nil
		}
		if r.Header.Get("x-ms-documentdb-partitionkey") != `["`+account.PersonalScopeID+`"]` {
			t.Fatal("personal initialization crossed the random account's server-owned partition")
		}
		if r.Method == http.MethodGet {
			if !committed {
				return authorizationItemResponse(t, r, nil, "personal-before"), nil
			}
			postReads++
			if writes == 1 && postReads <= 2 && r.Header.Get("x-ms-session-token") != "personal-ack" {
				t.Fatal("personal metadata read did not observe the atomic create acknowledgement")
			}
			if strings.HasSuffix(r.URL.Path, "/docs/"+authorizationAccountItemID) {
				return authorizationItemResponse(t, r, record, "personal-ack"), nil
			}
			return authorizationItemResponse(t, r, policy, "personal-ack"), nil
		}
		body, _ := io.ReadAll(r.Body)
		var operations []struct {
			Operation string     `json:"operationType"`
			Item      storedItem `json:"resourceBody"`
		}
		if committed || json.Unmarshal(body, &operations) != nil || len(operations) != 2 ||
			operations[0].Operation != "Create" || operations[1].Operation != "Create" ||
			operations[0].Item.Account == nil || *operations[0].Item.Account != *record.Account ||
			operations[1].Item.Policy == nil || !reflect.DeepEqual(operations[1].Item.Policy, policy.Policy) ||
			r.Header.Get("x-ms-session-token") != "personal-before" {
			t.Fatal("directory personal policy was not one exact create batch with immutable provenance")
		}
		writes++
		committed = true
		return cosmosResponse(r, 200, `[{"statusCode":201},{"statusCode":201}]`, "personal-ack"), nil
	})
	got, err := store.ensureDirectoryAccount(context.Background(), account)
	if err != nil || got != account.Account || postReads != 2 || writes != 1 {
		t.Fatal("random account did not acquire a usable acknowledged personal policy", err)
	}
	account.Generation++
	if got, err := store.ensureDirectoryAccount(context.Background(), account); err != nil || got != account.Account || writes != 1 {
		t.Fatal("fresh identity generation reset account/policy instead of an exact read", err)
	}
	for _, name := range []string{"missing-marker", "unknown-marker", "legacy-identity", "wrong-account", "foreign-owner", "missing-policy"} {
		t.Run(name, func(t *testing.T) {
			copyRecord, copyPolicy := *record, *policy
			copyAccount, personal := *record.Account, *policy.Policy
			copyRecord.Account, copyPolicy.Policy = &copyAccount, &personal
			switch name {
			case "missing-marker":
				copyAccount.DirectoryVersion = ""
			case "unknown-marker":
				copyAccount.DirectoryVersion = "unknown"
			case "legacy-identity":
				copyAccount.Identity = AccountIdentity{"https://fixture.invalid", "subject"}
			case "wrong-account":
				copyAccount.AccountID = namespacedID("other")
			case "foreign-owner":
				personal.OwnerAccountID = namespacedID("other")
			}
			corrupt := testCosmos(t, func(r *http.Request) (*http.Response, error) {
				if r.URL.Path == "/" || r.URL.Path == "" {
					return cosmosResponse(r, 200, authorizationTestAccountMetadata, ""), nil
				}
				if r.Method != http.MethodGet {
					t.Fatal("corrupt directory/personal metadata was implicitly repaired")
				}
				if strings.HasSuffix(r.URL.Path, "/docs/"+authorizationAccountItemID) {
					return authorizationItemResponse(t, r, &copyRecord, "corrupt-read"), nil
				}
				if name == "missing-policy" {
					return authorizationItemResponse(t, r, nil, "corrupt-read"), nil
				}
				return authorizationItemResponse(t, r, &copyPolicy, "corrupt-read"), nil
			})
			_, err := corrupt.ensureDirectoryAccount(context.Background(), account)
			requireAuthorizationCode(t, err, "authorization_store_unavailable")
		})
	}
}
