package integration

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
)

const browserFixtureClient = "non-uuid-browser-public-client"

var browserFixtureMode = map[string]bool{
	"normal": true, "bad-state": true, "bad-id-issuer": true,
	"bad-id-audience": true, "bad-id-signature": true, "bad-id-nonce": true,
	"bad-api-issuer": true, "bad-api-audience": true, "bad-api-scope": true,
	"no-refresh": true, "refresh-no-id": true, "refresh-subject-switch": true,
	"invalid-refresh": true, "slow-authorization": true, "slow-token": true,
}

type browserAuthorization struct {
	subject, nonce, challenge, scope, mode string
	expires                                time.Time
}

type browserIssuer struct {
	*oidcIssuer
	mu      sync.Mutex
	origin  string
	mode    string
	subject string
	codes   map[string]browserAuthorization
	refresh map[string]browserAuthorization
	counts  map[string]int
}

func newBrowserIssuer(t *testing.T, origin string) *browserIssuer {
	t.Helper()
	fixture := &browserIssuer{
		origin: origin, mode: "normal", subject: "alice",
		codes: map[string]browserAuthorization{}, refresh: map[string]browserAuthorization{},
		counts: map[string]int{},
	}
	newOIDCIssuerWithHandler(t, func(issuer *oidcIssuer, base http.Handler) http.Handler {
		fixture.oidcIssuer = issuer
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "no-store")
			requestOrigin := r.Header.Get("Origin")
			if requestOrigin != "" && requestOrigin != origin {
				http.Error(w, "fixture_origin_denied", http.StatusForbidden)
				return
			}
			if requestOrigin == origin {
				w.Header().Set("Access-Control-Allow-Origin", origin)
				w.Header().Set("Vary", "Origin")
				w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
				w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
			}
			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			switch r.URL.Path {
			case "/.well-known/openid-configuration":
				w.Header().Set("Content-Type", "application/json")
				_ = json.NewEncoder(w).Encode(map[string]any{
					"issuer": issuer.server.URL, "jwks_uri": issuer.server.URL + "/jwks",
					"authorization_endpoint":                issuer.server.URL + "/authorize",
					"token_endpoint":                        issuer.server.URL + "/token",
					"end_session_endpoint":                  issuer.server.URL + "/logout",
					"id_token_signing_alg_values_supported": []string{"RS256"},
					"response_types_supported":              []string{"code"},
					"code_challenge_methods_supported":      []string{"S256"},
					"token_endpoint_auth_methods_supported": []string{"none"},
				})
			case "/authorize":
				fixture.authorize(w, r)
			case "/token":
				fixture.tokenExchange(t, w, r)
			case "/logout":
				if r.URL.Query().Get("post_logout_redirect_uri") != origin+"/oidc-redirect.html" {
					fixture.oauthError(w, http.StatusBadRequest, "invalid_request")
					return
				}
				callback, _ := url.Parse(origin + "/oidc-redirect.html")
				callback.RawQuery = url.Values{"state": {r.URL.Query().Get("state")}}.Encode()
				http.Redirect(w, r, callback.String(), http.StatusFound)
			case "/_fixture/options":
				if r.Method != http.MethodPost || requestOrigin != origin {
					http.Error(w, "fixture_control_denied", http.StatusForbidden)
					return
				}
				var options struct {
					Mode    string `json:"mode"`
					Subject string `json:"subject"`
				}
				decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
				decoder.DisallowUnknownFields()
				if decoder.Decode(&options) != nil || decoder.Decode(new(any)) != io.EOF ||
					!browserFixtureMode[options.Mode] || (options.Subject != "alice" && options.Subject != "bob") {
					http.Error(w, "fixture_options_denied", http.StatusBadRequest)
					return
				}
				fixture.mu.Lock()
				fixture.mode, fixture.subject = options.Mode, options.Subject
				fixture.mu.Unlock()
				w.WriteHeader(http.StatusNoContent)
			case "/_fixture/receipt":
				w.Header().Set("Content-Type", "application/json")
				fixture.mu.Lock()
				defer fixture.mu.Unlock()
				_ = json.NewEncoder(w).Encode(fixture.counts)
			case "/jwks":
				fixture.count("jwks_requests")
				base.ServeHTTP(w, r)
			default:
				http.NotFound(w, r)
			}
		})
	}, browserFixtureTLS(t))
	return fixture
}

func browserFixtureTLS(t *testing.T) *tls.Config {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal("fixture transport key generation failed")
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		t.Fatal("fixture transport serial generation failed")
	}
	certificate := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: "Cosmos Sync disposable OIDC"},
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(30 * time.Minute),
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}, DNSNames: []string{"localhost"},
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment | x509.KeyUsageCertSign,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IsCA:        true, BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, certificate, certificate, &key.PublicKey, key)
	if err != nil {
		t.Fatal("fixture transport certificate generation failed")
	}
	return &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{{
		Certificate: [][]byte{der}, PrivateKey: key,
	}}}
}

func (fixture *browserIssuer) count(name string) {
	fixture.mu.Lock()
	fixture.counts[name]++
	fixture.mu.Unlock()
}

func (fixture *browserIssuer) oauthError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": code})
}

func browserOpaque() (string, error) {
	var random [32]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(random[:]), nil
}

func uniqueParameters(values url.Values) bool {
	for _, values := range values {
		if len(values) != 1 {
			return false
		}
	}
	return true
}

func (fixture *browserIssuer) authorize(w http.ResponseWriter, r *http.Request) {
	fixture.count("authorization_requests")
	query := r.URL.Query()
	callback := fixture.origin + "/oidc-redirect.html"
	if r.Method != http.MethodGet || !uniqueParameters(query) ||
		query.Get("redirect_uri") != callback ||
		query.Get("client_id") != browserFixtureClient || query.Get("response_type") != "code" {
		fixture.count("callback_denied")
		fixture.oauthError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	scopes := strings.Fields(query.Get("scope"))
	hasScope := func(value string) bool {
		for _, scope := range scopes {
			if scope == value {
				return true
			}
		}
		return false
	}
	if !hasScope("openid") || !hasScope("cosmos_sync") ||
		query.Get("code_challenge_method") != "S256" ||
		!regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`).MatchString(query.Get("code_challenge")) ||
		!regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(query.Get("nonce")) ||
		!regexp.MustCompile(`^[A-Za-z0-9_-]{16,128}$`).MatchString(query.Get("state")) ||
		query.Has("client_secret") {
		fixture.oauthError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	code, err := browserOpaque()
	if err != nil {
		fixture.oauthError(w, http.StatusInternalServerError, "server_error")
		return
	}
	fixture.mu.Lock()
	grant := browserAuthorization{
		subject: fixture.subject, nonce: query.Get("nonce"), challenge: query.Get("code_challenge"),
		scope: query.Get("scope"), mode: fixture.mode, expires: time.Now().Add(3 * time.Minute),
	}
	fixture.codes[code] = grant
	fixture.mu.Unlock()
	if grant.mode == "slow-authorization" {
		select {
		case <-time.After(2 * time.Second):
		case <-r.Context().Done():
			return
		}
	}
	state := query.Get("state")
	if grant.mode == "bad-state" {
		state = "fixture-unmatched-authorization-state"
	}
	redirect, _ := url.Parse(callback)
	redirect.RawQuery = url.Values{"code": {code}, "state": {state}}.Encode()
	http.Redirect(w, r, redirect.String(), http.StatusFound)
}

func (fixture *browserIssuer) tokenExchange(t *testing.T, w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		fixture.oauthError(w, http.StatusMethodNotAllowed, "invalid_request")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16384)
	if r.ParseForm() != nil || !uniqueParameters(r.PostForm) ||
		r.Form.Get("client_id") != browserFixtureClient || r.Form.Has("client_secret") ||
		r.Header.Get("Authorization") != "" {
		fixture.oauthError(w, http.StatusBadRequest, "invalid_client")
		return
	}
	fixture.mu.Lock()
	var grant browserAuthorization
	var found bool
	refreshing := r.Form.Get("grant_type") == "refresh_token"
	switch r.Form.Get("grant_type") {
	case "authorization_code":
		grant, found = fixture.codes[r.Form.Get("code")]
		delete(fixture.codes, r.Form.Get("code"))
		fixture.counts["code_exchanges"]++
		if !found {
			fixture.counts["code_replays_denied"]++
		}
	case "refresh_token":
		grant, found = fixture.refresh[r.Form.Get("refresh_token")]
		delete(fixture.refresh, r.Form.Get("refresh_token"))
		grant.mode = fixture.mode
		fixture.counts["refresh_exchanges"]++
	default:
		fixture.mu.Unlock()
		fixture.oauthError(w, http.StatusBadRequest, "unsupported_grant_type")
		return
	}
	fixture.mu.Unlock()
	if !found || !grant.expires.After(time.Now()) || grant.mode == "invalid-refresh" {
		fixture.oauthError(w, http.StatusBadRequest, "invalid_grant")
		return
	}
	if !refreshing {
		challenge := sha256.Sum256([]byte(r.Form.Get("code_verifier")))
		if r.Form.Get("redirect_uri") != fixture.origin+"/oidc-redirect.html" ||
			base64.RawURLEncoding.EncodeToString(challenge[:]) != grant.challenge {
			fixture.count("pkce_denied")
			fixture.oauthError(w, http.StatusBadRequest, "invalid_grant")
			return
		}
		fixture.count("pkce_verified")
	}
	if grant.mode == "slow-token" {
		select {
		case <-time.After(2 * time.Second):
		case <-r.Context().Done():
			return
		}
	}
	accessClaims := map[string]any{
		"sub": grant.subject, "azp": browserFixtureClient, "token_use": "access",
	}
	switch grant.mode {
	case "bad-api-issuer":
		accessClaims["iss"] = "https://foreign.example.test"
	case "bad-api-audience":
		accessClaims["aud"] = browserFixtureClient
	case "bad-api-scope":
		accessClaims["scp"] = "another_scope"
	}
	access := fixture.oidcIssuer.token(t, accessClaims)
	now := time.Now().Add(-time.Second).Unix()
	idClaims := map[string]any{
		"iss": fixture.server.URL, "aud": browserFixtureClient,
		"sub": grant.subject, "nonce": grant.nonce, "iat": now,
		"exp": now + 3600, "token_use": "id",
	}
	switch grant.mode {
	case "bad-id-issuer":
		idClaims["iss"] = "https://foreign.example.test"
	case "bad-id-audience":
		idClaims["aud"] = testAudience
	case "bad-id-nonce":
		idClaims["nonce"] = strings.Repeat("0", 64)
	case "refresh-subject-switch":
		if refreshing {
			idClaims["sub"] = "bob"
		}
	}
	id := signToken(t, fixture.key, idClaims, map[string]any{
		"alg": "RS256", "typ": "JWT", "kid": "integration-key",
	})
	if grant.mode == "bad-id-signature" {
		parts := strings.Split(id, ".")
		signature, _ := base64.RawURLEncoding.DecodeString(parts[2])
		signature[0] ^= 0xff
		parts[2] = base64.RawURLEncoding.EncodeToString(signature)
		id = strings.Join(parts, ".")
	}
	response := map[string]any{
		"access_token": access, "token_type": "Bearer", "expires_in": 3600,
		"scope": grant.scope, "id_token": id,
	}
	if refreshing && grant.mode == "refresh-no-id" {
		delete(response, "id_token")
	}
	if grant.mode != "no-refresh" {
		credential, err := browserOpaque()
		if err != nil {
			fixture.oauthError(w, http.StatusInternalServerError, "server_error")
			return
		}
		fixture.mu.Lock()
		grant.expires = time.Now().Add(3 * time.Minute)
		fixture.refresh[credential] = grant
		fixture.mu.Unlock()
		response["refresh_token"] = credential
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(response)
}

func TestBrowserOIDCCodeContract(t *testing.T) {
	fixture := newBrowserIssuer(t, "http://127.0.0.1:8123")
	client := fixture.server.Client()
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	verifier := strings.Repeat("v", 64)
	digest := sha256.Sum256([]byte(verifier))
	authorize := url.Values{
		"client_id": {browserFixtureClient}, "redirect_uri": {fixture.origin + "/oidc-redirect.html"},
		"response_type": {"code"}, "scope": {"openid offline_access cosmos_sync"},
		"nonce": {strings.Repeat("a", 64)}, "state": {strings.Repeat("s", 32)},
		"code_challenge": {base64.RawURLEncoding.EncodeToString(digest[:])}, "code_challenge_method": {"S256"},
	}
	code := func(query url.Values) string {
		t.Helper()
		response, err := client.Get(fixture.server.URL + "/authorize?" + query.Encode())
		if err != nil {
			t.Fatal("fixture authorization transport failed")
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusFound {
			t.Fatal("fixture authorization was denied")
		}
		callback, err := url.Parse(response.Header.Get("Location"))
		if err != nil || callback.Query().Get("state") != authorize.Get("state") {
			t.Fatal("fixture callback/state contract failed")
		}
		return callback.Query().Get("code")
	}
	exchange := func(credential, proof, callback string) int {
		t.Helper()
		response, err := client.PostForm(fixture.server.URL+"/token", url.Values{
			"grant_type": {"authorization_code"}, "client_id": {browserFixtureClient},
			"code": {credential}, "code_verifier": {proof}, "redirect_uri": {callback},
		})
		if err != nil {
			t.Fatal("fixture token transport failed")
		}
		defer response.Body.Close()
		return response.StatusCode
	}
	credential := code(authorize)
	if exchange(credential, verifier, authorize.Get("redirect_uri")) != http.StatusOK ||
		exchange(credential, verifier, authorize.Get("redirect_uri")) != http.StatusBadRequest {
		t.Fatal("one-time code/replay contract failed")
	}
	if exchange(code(authorize), strings.Repeat("x", 64), authorize.Get("redirect_uri")) != http.StatusBadRequest ||
		exchange(code(authorize), verifier, "https://foreign.example.test/oidc-redirect.html") != http.StatusBadRequest {
		t.Fatal("PKCE/callback contract failed")
	}
	authorize.Set("redirect_uri", "https://foreign.example.test/oidc-redirect.html")
	response, err := client.Get(fixture.server.URL + "/authorize?" + authorize.Encode())
	if err != nil {
		t.Fatal("fixture callback-denial transport failed")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatal("foreign callback was not denied")
	}
}

// Only this opt-in test process implements OAuth and fixture controls. The
// production BFF still uses its ordinary TLS/JWKS verifier and exact grants.
func TestBrowserOIDCFixture(t *testing.T) {
	readyFile := os.Getenv("COSMOS_SYNC_BROWSER_OIDC_READY_FILE")
	stopFile := os.Getenv("COSMOS_SYNC_BROWSER_OIDC_STOP_FILE")
	origin := os.Getenv("COSMOS_SYNC_BROWSER_OIDC_ORIGIN")
	if readyFile == "" || stopFile == "" || origin == "" {
		t.Skip("set the owned browser OIDC fixture paths and loopback origin")
	}
	parsed, err := url.Parse(origin)
	if err != nil || parsed.Scheme != "http" || parsed.Hostname() != "127.0.0.1" ||
		parsed.Port() == "" || parsed.Path != "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		t.Fatal("browser fixture requires an exact owned IPv4 loopback origin")
	}
	issuer := newBrowserIssuer(t, origin)
	api := newTestAPI(t, issuer.oidcIssuer, func(config *syncbff.Config) {
		config.AllowedOrigins = []string{origin}
		config.OIDC.TokenUse = "access"
		config.OIDC.AllowedClientIDs = []string{browserFixtureClient}
		config.Snapshots = syncbff.SnapshotOptions{Enabled: true}
	})
	server := httptest.NewServer(api.handler)
	t.Cleanup(server.Close)
	certificate := issuer.server.Certificate()
	spki := sha256.Sum256(certificate.RawSubjectPublicKeyInfo)
	ready, err := json.Marshal(map[string]any{
		"url": server.URL, "issuer": issuer.server.URL, "clientId": browserFixtureClient,
		"redirectUrl": origin + "/oidc-redirect.html", "scopes": []string{"openid", "offline_access", "cosmos_sync"},
		"discoveryUrl": issuer.server.URL + "/.well-known/openid-configuration",
		"certificate":  string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate.Raw})),
		"spki":         base64.StdEncoding.EncodeToString(spki[:]),
	})
	if err != nil || os.WriteFile(readyFile, ready, 0600) != nil {
		t.Fatal("browser fixture public readiness could not be written privately")
	}
	t.Cleanup(func() { _ = os.Remove(readyFile) })
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	deadline := time.NewTimer(180 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case <-ticker.C:
			if _, err := os.Stat(stopFile); err == nil {
				return
			} else if !os.IsNotExist(err) {
				t.Fatal("browser fixture stop path failed")
			}
		case <-deadline.C:
			t.Fatal("browser OIDC fixture timed out after 180 seconds")
		}
	}
}
