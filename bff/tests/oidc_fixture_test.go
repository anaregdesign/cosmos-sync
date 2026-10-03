package integration

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
	"github.com/coreos/go-oidc/v3/oidc"
)

const testAudience = "cosmos-sync-integration-api"

// oidcIssuer serves a real TLS discovery document and JWKS. The BFF still verifies
// RSA signatures, audience, issuer, and lifetime; tests do not bypass authentication.
type oidcIssuer struct {
	server   *httptest.Server
	key      *rsa.PrivateKey
	jwksHits atomic.Int64
}

func newOIDCIssuer(t *testing.T) *oidcIssuer {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	issuer := &oidcIssuer{key: key}
	issuer.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/.well-known/openid-configuration":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"issuer":                                issuer.server.URL,
				"jwks_uri":                              issuer.server.URL + "/jwks",
				"authorization_endpoint":                issuer.server.URL + "/authorize",
				"token_endpoint":                        issuer.server.URL + "/token",
				"id_token_signing_alg_values_supported": []string{"RS256"},
			})
		case "/jwks":
			issuer.jwksHits.Add(1)
			_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]any{
				"kty": "RSA", "kid": "integration-key", "alg": "RS256", "use": "sig",
				"n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
				"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
			}}})
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(issuer.server.Close)
	return issuer
}

func (issuer *oidcIssuer) verifier(t *testing.T) *oidc.IDTokenVerifier {
	t.Helper()
	ctx := oidc.ClientContext(context.Background(), issuer.server.Client())
	verifier, err := syncbff.NewOIDCVerifier(ctx, syncbff.OIDCConfig{Issuer: issuer.server.URL, Audience: testAudience})
	if err != nil {
		t.Fatal(err)
	}
	return verifier
}

func (issuer *oidcIssuer) token(t *testing.T, overrides map[string]any) string {
	t.Helper()
	now := time.Now()
	claims := map[string]any{
		"iss": issuer.server.URL,
		"aud": testAudience,
		"sub": "alice",
		"tid": "tenant-a",
		"scp": "cosmos_sync",
		"iat": now.Add(-time.Minute).Unix(),
		"nbf": now.Add(-time.Minute).Unix(),
		"exp": now.Add(time.Hour).Unix(),
	}
	for key, value := range overrides {
		if value == nil {
			delete(claims, key)
		} else {
			claims[key] = value
		}
	}
	return signToken(t, issuer.key, claims, map[string]any{"alg": "RS256", "typ": "at+jwt", "kid": "integration-key"})
}

func signToken(t *testing.T, key *rsa.PrivateKey, claims, header map[string]any) string {
	t.Helper()
	encode := func(value any) string {
		raw, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		return base64.RawURLEncoding.EncodeToString(raw)
	}
	unsigned := encode(header) + "." + encode(claims)
	digest := sha256.Sum256([]byte(unsigned))
	signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return unsigned + "." + base64.RawURLEncoding.EncodeToString(signature)
}
