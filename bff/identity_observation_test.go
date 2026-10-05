package syncbff

import (
	"context"
	"reflect"
	"testing"
)

func TestIdentityDirectoryObservationRejectsRequestLocalRollbackAndEquivocation(t *testing.T) {
	f := newDirectoryFixture(t)
	account := f.register(t, f.google, "observed-owner")
	before := cloneTestDirectory(f.store.state)
	f.link(t, account, "observed-second")
	current := cloneTestDirectory(f.store.state)
	for _, name := range []string{"missing", "older-revision", "changed-same-revision", "invalid"} {
		t.Run(name, func(t *testing.T) {
			ctx := withAuthorizationSessions(context.Background())
			if err := observeIdentityDirectory(ctx, current); err != nil {
				t.Fatal(err)
			}
			other := cloneTestDirectory(current)
			switch name {
			case "missing":
				other = nil
			case "older-revision":
				other = before
			case "changed-same-revision":
				other.Revision = current.Revision
				value := other.Accounts[account.AccountID]
				value.Generation++
				other.Accounts[account.AccountID] = value
				if !validIdentityDirectory(other) {
					t.Fatal("equivocation fixture must be internally valid before the high-water check")
				}
			case "invalid":
				other.Accounts[account.AccountID] = directoryAccount{}
			}
			err := observeIdentityDirectory(ctx, other)
			requireAuthorizationCode(t, err, "identity_directory_unavailable")
			if err := observeIdentityDirectory(ctx, current); err != nil {
				t.Fatal("rejected read replaced the request's security high-water mark", err)
			}
		})
	}
	ctx := withAuthorizationSessions(context.Background())
	if err := observeIdentityDirectory(ctx, before); err != nil {
		t.Fatal(err)
	}
	if err := observeIdentityDirectory(ctx, current); err != nil {
		t.Fatal("newer valid directory revision was rejected", err)
	}
	requireAuthorizationCode(t, observeIdentityDirectory(ctx, before), "identity_directory_unavailable")
}

func TestMemoryIdentityDirectoryConditionalStorageHasNoMutableAliases(t *testing.T) {
	memory := NewMemoryStore()
	store := memoryIdentityDirectoryStore{memory}
	f := newDirectoryFixture(t)
	f.d.store = store
	account := f.register(t, f.google, "memory-directory-owner")
	state, version, err := store.loadIdentityDirectory(context.Background())
	if err != nil || version == "" || !validIdentityDirectory(state) {
		t.Fatal("memory directory did not persist exact valid state", err)
	}
	expected := cloneTestDirectory(state)
	binding := state.Bindings[account.IdentityIDs[0]]
	binding.Active = false
	state.Bindings[account.IdentityIDs[0]] = binding
	state.Accounts[account.AccountID].IdentityIDs[0] = "modified"
	state.Audits[0].ProofDigests[0] = "modified"
	reloaded, reloadedVersion, err := (memoryIdentityDirectoryStore{memory}).loadIdentityDirectory(context.Background())
	if err != nil || reloadedVersion != version || !reflect.DeepEqual(reloaded, expected) {
		t.Fatal("a reader mutated the stored directory through aliases", err)
	}
	next := cloneTestDirectory(expected)
	next.Revision++
	if err := store.compareIdentityDirectory(context.Background(), version, next); err != nil {
		t.Fatal(err)
	}
	next.Accounts[account.AccountID].IdentityIDs[0] = "modified-after-write"
	requireAuthorizationCode(t, store.compareIdentityDirectory(context.Background(), version, expected), "authorization_contention")
	reloaded, _, err = store.loadIdentityDirectory(context.Background())
	if err != nil || !validIdentityDirectory(reloaded) || reloaded.Revision != expected.Revision+1 ||
		reloaded.Accounts[account.AccountID].IdentityIDs[0] != expected.Accounts[account.AccountID].IdentityIDs[0] {
		t.Fatal("write input alias or stale version overwrote the stored directory", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := store.loadIdentityDirectory(ctx); err != context.Canceled {
		t.Fatal("cancelled directory read accessed storage", err)
	}
	if err := store.compareIdentityDirectory(ctx, "", expected); err != context.Canceled {
		t.Fatal("cancelled directory write accessed storage", err)
	}
}
