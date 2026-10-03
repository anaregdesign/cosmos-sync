package syncbff

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"
)

const ScopeHeader = "X-Cosmos-Sync-Scope"
const PermissionHeader = "X-Cosmos-Sync-Permission"
const SessionHeader = "X-Cosmos-Sync-Session"
const PrincipalHeader = "X-Cosmos-Sync-Principal"
const ScopeModeHeader = "X-Cosmos-Sync-Scope-Mode"

type OIDCConfig struct {
	Issuer        string `json:"issuer"`
	Audience      string `json:"audience"`
	TenantClaim   string `json:"tenantClaim"`
	RequiredScope string `json:"requiredScope"`
	TokenUse      string `json:"tokenUse"`
}
type Grant struct {
	Tenant            string `json:"tenant"`
	Subject           string `json:"subject"`
	PermissionVersion string `json:"permissionVersion"`
	Active            bool   `json:"active"`
	CanRead           bool   `json:"canRead"`
	CanWrite          bool   `json:"canWrite"`
	ScopeMode         string `json:"scopeMode"`
}
type Scope struct {
	ID                string `json:"scopeId"`
	PermissionVersion string `json:"permissionVersion"`
	PrincipalID       string `json:"principalId"`
	ScopeMode         string `json:"scopeMode"`
	CanRead           bool   `json:"-"`
	CanWrite          bool   `json:"-"`
}
type Config struct {
	Listen          string           `json:"listen"`
	Development     bool             `json:"development"`
	TLSMode         string           `json:"-"`
	OIDC            OIDCConfig       `json:"oidc"`
	CursorKeyBase64 string           `json:"cursorKeyBase64"`
	Grants          []Grant          `json:"grants"`
	GrantsFile      string           `json:"grantsFile"`
	Storage         string           `json:"storage"`
	Cosmos          CosmosConfig     `json:"cosmos"`
	HistoryEpoch    string           `json:"historyEpoch"`
	Events          EventOptions     `json:"events"`
	Limits          LimitOptions     `json:"limits"`
	Snapshots       SnapshotOptions  `json:"snapshots"`
	MetricsToken    string           `json:"-"`
	AllowedOrigins  []string         `json:"allowedOrigins"`
	Retention       RetentionOptions `json:"retention"`
}

func validateGrantRoles(grants []Grant) error {
	for _, grant := range grants {
		if grant.CanWrite && !grant.CanRead {
			return fmt.Errorf("grant write capability requires read capability")
		}
	}
	return nil
}

func NewOIDCVerifier(ctx context.Context, c OIDCConfig) (*oidc.IDTokenVerifier, error) {
	if !strings.HasPrefix(c.Issuer, "https://") || c.Audience == "" {
		return nil, fmt.Errorf("OIDC issuer must use HTTPS and audience is required")
	}
	// Keep a bounded HTTP client for discovery and background JWKS refresh. The
	// verifier's RemoteKeySet removes context cancellation in the pinned version.
	if client, ok := ctx.Value(oauth2.HTTPClient).(*http.Client); !ok || client == nil {
		ctx = oidc.ClientContext(ctx, &http.Client{Timeout: 10 * time.Second})
	}
	provider, err := oidc.NewProvider(ctx, c.Issuer)
	if err != nil {
		return nil, err
	}
	return provider.VerifierContext(ctx, &oidc.Config{ClientID: c.Audience, SupportedSigningAlgs: []string{oidc.RS256, oidc.RS384, oidc.RS512, oidc.ES256, oidc.ES384, oidc.ES512}}), nil
}

func (s *Server) authorize(ctx context.Context, token, mode string) (Scope, error) {
	if mode == "" {
		mode = "user"
	}
	if mode != "user" && mode != "tenant" {
		return Scope{}, protocolError(400, "invalid_scope_mode")
	}
	verified, err := s.verifier.Verify(ctx, token)
	if err != nil {
		return Scope{}, protocolError(401, "unauthorized")
	}
	var claims map[string]json.RawMessage
	if verified.Claims(&claims) != nil {
		return Scope{}, protocolError(401, "unauthorized")
	}
	claim := func(name string) string { var value string; _ = json.Unmarshal(claims[name], &value); return value }
	var nbf json.Number
	if value, ok := claims["nbf"]; ok {
		if json.Unmarshal(value, &nbf) != nil {
			return Scope{}, protocolError(401, "unauthorized")
		}
		seconds, err := nbf.Int64()
		if err != nil || seconds > time.Now().Unix() {
			return Scope{}, protocolError(401, "unauthorized")
		}
	}
	if s.config.OIDC.TokenUse != "" && claim("token_use") != s.config.OIDC.TokenUse {
		return Scope{}, protocolError(401, "unauthorized")
	}
	// API-only audience plus required scope distinguish access JWTs from ID JWTs.
	allowed := false
	for _, value := range strings.Fields(claim("scp") + " " + claim("scope")) {
		if value == s.config.OIDC.RequiredScope {
			allowed = true
		}
	}
	tenant, subject := claim(s.config.OIDC.TenantClaim), verified.Subject
	if !allowed || tenant == "" || subject == "" {
		return Scope{}, protocolError(403, "forbidden")
	}
	grants := s.config.Grants
	if s.config.GrantsFile != "" {
		data, err := os.ReadFile(s.config.GrantsFile)
		if err != nil {
			return Scope{}, protocolError(503, "grant_store_unavailable")
		}
		// Decode into fresh storage: reusing the inline config slice would mutate
		// shared server configuration during concurrent requests and SSE checks.
		var loaded []Grant
		if json.Unmarshal(data, &loaded) != nil || validateGrantRoles(loaded) != nil {
			return Scope{}, protocolError(503, "grant_store_unavailable")
		}
		grants = loaded
	}
	var match *Grant
	for i := range grants {
		grantMode := grants[i].ScopeMode
		if grantMode == "" {
			grantMode = "user"
		}
		if grants[i].Tenant == tenant && grants[i].Subject == subject && grantMode == mode {
			if match != nil {
				return Scope{}, protocolError(403, "forbidden")
			}
			match = &grants[i]
		}
	}
	if match == nil || !match.Active || match.PermissionVersion == "" || !match.CanRead {
		return Scope{}, protocolError(403, "forbidden")
	}
	framing, _ := json.Marshal([]string{verified.Issuer, tenant, subject})
	hash := sha256.Sum256(framing)
	principal := hex.EncodeToString(hash[:])
	scopeID := principal
	if mode == "tenant" {
		framing, _ = json.Marshal([]string{"tenant", verified.Issuer, tenant})
		hash = sha256.Sum256(framing)
		scopeID = hex.EncodeToString(hash[:])
	}
	return Scope{ID: scopeID, PrincipalID: principal, ScopeMode: mode, PermissionVersion: match.PermissionVersion, CanRead: match.CanRead, CanWrite: match.CanWrite}, nil
}

type signedContext struct {
	Version    int    `json:"v"`
	Scope      string `json:"scope"`
	Permission string `json:"permission"`
	Sequence   int64  `json:"sequence,omitempty"`
	Token      string `json:"token,omitempty"`
	Principal  string `json:"principal"`
	Mode       string `json:"mode"`
	Epoch      string `json:"epoch"`
	Offset     int    `json:"offset,omitempty"`
}

func (s *Server) sign(purpose string, value signedContext) string {
	data, _ := json.Marshal(value)
	payload := base64.RawURLEncoding.EncodeToString(data)
	mac := hmac.New(sha256.New, s.key)
	_, _ = mac.Write([]byte(purpose + "." + payload))
	return payload + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}
func (s *Server) verifyContext(purpose, context string, scope Scope) (signedContext, error) {
	invalid := func() (signedContext, error) { return signedContext{}, protocolError(410, "resync_required") }
	parts := strings.Split(context, ".")
	if len(context) > 16384 || len(parts) != 2 {
		return invalid()
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return invalid()
	}
	mac := hmac.New(sha256.New, s.key)
	_, _ = mac.Write([]byte(purpose + "." + parts[0]))
	if !hmac.Equal(mac.Sum(nil), signature) {
		return invalid()
	}
	data, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return invalid()
	}
	var value signedContext
	if json.Unmarshal(data, &value) != nil || value.Version != 1 || value.Scope != scope.ID || value.Permission != scope.PermissionVersion || value.Principal != scope.PrincipalID || value.Mode != scope.ScopeMode || value.Epoch != s.config.HistoryEpoch {
		return invalid()
	}
	return value, nil
}

func (s *Server) boundContext(scope Scope, sequence int64) signedContext {
	return signedContext{Version: 1, Scope: scope.ID, Permission: scope.PermissionVersion, Principal: scope.PrincipalID, Mode: scope.ScopeMode, Epoch: s.config.HistoryEpoch, Sequence: sequence}
}
