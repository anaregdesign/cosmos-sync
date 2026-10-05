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
	"strconv"
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
const IdentityGenerationHeader = "X-Cosmos-Sync-Identity-Generation"
const IdentityHeader = "X-Cosmos-Sync-Identity"

type OIDCConfig struct {
	Issuer           string   `json:"issuer"`
	Audience         string   `json:"audience"`
	TenantClaim      string   `json:"tenantClaim"`
	RequiredScope    string   `json:"requiredScope"`
	TokenUse         string   `json:"tokenUse"`
	AllowedClientIDs []string `json:"allowedClientIds,omitempty"`
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
	ID                 string `json:"scopeId"`
	PermissionVersion  string `json:"permissionVersion"`
	PrincipalID        string `json:"principalId"`
	ScopeMode          string `json:"scopeMode"`
	IdentityGeneration int64  `json:"identityGeneration,omitempty"`
	IdentityID         string `json:"identityId,omitempty"`
	CanRead            bool   `json:"-"`
	CanWrite           bool   `json:"-"`
}
type Config struct {
	Listen          string               `json:"listen"`
	Development     bool                 `json:"development"`
	TLSMode         string               `json:"-"`
	OIDC            OIDCConfig           `json:"oidc"`
	CursorKeyBase64 string               `json:"cursorKeyBase64"`
	Grants          []Grant              `json:"grants"`
	GrantsFile      string               `json:"grantsFile"`
	Authorization   AuthorizationOptions `json:"authorization"`
	Storage         string               `json:"storage"`
	Cosmos          CosmosConfig         `json:"cosmos"`
	HistoryEpoch    string               `json:"historyEpoch"`
	Events          EventOptions         `json:"events"`
	Limits          LimitOptions         `json:"limits"`
	Snapshots       SnapshotOptions      `json:"snapshots"`
	MetricsToken    string               `json:"-"`
	AllowedOrigins  []string             `json:"allowedOrigins"`
	Retention       RetentionOptions     `json:"retention"`
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
	if err := validateAllowedClientIDs(c.AllowedClientIDs); err != nil {
		return nil, err
	}
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

func validateAllowedClientIDs(ids []string) error {
	invalid := func() error {
		return fmt.Errorf("OIDC allowedClientIds requires at most 32 distinct nonempty visible ASCII identifiers of at most 256 bytes")
	}
	if len(ids) > 32 {
		return invalid()
	}
	seen := make(map[string]bool, len(ids))
	for _, id := range ids {
		if len(id) == 0 || len(id) > 256 || seen[id] {
			return invalid()
		}
		for i := 0; i < len(id); i++ {
			if id[i] < '!' || id[i] > '~' {
				return invalid()
			}
		}
		seen[id] = true
	}
	return nil
}

func (s *Server) authorize(ctx context.Context, token, mode string) (Scope, error) {
	return s.authorizeSelected(ctx, token, mode, "")
}

func (s *Server) authorizeSelected(ctx context.Context, token, mode, scopeID string) (Scope, error) {
	return s.authorizeSelectedAt(ctx, token, mode, scopeID, "")
}

func (s *Server) authorizeSelectedAt(ctx context.Context, token, mode, scopeID, dataMinimum string) (Scope, error) {
	if mode == "" {
		mode = "user"
	}
	if s.builtinAuthorization() {
		if mode != "user" && mode != "shared" {
			return Scope{}, protocolError(400, "invalid_scope_mode")
		}
	} else if mode != "user" && mode != "tenant" {
		return Scope{}, protocolError(400, "invalid_scope_mode")
	}
	identity, tenant, err := s.verifyAccessIdentity(ctx, token)
	if err != nil {
		return Scope{}, err
	}
	if s.builtinAuthorization() {
		return s.authorizeBuiltin(ctx, identity, mode, scopeID, dataMinimum)
	}
	if tenant == "" {
		return Scope{}, protocolError(403, "forbidden")
	}
	subject := identity.Subject
	grants := s.config.Grants
	if s.config.GrantsFile != "" {
		data, err := os.ReadFile(s.config.GrantsFile)
		if err != nil {
			return Scope{}, protocolError(503, "grant_store_unavailable")
		}
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
	framing, _ := json.Marshal([]string{identity.Issuer, tenant, subject})
	hash := sha256.Sum256(framing)
	principal := hex.EncodeToString(hash[:])
	derivedScopeID := principal
	if mode == "tenant" {
		framing, _ = json.Marshal([]string{"tenant", identity.Issuer, tenant})
		hash = sha256.Sum256(framing)
		derivedScopeID = hex.EncodeToString(hash[:])
	}
	return Scope{ID: derivedScopeID, PrincipalID: principal, ScopeMode: mode, PermissionVersion: match.PermissionVersion, CanRead: match.CanRead, CanWrite: match.CanWrite}, nil
}

type verifiedAccessPrincipal struct {
	Identity  AccountIdentity
	TenantID  string
	ObjectID  string
	ClientID  string
	Version   string
	ExpiresAt time.Time
}

func (s *Server) verifyAccessIdentity(ctx context.Context, token string) (AccountIdentity, string, error) {
	principal, err := s.verifyAccessPrincipal(ctx, token)
	return principal.Identity, principal.TenantID, err
}

func (s *Server) verifyAccessPrincipal(ctx context.Context, token string) (verifiedAccessPrincipal, error) {
	verified, err := s.verifier.Verify(ctx, token)
	if err != nil {
		return verifiedAccessPrincipal{}, protocolError(401, "unauthorized")
	}
	var claims map[string]json.RawMessage
	if verified.Claims(&claims) != nil {
		return verifiedAccessPrincipal{}, protocolError(401, "unauthorized")
	}
	claim := func(name string) string { var value string; _ = json.Unmarshal(claims[name], &value); return value }
	// Client admission is an additional restriction on an already verified API
	// JWT. A public client's azp does not attest the app or its upstream provider.
	// No appid fallback or normalization can weaken an explicitly configured list.
	if len(s.config.OIDC.AllowedClientIDs) != 0 {
		var clientID string
		if json.Unmarshal(claims["azp"], &clientID) != nil {
			return verifiedAccessPrincipal{}, protocolError(403, "forbidden")
		}
		allowed := false
		for _, configuredID := range s.config.OIDC.AllowedClientIDs {
			if clientID == configuredID {
				allowed = true
				break
			}
		}
		if !allowed {
			return verifiedAccessPrincipal{}, protocolError(403, "forbidden")
		}
	}
	var nbf json.Number
	if value, ok := claims["nbf"]; ok {
		if json.Unmarshal(value, &nbf) != nil {
			return verifiedAccessPrincipal{}, protocolError(401, "unauthorized")
		}
		seconds, err := nbf.Int64()
		if err != nil || seconds > time.Now().Unix() {
			return verifiedAccessPrincipal{}, protocolError(401, "unauthorized")
		}
	}
	if s.config.OIDC.TokenUse != "" && claim("token_use") != s.config.OIDC.TokenUse {
		return verifiedAccessPrincipal{}, protocolError(401, "unauthorized")
	}
	// API-only audience plus required scope distinguish access JWTs from ID JWTs.
	allowed := false
	for _, value := range strings.Fields(claim("scp") + " " + claim("scope")) {
		if value == s.config.OIDC.RequiredScope {
			allowed = true
		}
	}
	tenant, subject := claim(s.config.OIDC.TenantClaim), verified.Subject
	if !allowed || subject == "" || len(subject) > 512 || len(verified.Issuer) > 2048 {
		return verifiedAccessPrincipal{}, protocolError(403, "forbidden")
	}
	return verifiedAccessPrincipal{
		Identity: AccountIdentity{Issuer: verified.Issuer, Subject: subject}, TenantID: tenant,
		ObjectID: claim("oid"), ClientID: claim("azp"), Version: claim("ver"), ExpiresAt: verified.Expiry,
	}, nil
}

type signedContext struct {
	Version            int    `json:"v"`
	Scope              string `json:"scope"`
	Permission         string `json:"permission"`
	Sequence           int64  `json:"sequence,omitempty"`
	Token              string `json:"token,omitempty"`
	Principal          string `json:"principal"`
	Mode               string `json:"mode"`
	IdentityGeneration int64  `json:"identityGeneration,omitempty"`
	IdentityID         string `json:"identityId,omitempty"`
	Epoch              string `json:"epoch"`
	Offset             int    `json:"offset,omitempty"`
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
	if json.Unmarshal(data, &value) != nil || value.Version != 1 || value.Scope != scope.ID || value.Permission != scope.PermissionVersion || value.Principal != scope.PrincipalID || value.Mode != scope.ScopeMode || value.Epoch != s.config.HistoryEpoch ||
		!scope.validIdentityBinding() || value.IdentityGeneration != scope.IdentityGeneration || value.IdentityID != scope.IdentityID {
		return invalid()
	}
	return value, nil
}

func (s *Server) boundContext(scope Scope, sequence int64) signedContext {
	return signedContext{Version: 1, Scope: scope.ID, Permission: scope.PermissionVersion, Principal: scope.PrincipalID, Mode: scope.ScopeMode,
		IdentityGeneration: scope.IdentityGeneration, IdentityID: scope.IdentityID, Epoch: s.config.HistoryEpoch, Sequence: sequence}
}

func (scope Scope) validIdentityBinding() bool {
	return scope.IdentityGeneration == 0 && scope.IdentityID == "" ||
		scope.IdentityGeneration >= 1 && scope.IdentityGeneration <= maxIdentityGeneration && accountIDPattern.MatchString(scope.IdentityID)
}

func (scope Scope) sameBinding(other Scope) bool {
	return scope.ID == other.ID && scope.PrincipalID == other.PrincipalID && scope.ScopeMode == other.ScopeMode &&
		scope.PermissionVersion == other.PermissionVersion && scope.IdentityGeneration == other.IdentityGeneration && scope.IdentityID == other.IdentityID
}

func checkScopeBinding(current, previous Scope) error {
	if current.IdentityGeneration != previous.IdentityGeneration || current.IdentityID != previous.IdentityID {
		return protocolError(401, "identity_session_invalid")
	}
	if !current.sameBinding(previous) || !current.CanRead {
		return protocolError(403, "forbidden")
	}
	return nil
}

func checkIdentityRequestBinding(request *http.Request, scope Scope) error {
	if !scope.validIdentityBinding() {
		return protocolError(503, "identity_directory_unavailable")
	}
	if scope.IdentityGeneration == 0 {
		if len(request.Header.Values(IdentityGenerationHeader)) != 0 || len(request.Header.Values(IdentityHeader)) != 0 {
			return protocolError(401, "identity_session_invalid")
		}
		return nil
	}
	if len(request.Header.Values(IdentityGenerationHeader)) != 1 || len(request.Header.Values(IdentityHeader)) != 1 ||
		request.Header.Get(IdentityGenerationHeader) != strconv.FormatInt(scope.IdentityGeneration, 10) || request.Header.Get(IdentityHeader) != scope.IdentityID {
		return protocolError(401, "identity_session_invalid")
	}
	return nil
}
