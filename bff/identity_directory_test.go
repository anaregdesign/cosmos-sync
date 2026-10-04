package syncbff

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

type testIdentityDirectoryStore struct {
	mu            sync.Mutex
	state         *identityDirectoryState
	version       int
	loads         int
	writes        int
	conflicts     int
	fail          error
	ambiguousNext bool
}

func cloneTestDirectory(state *identityDirectoryState) *identityDirectoryState {
	if state == nil {
		return nil
	}
	body, err := json.Marshal(state)
	if err != nil {
		panic(err)
	}
	var copy identityDirectoryState
	if err := json.Unmarshal(body, &copy); err != nil {
		panic(err)
	}
	return &copy
}

func (s *testIdentityDirectoryStore) loadIdentityDirectory(context.Context) (*identityDirectoryState, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.loads++
	if s.fail != nil {
		return nil, "", s.fail
	}
	version := ""
	if s.state != nil {
		version = fmt.Sprint(s.version)
	}
	return cloneTestDirectory(s.state), version, nil
}

func (s *testIdentityDirectoryStore) compareIdentityDirectory(_ context.Context, version string, state *identityDirectoryState) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.fail != nil {
		return s.fail
	}
	expected := ""
	if s.state != nil {
		expected = fmt.Sprint(s.version)
	}
	if version != expected || s.conflicts > 0 {
		if s.conflicts > 0 {
			s.conflicts--
		}
		return protocolError(412, "authorization_contention")
	}
	s.state, s.version, s.writes = cloneTestDirectory(state), s.version+1, s.writes+1
	if s.ambiguousNext {
		s.ambiguousNext = false
		return protocolError(503, "batch_failed")
	}
	return nil
}

type directoryFixture struct {
	d       *identityDirectory
	store   *testIdentityDirectoryStore
	now     time.Time
	google  identityProofTarget
	apple   identityProofTarget
	counter int
}

func newDirectoryFixture(t *testing.T) *directoryFixture {
	t.Helper()
	f := &directoryFixture{
		store:  &testIdentityDirectoryStore{},
		now:    time.Unix(1800000000, 0).UTC(),
		google: identityProofTarget{"https://google-fixture.invalid", "google", "consumer-v1", "google-client", "https://app.invalid/callback"},
		apple:  identityProofTarget{"https://apple-fixture.invalid", "apple", "consumer-v1", "apple-client", "com.anaregdesign.cosmossync://auth/oauthredirect"},
	}
	var err error
	f.d, err = newIdentityDirectory(f.store, []identityProofTarget{f.google, f.apple})
	if err != nil {
		t.Fatal(err)
	}
	f.d.now = func() time.Time { return f.now }
	return f
}

// These are internal verified-proof stamps, not a provider verifier or signed
// JWT fixture. No production route constructs stamps from client JSON.
func (f *directoryFixture) proof(t *testing.T, raw string, target identityProofTarget, subject string) verifiedDirectoryProof {
	t.Helper()
	digest, err := identityChallengeDigest(raw)
	if err != nil {
		t.Fatal(err)
	}
	f.counter++
	return verifiedDirectoryProof{Target: target, Subject: subject, AuthenticatedAt: f.now, ExpiresAt: f.now.Add(time.Hour),
		ChallengeDigest: digest, ProofDigest: namespacedID("proof-fixture", fmt.Sprint(f.counter))}
}

func (f *directoryFixture) register(t *testing.T, target identityProofTarget, subject string) directoryAccount {
	t.Helper()
	raw, err := f.d.begin(context.Background(), nil, "register", target, "")
	if err != nil {
		t.Fatal(err)
	}
	account, err := f.d.register(context.Background(), raw, f.proof(t, raw, target, subject))
	if err != nil {
		t.Fatal(err)
	}
	return account
}

func (f *directoryFixture) session(account directoryAccount, identity int) directorySession {
	return directorySession{account.AccountID, account.Generation, account.IdentityIDs[identity], f.now.Add(time.Hour)}
}

func (f *directoryFixture) link(t *testing.T, account directoryAccount, subject string) directoryAccount {
	t.Helper()
	session := f.session(account, 0)
	raw, err := f.d.begin(context.Background(), &session, "link", f.apple, "")
	if err != nil {
		t.Fatal(err)
	}
	before := f.store.state.Bindings[session.IdentityID].Identity
	updated, err := f.d.change(context.Background(), session, raw, "link",
		f.proof(t, raw, f.google, before.Subject), f.proof(t, raw, f.apple, subject))
	if err != nil {
		t.Fatal(err)
	}
	return updated
}

func TestIdentityDirectoryStableOwnershipGenerationAndUnlink(t *testing.T) {
	f := newDirectoryFixture(t)
	account := f.register(t, f.google, "google-subject")
	initialSession := f.session(account, 0)
	linked := f.link(t, account, "apple-subject")
	if linked.Account != account.Account || linked.Generation != 2 || len(linked.IdentityIDs) != 2 ||
		linked.AccountID == identityAccount(AccountIdentity{f.google.Issuer, "google-subject"}).AccountID {
		t.Fatalf("link did not preserve independent random ownership: %+v", linked)
	}
	_, err := f.d.begin(context.Background(), &initialSession, "link", f.apple, "")
	requireAuthorizationCode(t, err, "identity_session_invalid")

	session := f.session(linked, 0)
	raw, err := f.d.begin(context.Background(), &session, "unlink", f.google, linked.IdentityIDs[1])
	if err != nil {
		t.Fatal(err)
	}
	proof := f.proof(t, raw, f.google, "google-subject")
	unlinked, err := f.d.change(context.Background(), session, raw, "unlink", proof, proof)
	if err != nil || unlinked.Account != account.Account || unlinked.Generation != 3 || len(unlinked.IdentityIDs) != 1 {
		t.Fatalf("unlink: %+v %v", unlinked, err)
	}
	binding := f.store.state.Bindings[linked.IdentityIDs[1]]
	if binding.Active || binding.AccountID != account.AccountID || len(f.store.state.Audits) != 3 {
		t.Fatal("unlink lost the immutable owner/tombstone/audit")
	}
	fresh := f.session(unlinked, 0)
	_, err = f.d.begin(context.Background(), &fresh, "unlink", f.google, unlinked.IdentityIDs[0])
	requireAuthorizationCode(t, err, "identity_last_credential")
	_, err = f.d.begin(context.Background(), &session, "link", f.apple, "")
	requireAuthorizationCode(t, err, "identity_session_invalid")

	raw, err = f.d.begin(context.Background(), nil, "register", f.apple, "")
	if err != nil {
		t.Fatal(err)
	}
	_, err = f.d.register(context.Background(), raw, f.proof(t, raw, f.apple, "apple-subject"))
	requireAuthorizationCode(t, err, "identity_already_assigned")
	relinked := f.link(t, unlinked, "apple-subject")
	if relinked.Account != account.Account || relinked.Generation != 4 {
		t.Fatal("relink changed the tombstone's owner")
	}
}

func TestIdentityDirectoryNamespaceIsolationAndNoProfilePrerequisite(t *testing.T) {
	f := newDirectoryFixture(t)
	google := f.register(t, f.google, "same-subject")
	apple := f.register(t, f.apple, "same-subject")
	if google.Account == apple.Account {
		t.Fatal("different trusted issuers/providers were merged")
	}
	other := f.google
	other.Namespace = "other-project"
	d, err := newIdentityDirectory(f.store, []identityProofTarget{other})
	if err != nil {
		t.Fatal(err)
	}
	d.now = f.d.now
	raw, err := d.begin(context.Background(), nil, "register", other, "")
	if err != nil {
		t.Fatal(err)
	}
	proof := f.proof(t, raw, other, "same-subject")
	namespaced, err := d.register(context.Background(), raw, proof)
	if err != nil || namespaced.Account == google.Account {
		t.Fatalf("client/project namespace isolation: %+v %v", namespaced, err)
	}
	for _, field := range []string{"Email", "DisplayName", "Partition", "ProviderData", "IssuedAt"} {
		if _, exists := reflect.TypeFor[verifiedDirectoryProof]().FieldByName(field); exists {
			t.Fatalf("untrusted profile/iat ownership input added: %s", field)
		}
	}
}

func TestIdentityDirectoryFreshProofAndCallbackRejectionIsAtomic(t *testing.T) {
	for _, name := range []string{"missing-auth-time", "old-auth-time", "future-auth-time", "pre-challenge-auth",
		"expired-proof", "wrong-challenge", "wrong-callback", "wrong-client", "wrong-provider", "wrong-namespace", "missing-digest", "same-proof"} {
		t.Run(name, func(t *testing.T) {
			f := newDirectoryFixture(t)
			account := f.register(t, f.google, "owner")
			session := f.session(account, 0)
			raw, err := f.d.begin(context.Background(), &session, "link", f.apple, "")
			if err != nil {
				t.Fatal(err)
			}
			old := f.proof(t, raw, f.google, "owner")
			next := f.proof(t, raw, f.apple, "new-identity")
			switch name {
			case "missing-auth-time":
				old.AuthenticatedAt = time.Time{}
			case "old-auth-time":
				old.AuthenticatedAt = f.now.Add(-identityChallengeLifetime)
			case "future-auth-time":
				next.AuthenticatedAt = f.now.Add(time.Second)
			case "pre-challenge-auth":
				old.AuthenticatedAt = f.now.Add(-time.Second)
			case "expired-proof":
				next.ExpiresAt = f.now
			case "wrong-challenge":
				next.ChallengeDigest = namespacedID("wrong")
			case "wrong-callback":
				next.Target.Callback = "https://attacker.invalid/return"
			case "wrong-client":
				next.Target.ClientID = "other-client"
			case "wrong-provider":
				next.Target.Provider = "google"
			case "wrong-namespace":
				next.Target.Namespace = "other-project"
			case "missing-digest":
				next.ProofDigest = ""
			case "same-proof":
				next.ProofDigest = old.ProofDigest
			}
			before, writes := cloneTestDirectory(f.store.state), f.store.writes
			_, err = f.d.change(context.Background(), session, raw, "link", old, next)
			requireAuthorizationCode(t, err, "identity_fresh_proof_required")
			if f.store.writes != writes || !reflect.DeepEqual(before, f.store.state) {
				t.Fatal("rejected proof partially consumed a challenge or changed ownership")
			}
		})
	}
}

func TestIdentityDirectoryExpiryAndReplay(t *testing.T) {
	f := newDirectoryFixture(t)
	account := f.register(t, f.google, "owner")
	session := f.session(account, 0)
	raw, err := f.d.begin(context.Background(), &session, "link", f.apple, "")
	if err != nil {
		t.Fatal(err)
	}
	old, next := f.proof(t, raw, f.google, "owner"), f.proof(t, raw, f.apple, "new")
	f.now = f.now.Add(identityChallengeLifetime)
	_, err = f.d.change(context.Background(), session, raw, "link", old, next)
	requireAuthorizationCode(t, err, "identity_challenge_invalid")

	raw, err = f.d.begin(context.Background(), &session, "link", f.apple, "")
	if err != nil {
		t.Fatal(err)
	}
	old, next = f.proof(t, raw, f.google, "owner"), f.proof(t, raw, f.apple, "new")
	linked, err := f.d.change(context.Background(), session, raw, "link", old, next)
	if err != nil {
		t.Fatal(err)
	}
	fresh := f.session(linked, 0)
	_, err = f.d.change(context.Background(), fresh, raw, "link", old, next)
	requireAuthorizationCode(t, err, "identity_challenge_invalid")
	raw2, err := f.d.begin(context.Background(), &fresh, "link", f.apple, "")
	if err != nil {
		t.Fatal(err)
	}
	current := f.proof(t, raw2, f.google, "owner")
	proposed := f.proof(t, raw2, f.apple, "another")
	current.ProofDigest = old.ProofDigest
	_, err = f.d.change(context.Background(), fresh, raw2, "link", current, proposed)
	requireAuthorizationCode(t, err, "identity_proof_replayed")
	if len(f.store.state.Audits) != 2 || len(f.store.state.Bindings) != 2 {
		t.Fatal("replay created a second binding/audit")
	}
}

func TestIdentityDirectoryChallengeAccountSessionAndOperationBinding(t *testing.T) {
	f := newDirectoryFixture(t)
	first := f.register(t, f.google, "first")
	second := f.register(t, f.google, "second")
	session, other := f.session(first, 0), f.session(second, 0)
	raw, err := f.d.begin(context.Background(), &session, "link", f.apple, "")
	if err != nil {
		t.Fatal(err)
	}
	_, err = f.d.change(context.Background(), other, raw, "link",
		f.proof(t, raw, f.google, "second"), f.proof(t, raw, f.apple, "new"))
	requireAuthorizationCode(t, err, "identity_challenge_invalid")
	_, err = f.d.change(context.Background(), session, raw, "unlink",
		f.proof(t, raw, f.google, "first"), f.proof(t, raw, f.apple, "new"))
	requireAuthorizationCode(t, err, "identity_challenge_invalid")
	wrongIdentity := session
	wrongIdentity.IdentityID = second.IdentityIDs[0]
	_, err = f.d.begin(context.Background(), &wrongIdentity, "link", f.apple, "")
	requireAuthorizationCode(t, err, "identity_session_invalid")
	_, err = f.d.change(context.Background(), session, raw, "link",
		f.proof(t, raw, f.google, "second"), f.proof(t, raw, f.apple, "new"))
	requireAuthorizationCode(t, err, "identity_fresh_proof_required")
}

func TestIdentityDirectoryConcurrentIdentityHasExactlyOneOwner(t *testing.T) {
	f := newDirectoryFixture(t)
	accounts := []directoryAccount{f.register(t, f.google, "first"), f.register(t, f.google, "second")}
	type attempt struct {
		session directorySession
		raw     string
		old     verifiedDirectoryProof
		next    verifiedDirectoryProof
	}
	attempts := make([]attempt, len(accounts))
	for i, account := range accounts {
		session := f.session(account, 0)
		raw, err := f.d.begin(context.Background(), &session, "link", f.apple, "")
		if err != nil {
			t.Fatal(err)
		}
		subject := f.store.state.Bindings[session.IdentityID].Identity.Subject
		attempts[i] = attempt{session, raw, f.proof(t, raw, f.google, subject), f.proof(t, raw, f.apple, "contested")}
	}
	start := make(chan struct{})
	results := make(chan error, len(attempts))
	for _, item := range attempts {
		go func() {
			<-start
			_, err := f.d.change(context.Background(), item.session, item.raw, "link", item.old, item.next)
			results <- err
		}()
	}
	close(start)
	successes := 0
	for range attempts {
		err := <-results
		if err == nil {
			successes++
		} else {
			requireAuthorizationCode(t, err, "identity_already_assigned")
		}
	}
	if successes != 1 || len(f.store.state.Bindings) != 3 || len(f.store.state.Audits) != 3 {
		t.Fatalf("nonunique/partial concurrent assignment: successes=%d", successes)
	}
}

func TestIdentityDirectoryConcurrentChallengeIsSingleUse(t *testing.T) {
	f := newDirectoryFixture(t)
	account := f.register(t, f.google, "owner")
	session := f.session(account, 0)
	raw, err := f.d.begin(context.Background(), &session, "link", f.apple, "")
	if err != nil {
		t.Fatal(err)
	}
	old, next := f.proof(t, raw, f.google, "owner"), f.proof(t, raw, f.apple, "new")
	start, results := make(chan struct{}), make(chan error, 16)
	for range 16 {
		go func() {
			<-start
			_, err := f.d.change(context.Background(), session, raw, "link", old, next)
			results <- err
		}()
	}
	close(start)
	successes := 0
	for range 16 {
		err := <-results
		if err == nil {
			successes++
		} else {
			var failure *ProtocolError
			if !errors.As(err, &failure) || failure.Code != "identity_session_invalid" {
				t.Fatalf("unexpected replay error: %v", err)
			}
		}
	}
	if successes != 1 || len(f.store.state.Audits) != 2 || len(f.store.state.Proofs) != 3 {
		t.Fatalf("challenge assigned more than once: successes=%d", successes)
	}
}

func TestIdentityDirectoryRetainedCapacityAndCredentialLimits(t *testing.T) {
	f := newDirectoryFixture(t)
	account := f.register(t, f.google, "owner")
	for i := 1; i < maxAccountIdentities; i++ {
		account = f.link(t, account, fmt.Sprint(i))
	}
	session := f.session(account, 0)
	raw, err := f.d.begin(context.Background(), &session, "link", f.apple, "")
	if err != nil {
		t.Fatal(err)
	}
	_, err = f.d.change(context.Background(), session, raw, "link",
		f.proof(t, raw, f.google, "owner"), f.proof(t, raw, f.apple, "overflow"))
	requireAuthorizationCode(t, err, "identity_credential_limit")
	for i := 1; i < maxNormalIdentityChallenges; i++ {
		if _, err := f.d.begin(context.Background(), &session, "link", f.apple, ""); err != nil {
			t.Fatal(err)
		}
	}
	_, err = f.d.begin(context.Background(), &session, "link", f.apple, "")
	requireAuthorizationCode(t, err, "identity_challenge_limit")

	full := newDirectoryFixture(t)
	full.store.state = emptyIdentityDirectory()
	full.store.state.Revision = 1
	for i := range maxIdentityChallenges {
		full.store.state.Challenges[namespacedID("retained", fmt.Sprint(i))] = directoryChallenge{
			Operation: "register", Target: full.google, IssuedAt: full.now, ExpiresAt: full.now.Add(identityChallengeLifetime)}
	}
	if !validIdentityDirectory(full.store.state) {
		t.Fatal("capacity fixture must be valid")
	}
	_, err = full.d.begin(context.Background(), nil, "register", full.google, "")
	requireAuthorizationCode(t, err, "identity_directory_capacity_exceeded")
	if full.store.writes != 0 || len(full.store.state.Challenges) != maxIdentityChallenges {
		t.Fatal("capacity rejection partially wrote")
	}
}

func TestIdentityDirectorySerializedByteLimitIsMeasuredBeforeWrite(t *testing.T) {
	f := newDirectoryFixture(t)
	target := f.google
	target.Callback = "https://callback.invalid/" + strings.Repeat("x", 2000)
	f.d.targets[target] = true
	state := emptyIdentityDirectory()
	state.Revision = 1
	for i := range maxIdentityChallenges {
		id := namespacedID("large-challenge", fmt.Sprint(i))
		state.Challenges[id] = directoryChallenge{Operation: "register", Target: target,
			IssuedAt: f.now, ExpiresAt: f.now.Add(identityChallengeLifetime)}
		body, err := encodeJSON(state)
		if err != nil {
			t.Fatal(err)
		}
		if len(body) > maxIdentityDirectoryBytes {
			delete(state.Challenges, id)
			break
		}
	}
	if !validIdentityDirectory(state) || len(state.Challenges) >= maxIdentityChallenges {
		t.Fatal("byte-bound fixture must hit the byte limit before the row count")
	}
	f.store.state = state
	before, _ := encodeJSON(state)
	_, err := f.d.begin(context.Background(), nil, "register", target, "")
	requireAuthorizationCode(t, err, "identity_directory_capacity_exceeded")
	after, _ := encodeJSON(f.store.state)
	if string(before) != string(after) || f.store.writes != 0 {
		t.Fatal("serialized byte overflow partially changed persisted state")
	}
}

func TestIdentityDirectoryRetriesAndUnknownWriteOutcome(t *testing.T) {
	f := newDirectoryFixture(t)
	f.store.conflicts = 2
	raw, err := f.d.begin(context.Background(), nil, "register", f.google, "")
	if err != nil || f.store.loads != 3 || f.store.writes != 1 {
		t.Fatalf("bounded CAS retry: %v", err)
	}
	encoded, _ := encodeJSON(f.store.state)
	if strings.Contains(string(encoded), raw) {
		t.Fatal("plaintext challenge was retained")
	}
	proof := f.proof(t, raw, f.google, "owner")
	f.store.ambiguousNext = true
	account, err := f.d.register(context.Background(), raw, proof)
	requireAuthorizationCode(t, err, "batch_failed")
	if !reflect.DeepEqual(account, directoryAccount{}) {
		t.Fatal("ambiguous outcome returned success-shaped account")
	}
	writes := f.store.writes
	_, err = f.d.register(context.Background(), raw, proof)
	requireAuthorizationCode(t, err, "identity_challenge_invalid")
	if f.store.writes != writes || len(f.store.state.Accounts) != 1 || len(f.store.state.Audits) != 1 {
		t.Fatal("unknown commit outcome allowed a second assignment")
	}

	f.store.conflicts = 8
	_, err = f.d.begin(context.Background(), nil, "register", f.apple, "")
	requireAuthorizationCode(t, err, "identity_directory_contention")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	loads := f.store.loads
	_, err = f.d.begin(ctx, nil, "register", f.apple, "")
	if err != context.Canceled || f.store.loads != loads {
		t.Fatal("cancelled operation performed storage I/O")
	}
}

func TestIdentityDirectoryCorruptStateAndConfigurationFailClosed(t *testing.T) {
	for _, name := range []string{"wrong-scope", "wrong-owner", "missing-audit", "missing-proof", "active-tombstone", "invalid-generation"} {
		t.Run(name, func(t *testing.T) {
			f := newDirectoryFixture(t)
			account := f.register(t, f.google, "owner")
			switch name {
			case "wrong-scope":
				account.PersonalScopeID = namespacedID("wrong")
				f.store.state.Accounts[account.AccountID] = account
			case "wrong-owner":
				binding := f.store.state.Bindings[account.IdentityIDs[0]]
				binding.AccountID = namespacedID("wrong")
				f.store.state.Bindings[account.IdentityIDs[0]] = binding
			case "missing-audit":
				f.store.state.Audits = []directoryAudit{}
			case "missing-proof":
				f.store.state.Proofs = map[string]string{}
			case "active-tombstone":
				binding := f.store.state.Bindings[account.IdentityIDs[0]]
				binding.Active = false
				f.store.state.Bindings[account.IdentityIDs[0]] = binding
			case "invalid-generation":
				account.Generation = 0
				f.store.state.Accounts[account.AccountID] = account
			}
			writes := f.store.writes
			_, err := f.d.begin(context.Background(), nil, "register", f.apple, "")
			requireAuthorizationCode(t, err, "identity_directory_unavailable")
			if f.store.writes != writes {
				t.Fatal("corruption was silently repaired")
			}
		})
	}
	f := newDirectoryFixture(t)
	for _, callback := range []string{"http://remote.invalid/callback", "javascript://callback.invalid/x",
		"https://secret@callback.invalid/x", "https://callback.invalid/x?code=secret", "https://callback.invalid/x#fragment"} {
		target := f.google
		target.Callback = callback
		_, err := newIdentityDirectory(f.store, []identityProofTarget{target})
		requireAuthorizationCode(t, err, "invalid_identity_configuration")
	}
	_, err := newIdentityDirectory(f.store, []identityProofTarget{f.google, f.google})
	requireAuthorizationCode(t, err, "invalid_identity_configuration")
	f.d.entropy = strings.NewReader("")
	_, err = f.d.begin(context.Background(), nil, "register", f.google, "")
	requireAuthorizationCode(t, err, "identity_entropy_unavailable")
}

func TestCosmosIdentityDirectoryWireIsSinglePartitionConditionalAndSessionBound(t *testing.T) {
	var saved *storedItem
	batches := 0
	cosmos := testCosmos(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/" || r.URL.Path == "" {
			return cosmosResponse(r, 200, authorizationTestAccountMetadata, ""), nil
		}
		if r.Header.Get("x-ms-documentdb-partitionkey") != `["`+identityDirectoryPartition+`"]` {
			t.Fatal("identity directory crossed its intentional logical partition")
		}
		if r.Method == http.MethodGet {
			response := authorizationItemResponse(t, r, saved, "directory-read")
			response.Header.Set("Etag", `"directory-etag"`)
			return response, nil
		}
		if r.Header.Get("x-ms-session-token") != "directory-read" {
			t.Fatal("directory commit lost the request-local authorization session")
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatal(err)
		}
		var operations []struct {
			Operation string     `json:"operationType"`
			ETag      string     `json:"ifMatch"`
			Item      storedItem `json:"resourceBody"`
		}
		if json.Unmarshal(body, &operations) != nil || len(operations) != 1 ||
			operations[0].Item.ScopeID != identityDirectoryPartition || operations[0].Item.ID != identityDirectoryItemID {
			t.Fatal("directory transaction must atomically replace one bounded record")
		}
		if batches == 0 {
			if operations[0].Operation != "Create" || operations[0].ETag != "" {
				t.Fatal("initial directory must use an exclusive create")
			}
		} else if operations[0].Operation != "Replace" || operations[0].ETag != `"directory-etag"` {
			t.Fatal("directory replacement lacks the actual read ETag fence")
		}
		if !validIdentityDirectory(operations[0].Item.IdentityDirectory) {
			t.Fatal("invalid persisted directory")
		}
		saved = &operations[0].Item
		batches++
		return cosmosResponse(r, 200, `[{"statusCode":201}]`, "directory-write"), nil
	})
	f := newDirectoryFixture(t)
	f.d.store = cosmosIdentityDirectoryStore{cosmos}
	f.register(t, f.google, "owner")
	if batches != 2 || len(saved.IdentityDirectory.Accounts) != 1 || len(saved.IdentityDirectory.Audits) != 1 {
		t.Fatal("registration was not atomic within the directory boundary")
	}
}
