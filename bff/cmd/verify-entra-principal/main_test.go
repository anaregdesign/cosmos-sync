package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
	"github.com/coreos/go-oidc/v3/oidc"
)

// All identities below are synthetic, local-only signer fixtures.
const (
	testTenant = "11111111-1111-4111-8111-111111111111"
	testOwner  = "22222222-2222-4222-8222-222222222222"
	testAPI    = "33333333-3333-4333-8333-333333333333"
	testNative = "44444444-4444-4444-8444-444444444444"
	testOther  = "55555555-5555-4555-8555-555555555555"
)

type signerFixture struct {
	server *httptest.Server
	key    *rsa.PrivateKey
	ctx    context.Context
	config syncbff.OIDCConfig
}

func fixture(t *testing.T) *signerFixture {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	f := &signerFixture{key: key}
	f.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Token verification must never send a bearer token or credentials.
		if r.Method != http.MethodGet || r.Header.Get("Authorization") != "" || r.URL.RawQuery != "" {
			t.Error("discovery request unexpectedly included credentials")
			http.Error(w, "rejected", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/.well-known/openid-configuration":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"issuer": f.config.Issuer, "jwks_uri": f.server.URL + "/jwks",
				"authorization_endpoint": f.server.URL + "/authorize", "token_endpoint": f.server.URL + "/token",
				"id_token_signing_alg_values_supported": []string{"RS256"},
			})
		case "/jwks":
			_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]any{
				"kty": "RSA", "kid": "local-key", "alg": "RS256", "use": "sig",
				"n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
				"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
			}}})
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(f.server.Close)
	f.ctx = oidc.ClientContext(context.Background(), f.server.Client())
	f.config = syncbff.OIDCConfig{Issuer: f.server.URL, Audience: testAPI, TenantClaim: "tid", RequiredScope: requiredScope}
	return f
}

func (f *signerFixture) token(t *testing.T, overrides map[string]any, key *rsa.PrivateKey) string {
	t.Helper()
	now := time.Now().Unix()
	claims := map[string]any{
		"iss": f.config.Issuer, "aud": testAPI, "sub": "api-specific-pairwise-subject",
		"tid": testTenant, "oid": testOwner, "ver": "2.0", "scp": requiredScope,
		"nbf": now - 60, "iat": now - 60, "exp": now + 3600,
	}
	for k, v := range overrides {
		if v == nil {
			delete(claims, k)
		} else {
			claims[k] = v
		}
	}
	encode := func(v any) string {
		data, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return base64.RawURLEncoding.EncodeToString(data)
	}
	unsigned := encode(map[string]any{"alg": "RS256", "kid": "local-key", "typ": "JWT"}) + "." + encode(claims)
	hash := sha256.Sum256([]byte(unsigned))
	if key == nil {
		key = f.key
	}
	signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, hash[:])
	if err != nil {
		t.Fatal(err)
	}
	return unsigned + "." + base64.RawURLEncoding.EncodeToString(signature)
}

func TestVerifiedEntraAPIPrincipal(t *testing.T) {
	f := fixture(t)
	verifier, err := syncbff.NewOIDCVerifier(f.ctx, f.config)
	if err != nil {
		t.Fatal(err)
	}
	owner := ownerRecord{testTenant, testOwner}
	valid := f.token(t, map[string]any{"scp": "Additional.Read " + requiredScope}, nil)
	got, err := verifyPrincipal(f.ctx, verifier, valid, owner, f.config)
	if err != nil {
		t.Fatalf("valid signed API token rejected: %v", err)
	}
	if got.Subject != "api-specific-pairwise-subject" || got.Subject == testOwner || got.OwnerObjectID != testOwner || got.TenantID != testTenant {
		t.Fatal("identity was not derived from the verified API access JWT")
	}
	wrongKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name      string
		overrides map[string]any
		key       *rsa.PrivateKey
	}{
		{"wrong signature", nil, wrongKey},
		{"ID token audience", map[string]any{"aud": testNative}, nil},
		{"mixed audiences", map[string]any{"aud": []string{testAPI, testNative}}, nil},
		{"wrong issuer", map[string]any{"iss": "https://wrong.example/v2.0"}, nil},
		{"wrong tenant", map[string]any{"tid": testOther}, nil},
		{"wrong owner", map[string]any{"oid": testOther}, nil},
		{"missing owner", map[string]any{"oid": nil}, nil},
		{"wrong version", map[string]any{"ver": "1.0"}, nil},
		{"missing scope", map[string]any{"scp": nil}, nil},
		{"application roles only", map[string]any{"scp": nil, "roles": []string{requiredScope}}, nil},
		{"scope alias only", map[string]any{"scp": nil, "scope": requiredScope}, nil},
		{"near-match scope", map[string]any{"scp": "Cosmos.Sync.Other"}, nil},
		{"scope wrong case", map[string]any{"scp": "cosmos.sync"}, nil},
		{"expired", map[string]any{"exp": time.Now().Unix() - 60}, nil},
		{"not yet valid", map[string]any{"nbf": time.Now().Unix() + 60}, nil},
		{"future issued at", map[string]any{"iat": time.Now().Unix() + 60}, nil},
		{"absent nbf", map[string]any{"nbf": nil}, nil},
		{"absent iat", map[string]any{"iat": nil}, nil},
		{"malformed nbf", map[string]any{"nbf": "tomorrow"}, nil},
		{"string numeric nbf", map[string]any{"nbf": "1700000000"}, nil},
		{"empty subject", map[string]any{"sub": ""}, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			token := f.token(t, tc.overrides, tc.key)
			got, err := verifyPrincipal(f.ctx, verifier, token, owner, f.config)
			if err == nil || got.Subject != "" {
				t.Fatal("invalid API identity accepted")
			}
			for _, private := range []string{token, testTenant, testOwner, testAPI, "wrong.example", "tomorrow"} {
				if strings.Contains(err.Error(), private) {
					t.Fatal("failure leaked token, claims, or provider details")
				}
			}
		})
	}
}

func validReceipt() (ownerRecord, registrationReceipt) {
	owner := ownerRecord{testTenant, testOwner}
	var receipt registrationReceipt
	receipt.TenantID, receipt.OwnerObjectID, receipt.ConfigurationVerified = testTenant, testOwner, true
	receipt.API.AppID, receipt.Native.AppID = testAPI, testNative
	receipt.OIDC = syncbff.OIDCConfig{
		Issuer:   "https://login.microsoftonline.com/" + testTenant + "/v2.0",
		Audience: testAPI, TenantClaim: "tid", RequiredScope: requiredScope,
	}
	return owner, receipt
}

func TestConfigurationPinsSelectedAccountAndAPIAudience(t *testing.T) {
	owner, receipt := validReceipt()
	if err := validateConfiguration(owner, receipt); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name   string
		modify func(*ownerRecord, *registrationReceipt)
	}{
		{"receipt tenant mismatch", func(_ *ownerRecord, r *registrationReceipt) { r.TenantID = testOther }},
		{"receipt owner mismatch", func(_ *ownerRecord, r *registrationReceipt) { r.OwnerObjectID = testOther }},
		{"native audience", func(_ *ownerRecord, r *registrationReceipt) { r.OIDC.Audience = testNative }},
		{"shared API and native app", func(_ *ownerRecord, r *registrationReceipt) { r.Native.AppID = testAPI }},
		{"common authority", func(_ *ownerRecord, r *registrationReceipt) {
			r.OIDC.Issuer = "https://login.microsoftonline.com/common/v2.0"
		}},
		{"unexpected tenant host", func(_ *ownerRecord, r *registrationReceipt) {
			r.OIDC.Issuer = "https://wrong.example/" + testTenant + "/v2.0"
		}},
		{"http issuer", func(_ *ownerRecord, r *registrationReceipt) {
			r.OIDC.Issuer = "http://login.microsoftonline.com/" + testTenant + "/v2.0"
		}},
		{"not v2", func(_ *ownerRecord, r *registrationReceipt) {
			r.OIDC.Issuer = "https://login.microsoftonline.com/" + testTenant
		}},
		{"scope weakening", func(_ *ownerRecord, r *registrationReceipt) { r.OIDC.RequiredScope = "" }},
		{"tenant claim weakening", func(_ *ownerRecord, r *registrationReceipt) { r.OIDC.TenantClaim = "sub" }},
		{"unverified setup", func(_ *ownerRecord, r *registrationReceipt) { r.ConfigurationVerified = false }},
		{"invalid owner identifier", func(o *ownerRecord, _ *registrationReceipt) { o.OwnerObjectID = "email@example.com" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			o, r := validReceipt()
			tc.modify(&o, &r)
			if validateConfiguration(o, r) == nil {
				t.Fatal("unsafe account or resource configuration accepted")
			}
		})
	}
}

func privateDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestPrivateFileRequirements(t *testing.T) {
	dir := privateDir(t)
	path := filepath.Join(dir, "token.local")
	if err := os.WriteFile(path, []byte("private-token"), 0600); err != nil {
		t.Fatal(err)
	}
	if got, err := readPrivateFile(path, 64); err != nil || string(got) != "private-token" {
		t.Fatalf("private regular file rejected: %v", err)
	}
	if _, err := readPrivateFile(path, 3); err == nil {
		t.Fatal("oversized token accepted")
	}
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := readPrivateFile(path, 64); err == nil {
		t.Fatal("world-readable token accepted")
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	symlink := filepath.Join(dir, "symlink")
	if err := os.Symlink(path, symlink); err != nil {
		t.Fatal(err)
	}
	if _, err := readPrivateFile(symlink, 64); err == nil {
		t.Fatal("symlink token accepted")
	}
	if _, err := readPrivateFile(dir, 64); err == nil {
		t.Fatal("directory token accepted")
	}
}

func TestPrivateExclusiveOutputsAndPublicProof(t *testing.T) {
	dir := privateDir(t)
	owner := identity{Issuer: "https://private.example", TenantID: testTenant, OwnerObjectID: testOwner, Subject: "private-subject"}
	grants := []syncbff.Grant{{Tenant: testTenant, Subject: owner.Subject, PermissionVersion: "owner-validation-v1", Active: true, CanRead: true, CanWrite: true, ScopeMode: "user"}}
	result := proof{true, true, true, true, true, true, true, true, true, true, false}
	if err := writeOutputs(dir, owner, grants, result); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"identity.local.json", "grants.proposed.local.json", "proof.json"} {
		info, err := os.Stat(filepath.Join(dir, name))
		if err != nil || info.Mode().Perm() != 0600 {
			t.Fatal("output was not created privately")
		}
	}
	data, err := os.ReadFile(filepath.Join(dir, "proof.json"))
	if err != nil {
		t.Fatal(err)
	}
	var public map[string]any
	if json.Unmarshal(data, &public) != nil || len(public) != 11 {
		t.Fatal("invalid proof")
	}
	for _, value := range public {
		if _, ok := value.(bool); !ok {
			t.Fatal("public proof contains identifying or non-boolean data")
		}
	}
	if public["grantsApplied"] != false || public["proposedSingleUserOnly"] != true {
		t.Fatal("proof misrepresented grant application")
	}
	before, _ := os.ReadFile(filepath.Join(dir, "identity.local.json"))
	if err := writeOutputs(dir, identity{Subject: "different"}, nil, proof{}); err == nil {
		t.Fatal("existing output overwritten")
	}
	after, _ := os.ReadFile(filepath.Join(dir, "identity.local.json"))
	if string(before) != string(after) {
		t.Fatal("exclusive output was modified")
	}
}

func TestOutputFailureCleansOnlyCreatedFiles(t *testing.T) {
	dir := privateDir(t)
	blocker := filepath.Join(dir, "grants.proposed.local.json")
	if err := os.WriteFile(blocker, []byte("existing"), 0600); err != nil {
		t.Fatal(err)
	}
	if writeOutputs(dir, identity{}, nil, proof{}) == nil {
		t.Fatal("existing second output accepted")
	}
	if _, err := os.Stat(filepath.Join(dir, "identity.local.json")); !os.IsNotExist(err) {
		t.Fatal("partial sensitive output was not removed")
	}
	data, _ := os.ReadFile(blocker)
	if string(data) != "existing" {
		t.Fatal("preexisting output was removed or changed")
	}
	if err := os.Chmod(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if writeOutputs(dir, identity{}, nil, proof{}) == nil {
		t.Fatal("non-private directory accepted")
	}
}

type localProviderTransport struct {
	base   http.RoundTripper
	source *url.URL
	target *url.URL
}

func (rt localProviderTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.URL.Scheme != "https" || req.Method != http.MethodGet || req.Header.Get("Authorization") != "" {
		return nil, fmt.Errorf("test prohibited an authenticated or non-HTTPS provider request")
	}
	clone := req.Clone(req.Context())
	u := *req.URL
	if u.Host == rt.source.Host {
		u.Host = rt.target.Host
		u.Path = strings.TrimPrefix(u.Path, rt.source.Path)
		clone.Host = rt.target.Host
	} else if u.Host != rt.target.Host {
		return nil, fmt.Errorf("test prohibited external network access")
	}
	clone.URL = &u
	return rt.base.RoundTrip(clone)
}

func TestRunProducesOnlyProposedVerifiedOwnerGrant(t *testing.T) {
	f := fixture(t)
	owner, receipt := validReceipt()
	f.config = receipt.OIDC
	source, _ := url.Parse(f.config.Issuer)
	target, _ := url.Parse(f.server.URL)
	client := f.server.Client()
	client.Transport = localProviderTransport{base: client.Transport, source: source, target: target}
	ctx := oidc.ClientContext(context.Background(), client)
	dir := privateDir(t)
	write := func(name string, value any) string {
		t.Helper()
		data, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	opts := options{
		OwnerFile: write("owner.local.json", owner), ReceiptFile: write("receipt.local.json", receipt),
		TokenFile: filepath.Join(dir, "token.local"), OutputDir: privateDir(t), PermissionVersion: "approved-owner-v1",
	}
	token := f.token(t, nil, nil)
	if err := os.WriteFile(opts.TokenFile, []byte(token+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	result, err := run(ctx, opts)
	if err != nil || !result.VerifiedSelectedOwner || result.GrantsApplied {
		t.Fatalf("private verification workflow failed: %v", err)
	}
	grantBytes, err := os.ReadFile(filepath.Join(opts.OutputDir, "grants.proposed.local.json"))
	if err != nil {
		t.Fatal(err)
	}
	var grants []syncbff.Grant
	if json.Unmarshal(grantBytes, &grants) != nil || len(grants) != 1 {
		t.Fatal("output did not contain exactly one user grant")
	}
	grant := grants[0]
	if grant.Tenant != owner.TenantID || grant.Subject != "api-specific-pairwise-subject" ||
		grant.PermissionVersion != opts.PermissionVersion || grant.ScopeMode != "user" ||
		!grant.Active || !grant.CanRead || !grant.CanWrite {
		t.Fatal("proposed grant did not match the approved verified principal")
	}
	for _, name := range []string{"identity.local.json", "grants.proposed.local.json", "proof.json"} {
		data, err := os.ReadFile(filepath.Join(opts.OutputDir, name))
		if err != nil || strings.Contains(string(data), token) {
			t.Fatal("output leaked the API access token")
		}
	}
	// A different signed user is rejected before any output is created.
	opts.OutputDir = privateDir(t)
	if err := os.WriteFile(opts.TokenFile, []byte(f.token(t, map[string]any{"oid": testOther}, nil)), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := run(ctx, opts); err == nil {
		t.Fatal("unapproved user accepted by full workflow")
	}
	entries, _ := os.ReadDir(opts.OutputDir)
	if len(entries) != 0 {
		t.Fatal("rejected user produced private outputs")
	}
}
