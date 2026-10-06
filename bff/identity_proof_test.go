package syncbff

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

type directoryProofFixture struct {
	server   *httptest.Server
	now      time.Time
	target   identityProofTarget
	verifier *directoryProofVerifier
	keys     []*rsa.PrivateKey
	mu       sync.Mutex
	active   int
	failKeys bool
	redirect string
	hits     int
}

func newDirectoryProofFixture(t *testing.T) *directoryProofFixture {
	t.Helper()
	f := &directoryProofFixture{now: time.Now().UTC().Truncate(time.Second)}
	for range 2 {
		key, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			t.Fatal(err)
		}
		f.keys = append(f.keys, key)
	}
	f.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.hits++
		if r.URL.Path != "/jwks" {
			http.NotFound(w, r)
			return
		}
		if f.redirect != "" {
			http.Redirect(w, r, f.redirect, http.StatusTemporaryRedirect)
			return
		}
		if f.failKeys {
			http.Error(w, "fixture keys unavailable", http.StatusServiceUnavailable)
			return
		}
		key := f.keys[f.active]
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]any{
			"kty": "RSA", "kid": f.keyID(f.active), "alg": "RS256", "use": "sig",
			"n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
			"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
		}}})
	}))
	t.Cleanup(f.server.Close)
	f.target = identityProofTarget{f.server.URL, "entra", "signed-fixture-only", "native-proof-fixture", "com.anaregdesign.cosmossync://auth/oauthredirect"}
	var err error
	f.verifier, err = newDirectoryProofVerifier(oidc.ClientContext(context.Background(), f.server.Client()), f.target, f.server.URL+"/jwks")
	if err != nil {
		t.Fatal(err)
	}
	f.verifier.now = func() time.Time { return f.now }
	return f
}

func (f *directoryProofFixture) keyID(index int) string {
	if index == 0 {
		return "proof-key-a"
	}
	return "proof-key-b"
}

func (f *directoryProofFixture) token(t *testing.T, challenge string, changes, headerChanges map[string]any, keyIndex int) string {
	t.Helper()
	claims := map[string]any{
		"iss": f.target.Issuer, "aud": f.target.ClientID, "sub": "signed-subject",
		"nonce": challenge, "auth_time": f.now.Unix(), "iat": f.now.Unix(), "nbf": f.now.Unix(), "exp": f.now.Add(time.Hour).Unix(),
	}
	header := map[string]any{"alg": "RS256", "typ": "JWT", "kid": f.keyID(keyIndex)}
	for _, pair := range []struct {
		target  map[string]any
		changes map[string]any
	}{{claims, changes}, {header, headerChanges}} {
		for name, value := range pair.changes {
			if value == nil {
				delete(pair.target, name)
			} else {
				pair.target[name] = value
			}
		}
	}
	encode := func(value any) string {
		body, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		return base64.RawURLEncoding.EncodeToString(body)
	}
	unsigned := encode(header) + "." + encode(claims)
	digest := sha256.Sum256([]byte(unsigned))
	signature, err := rsa.SignPKCS1v15(rand.Reader, f.keys[keyIndex], crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return unsigned + "." + base64.RawURLEncoding.EncodeToString(signature)
}

func TestDirectorySignedProofFailsClosed(t *testing.T) {
	f := newDirectoryProofFixture(t)
	challenge := strings.Repeat("a", 64)
	valid := f.token(t, challenge, nil, nil, 0)
	proof, err := f.verifier.verify(context.Background(), valid, challenge)
	if err != nil || proof.Target != f.target || proof.Subject != "signed-subject" || proof.AuthenticatedAt != f.now {
		t.Fatal("approved signed nonce-bound proof rejected", err)
	}
	cases := []struct {
		name   string
		claims map[string]any
		header map[string]any
	}{
		{"wrong issuer", map[string]any{"iss": "https://other-issuer.invalid"}, nil},
		{"API audience", map[string]any{"aud": "sync-api-not-native-proof"}, nil},
		{"multiple audiences", map[string]any{"aud": []string{f.target.ClientID, "another-client"}}, nil},
		{"absent subject", map[string]any{"sub": nil}, nil},
		{"invalid subject", map[string]any{"sub": " subject\n"}, nil},
		{"absent nonce", map[string]any{"nonce": nil}, nil},
		{"wrong nonce", map[string]any{"nonce": strings.Repeat("b", 64)}, nil},
		{"structured nonce", map[string]any{"nonce": []string{challenge}}, nil},
		{"absent auth time", map[string]any{"auth_time": nil}, nil},
		{"string auth time", map[string]any{"auth_time": "1800000000"}, nil},
		{"fractional auth time", map[string]any{"auth_time": float64(f.now.Unix()) + 0.5}, nil},
		{"null auth time", map[string]any{"auth_time": json.RawMessage("null")}, nil},
		{"future auth time", map[string]any{"auth_time": f.now.Add(time.Second).Unix()}, nil},
		{"auth after issuance", map[string]any{"iat": f.now.Add(-time.Second).Unix()}, nil},
		{"stale auth at boundary", map[string]any{"auth_time": f.now.Add(-identityChallengeLifetime).Unix()}, nil},
		{"refresh is not reauth", map[string]any{"auth_time": f.now.Add(-time.Hour).Unix()}, nil},
		{"absent issuance", map[string]any{"iat": nil}, nil},
		{"future issuance", map[string]any{"iat": f.now.Add(time.Second).Unix()}, nil},
		{"expired", map[string]any{"exp": f.now.Unix()}, nil},
		{"string expiry", map[string]any{"exp": "1800000000"}, nil},
		{"future not before", map[string]any{"nbf": f.now.Add(time.Second).Unix()}, nil},
		{"null not before", map[string]any{"nbf": json.RawMessage("null")}, nil},
		{"API scope", map[string]any{"scp": "Cosmos.Sync"}, nil},
		{"empty scope still access", map[string]any{"scope": ""}, nil},
		{"access purpose", map[string]any{"token_use": "access"}, nil},
		{"wrong signed client", map[string]any{"azp": "another-client"}, nil},
		{"structured signed client", map[string]any{"azp": []string{f.target.ClientID}}, nil},
		{"access header", nil, map[string]any{"typ": "at+jwt"}},
		{"absent key ID", nil, map[string]any{"kid": nil}},
		{"unknown key", nil, map[string]any{"kid": "unknown-key"}},
		{"HMAC confusion", nil, map[string]any{"alg": "HS256"}},
		{"unsigned algorithm", nil, map[string]any{"alg": "none"}},
	}
	_, err = f.verifier.verify(context.Background(), f.token(t, challenge, nil, map[string]any{"kid": f.keyID(0)}, 1), challenge)
	requireAuthorizationCode(t, err, "identity_fresh_proof_required")
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			raw := f.token(t, challenge, test.claims, test.header, 0)
			proof, err := f.verifier.verify(context.Background(), raw, challenge)
			requireAuthorizationCode(t, err, "identity_fresh_proof_required")
			if proof != (verifiedDirectoryProof{}) || strings.Contains(err.Error(), raw) {
				t.Fatal("rejection returned proof or raw credential")
			}
		})
	}
	for _, raw := range []string{"", "not-a-jwt", valid + "x", strings.Repeat("x", maxDirectoryProofBytes+1)} {
		_, err := f.verifier.verify(context.Background(), raw, challenge)
		requireAuthorizationCode(t, err, "identity_fresh_proof_required")
	}
	_, err = f.verifier.verify(context.Background(), valid, "not-a-server-challenge")
	requireAuthorizationCode(t, err, "identity_fresh_proof_required")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = f.verifier.verify(ctx, valid, challenge)
	if !errors.Is(err, context.Canceled) {
		t.Fatal("context cancellation was hidden", err)
	}
}

func TestDirectoryProofKeyRotationFailureAndRedirect(t *testing.T) {
	f := newDirectoryProofFixture(t)
	challenge := strings.Repeat("a", 64)
	if _, err := f.verifier.verify(context.Background(), f.token(t, challenge, nil, nil, 0), challenge); err != nil {
		t.Fatal(err)
	}
	f.mu.Lock()
	f.active = 1
	f.mu.Unlock()
	if _, err := f.verifier.verify(context.Background(), f.token(t, challenge, nil, nil, 1), challenge); err != nil {
		t.Fatal("approved JWKS rotation failed", err)
	}
	f.mu.Lock()
	f.failKeys = true
	f.mu.Unlock()
	_, err := f.verifier.verify(context.Background(), f.token(t, challenge, nil, map[string]any{"kid": "unavailable-new-key"}, 1), challenge)
	requireAuthorizationCode(t, err, "identity_fresh_proof_required")

	destinationHits := 0
	destination := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { destinationHits++ }))
	defer destination.Close()
	f.mu.Lock()
	f.failKeys, f.redirect = false, destination.URL
	f.mu.Unlock()
	_, err = f.verifier.verify(context.Background(), f.token(t, challenge, nil, map[string]any{"kid": "redirect-key"}, 1), challenge)
	requireAuthorizationCode(t, err, "identity_fresh_proof_required")
	if destinationHits != 0 {
		t.Fatal("pinned key source followed a redirect")
	}
	f.mu.Lock()
	hits := f.hits
	f.mu.Unlock()
	if hits != 4 {
		t.Fatalf("key rotation/failure was not one bounded fetch per unknown key: %d", hits)
	}
}

func TestDirectoryProofConfigurationRejectsUnapprovedKeyLocations(t *testing.T) {
	target := identityProofTarget{"https://issuer.invalid", "entra", "consumer-v1", "native-client", "https://app.invalid/callback"}
	for _, keys := range []string{"", "http://keys.invalid/jwks", "https://user:secret@keys.invalid/jwks",
		"https://keys.invalid/jwks?unapproved=1", "https://keys.invalid/jwks#fragment", "https://keys.invalid/\n"} {
		_, err := newDirectoryProofVerifier(context.Background(), target, keys)
		requireAuthorizationCode(t, err, "invalid_identity_configuration")
	}
	target.Provider = "client-chosen-provider"
	_, err := newDirectoryProofVerifier(context.Background(), target, "https://keys.invalid/jwks")
	requireAuthorizationCode(t, err, "invalid_identity_configuration")
}

func TestDirectoryCryptographicProofRegistersLinksAndCannotReplay(t *testing.T) {
	f := newDirectoryProofFixture(t)
	d, err := newIdentityDirectory(&testIdentityDirectoryStore{}, []identityProofTarget{f.target})
	if err != nil {
		t.Fatal(err)
	}
	d.now = func() time.Time { return f.now }
	ctx := context.Background()
	raw, err := d.begin(ctx, nil, "register", f.target, "")
	if err != nil {
		t.Fatal(err)
	}
	first, err := f.verifier.verify(ctx, f.token(t, raw, map[string]any{"email": "equal-email@fixture.invalid"}, nil, 0), raw)
	if err != nil {
		t.Fatal(err)
	}
	account, err := d.register(ctx, raw, first)
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.register(ctx, raw, first)
	requireAuthorizationCode(t, err, "identity_challenge_invalid")
	session := directorySession{account.AccountID, account.Generation, account.IdentityIDs[0], f.now.Add(time.Hour)}
	link, err := d.begin(ctx, &session, "link", f.target, "")
	if err != nil {
		t.Fatal(err)
	}
	_, err = f.verifier.verify(ctx, f.token(t, raw, nil, nil, 0), link)
	requireAuthorizationCode(t, err, "identity_fresh_proof_required")
	current, err := f.verifier.verify(ctx, f.token(t, link, nil, nil, 0), link)
	if err != nil {
		t.Fatal(err)
	}
	newIdentity, err := f.verifier.verify(ctx, f.token(t, link, map[string]any{
		"sub": "independent-subject", "email": "equal-email@fixture.invalid",
	}, nil, 0), link)
	if err != nil {
		t.Fatal(err)
	}
	linked, err := d.change(ctx, session, link, "link", current, newIdentity)
	if err != nil || linked.Account != account.Account || linked.Generation != 2 || len(linked.IdentityIDs) != 2 {
		t.Fatal("signed explicit link changed ownership or failed", err)
	}
	_, err = d.begin(ctx, &session, "link", f.target, "")
	requireAuthorizationCode(t, err, "identity_session_invalid")
	session.Generation = linked.Generation
	unlink, err := d.begin(ctx, &session, "unlink", f.target, newIdentity.identity().id())
	if err != nil {
		t.Fatal(err)
	}
	retained, err := f.verifier.verify(ctx, f.token(t, unlink, nil, nil, 0), unlink)
	if err != nil {
		t.Fatal(err)
	}
	unlinked, err := d.change(ctx, session, unlink, "unlink", retained, retained)
	if err != nil || unlinked.Account != account.Account || len(unlinked.IdentityIDs) != 1 {
		t.Fatal("signed unlink failed or changed ownership", err)
	}
	raw, err = d.begin(ctx, nil, "register", f.target, "")
	if err != nil {
		t.Fatal(err)
	}
	other, err := f.verifier.verify(ctx, f.token(t, raw, map[string]any{
		"sub": "same-email-separate-account", "email": "equal-email@fixture.invalid",
	}, nil, 0), raw)
	if err != nil {
		t.Fatal(err)
	}
	separate, err := d.register(ctx, raw, other)
	if err != nil || separate.AccountID == account.AccountID {
		t.Fatal("equal email implicitly merged signed identities", err)
	}
	raw, err = d.begin(ctx, nil, "register", f.target, "")
	if err != nil {
		t.Fatal(err)
	}
	removed, err := f.verifier.verify(ctx, f.token(t, raw, map[string]any{"sub": "independent-subject"}, nil, 0), raw)
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.register(ctx, raw, removed)
	requireAuthorizationCode(t, err, "identity_already_assigned")
}
