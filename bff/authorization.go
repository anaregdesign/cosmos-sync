package syncbff

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// AuthorizationOptions explicitly selects a new namespace. Legacy grants and
// data are never implicitly adopted by an account's first authenticated request.
type AuthorizationOptions struct {
	Mode string `json:"mode"`
}

const maxAuthorizationMembers = 128
const maxAuthorizationRevision int64 = 10000
const authorizationGrantRevisionLimit = maxAuthorizationRevision - 2*maxAuthorizationMembers

var accountIDPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type AccountIdentity struct {
	Issuer  string `json:"issuer"`
	Subject string `json:"subject"`
}

type Account struct {
	AccountID       string `json:"accountId"`
	PersonalScopeID string `json:"personalScopeId"`
}

type accountRecord struct {
	Account
	Identity AccountIdentity `json:"identity"`
}

type ScopeMember struct {
	AccountID         string `json:"accountId"`
	Role              string `json:"role"`
	PermissionVersion string `json:"permissionVersion"`
}

type SharedScope struct {
	ScopeID        string        `json:"scopeId"`
	OwnerAccountID string        `json:"ownerAccountId"`
	Revision       int64         `json:"revision"`
	Members        []ScopeMember `json:"members"`
}

type MembershipChange struct {
	OperationID  string `json:"operationId"`
	AccountID    string `json:"accountId"`
	Role         string `json:"role"`
	BaseRevision int64  `json:"baseRevision"`
}

// AuthorizationPolicy lives in the data scope's partition, outside the document
// and journal ID namespaces. Removed members remain as generation tombstones.
type AuthorizationPolicy struct {
	ScopeID        string                 `json:"scopeId"`
	OwnerAccountID string                 `json:"ownerAccountId"`
	Mode           string                 `json:"mode"`
	Revision       int64                  `json:"revision"`
	Members        map[string]ScopeMember `json:"members"`
}

type authorizationAudit struct {
	ActorAccountID string `json:"actorAccountId"`
	OperationID    string `json:"operationId"`
	AccountID      string `json:"accountId"`
	PreviousRole   string `json:"previousRole"`
	Role           string `json:"role"`
	Revision       int64  `json:"revision"`
	OccurredAt     string `json:"occurredAt"`
}

type authorizationReceipt struct {
	Hash   string      `json:"hash"`
	Result SharedScope `json:"result"`
}

type AuthorizationStore interface {
	EnsureAccount(context.Context, AccountIdentity) (Account, error)
	CreateSharedScope(context.Context, string, string) (SharedScope, error)
	LoadAuthorizationPolicy(context.Context, string) (*AuthorizationPolicy, error)
	ChangeMembership(context.Context, string, string, MembershipChange) (SharedScope, error)
}

func namespacedID(parts ...string) string {
	data, _ := json.Marshal(parts)
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

func identityAccount(identity AccountIdentity) Account {
	id := namespacedID("account-v1", identity.Issuer, identity.Subject)
	return Account{AccountID: id, PersonalScopeID: personalScopeID(id)}
}

func personalScopeID(accountID string) string { return namespacedID("personal-v1", accountID) }

func sharedScopeID(accountID, operationID string) string {
	return namespacedID("shared-v1", accountID, strings.ToLower(operationID))
}

func newAuthorizationPolicy(scopeID, accountID, mode string) *AuthorizationPolicy {
	return &AuthorizationPolicy{ScopeID: scopeID, OwnerAccountID: accountID, Mode: mode, Revision: 1, Members: map[string]ScopeMember{}}
}

func validAuthorizationPolicy(p *AuthorizationPolicy, scopeID string) bool {
	if p == nil || p.ScopeID != scopeID || !accountIDPattern.MatchString(scopeID) || !accountIDPattern.MatchString(p.OwnerAccountID) || (p.Mode != "user" && p.Mode != "shared") || p.Revision < 1 || p.Revision > maxAuthorizationRevision || p.Members == nil || len(p.Members) > maxAuthorizationMembers {
		return false
	}
	if p.Mode == "user" && (p.ScopeID != personalScopeID(p.OwnerAccountID) || len(p.Members) != 0) {
		return false
	}
	remainingReductions := int64(0)
	for id, member := range p.Members {
		version, err := strconv.ParseInt(member.PermissionVersion, 10, 64)
		if !accountIDPattern.MatchString(id) || id == p.OwnerAccountID || member.AccountID != id || (member.Role != "reader" && member.Role != "writer" && member.Role != "none") || err != nil || version < 2 || version > p.Revision || strconv.FormatInt(version, 10) != member.PermissionVersion {
			return false
		}
		if member.Role == "writer" {
			remainingReductions += 2
		} else if member.Role == "reader" {
			remainingReductions++
		}
	}
	if p.Revision >= authorizationGrantRevisionLimit && remainingReductions > maxAuthorizationRevision-p.Revision {
		return false
	}
	return true
}

func (p *AuthorizationPolicy) public() SharedScope {
	members := make([]ScopeMember, 0, len(p.Members))
	for _, member := range p.Members {
		members = append(members, member)
	}
	sort.Slice(members, func(i, j int) bool { return members[i].AccountID < members[j].AccountID })
	return SharedScope{ScopeID: p.ScopeID, OwnerAccountID: p.OwnerAccountID, Revision: p.Revision, Members: members}
}

func (p *AuthorizationPolicy) scope(accountID string) (Scope, error) {
	if p == nil || !validAuthorizationPolicy(p, p.ScopeID) {
		return Scope{}, protocolError(503, "authorization_store_unavailable")
	}
	version, write := "1", true
	if accountID != p.OwnerAccountID {
		member, exists := p.Members[accountID]
		if !exists || member.Role == "none" {
			return Scope{}, protocolError(403, "forbidden")
		}
		version, write = member.PermissionVersion, member.Role == "writer"
	}
	return Scope{ID: p.ScopeID, PrincipalID: accountID, ScopeMode: p.Mode, PermissionVersion: version, CanRead: true, CanWrite: write}, nil
}

func checkAuthorizationWrite(policy *AuthorizationPolicy, scopeID string, mutation Mutation) error {
	if mutation.AuthorizationVersion == "" {
		return nil // Only the explicitly selected legacy mode omits a fence.
	}
	if !validAuthorizationPolicy(policy, scopeID) {
		return protocolError(503, "authorization_store_unavailable")
	}
	scope, err := policy.scope(mutation.PrincipalID)
	if err != nil || !scope.CanWrite || scope.PermissionVersion != mutation.AuthorizationVersion {
		return protocolError(403, "forbidden")
	}
	return nil
}

func validateMembershipChange(change *MembershipChange) error {
	if !operationIDPattern.MatchString(change.OperationID) || !accountIDPattern.MatchString(change.AccountID) || (change.Role != "reader" && change.Role != "writer" && change.Role != "none") || change.BaseRevision < 1 || change.BaseRevision > maxAuthorizationRevision {
		return protocolError(400, "invalid_authorization_request")
	}
	change.OperationID = strings.ToLower(change.OperationID)
	return nil
}

func membershipHash(scopeID, actor string, change MembershipChange) string {
	body, _ := encodeJSON([]any{"membership-v1", scopeID, actor, change.AccountID, change.Role, change.BaseRevision})
	hash := sha256.Sum256(body)
	return hex.EncodeToString(hash[:])
}

func applyMembership(policy *AuthorizationPolicy, actor string, change MembershipChange) (*AuthorizationPolicy, authorizationAudit, error) {
	if policy == nil || !validAuthorizationPolicy(policy, policy.ScopeID) {
		return nil, authorizationAudit{}, protocolError(503, "authorization_store_unavailable")
	}
	if policy.Mode != "shared" || policy.OwnerAccountID != actor {
		return nil, authorizationAudit{}, protocolError(403, "forbidden")
	}
	if change.AccountID == policy.OwnerAccountID {
		return nil, authorizationAudit{}, protocolError(409, "immutable_owner")
	}
	if change.BaseRevision != policy.Revision {
		return nil, authorizationAudit{}, protocolError(409, "membership_conflict")
	}
	_, exists := policy.Members[change.AccountID]
	previousRole := policy.Members[change.AccountID].Role
	reducesRights := (previousRole == "writer" && (change.Role == "reader" || change.Role == "none")) || (previousRole == "reader" && change.Role == "none")
	if policy.Revision == maxAuthorizationRevision || (!exists && len(policy.Members) == maxAuthorizationMembers) || (policy.Revision >= authorizationGrantRevisionLimit && !reducesRights) {
		return nil, authorizationAudit{}, protocolError(507, "authorization_capacity_exceeded")
	}
	copy := cloneAuthorizationPolicy(policy)
	copy.Revision++
	previous := policy.Members[change.AccountID].Role
	if previous == "" {
		previous = "none"
	}
	copy.Members[change.AccountID] = ScopeMember{AccountID: change.AccountID, Role: change.Role, PermissionVersion: strconv.FormatInt(copy.Revision, 10)}
	audit := authorizationAudit{ActorAccountID: actor, OperationID: change.OperationID, AccountID: change.AccountID, PreviousRole: previous, Role: change.Role, Revision: copy.Revision, OccurredAt: time.Now().UTC().Format(time.RFC3339Nano)}
	return copy, audit, nil
}

func cloneAuthorizationPolicy(policy *AuthorizationPolicy) *AuthorizationPolicy {
	if policy == nil {
		return nil
	}
	copy := *policy
	copy.Members = make(map[string]ScopeMember, len(policy.Members))
	for id, member := range policy.Members {
		copy.Members[id] = member
	}
	return &copy
}

func (s *Server) builtinAuthorization() bool { return s.config.Authorization.Mode == "builtin" }

func (s *Server) authorizeBuiltin(ctx context.Context, identity AccountIdentity, mode, scopeID string) (Scope, error) {
	account, err := s.authorization.EnsureAccount(ctx, identity)
	if err != nil {
		return Scope{}, err
	}
	if mode == "user" {
		if scopeID != "" && scopeID != account.PersonalScopeID {
			return Scope{}, protocolError(403, "forbidden")
		}
		scopeID = account.PersonalScopeID
	} else if mode != "shared" {
		return Scope{}, protocolError(400, "invalid_scope_mode")
	} else if !accountIDPattern.MatchString(scopeID) {
		return Scope{}, protocolError(400, "invalid_authorization_request")
	}
	policy, err := s.authorization.LoadAuthorizationPolicy(ctx, scopeID)
	if err != nil {
		return Scope{}, err
	}
	if policy == nil || policy.Mode != mode {
		return Scope{}, protocolError(403, "forbidden")
	}
	return policy.scope(account.AccountID)
}

// Management routes accept a validated API access JWT, never a role claim or
// caller-supplied owner. They do not use a data session to grant authority.
func (s *Server) serveAuthorization(w http.ResponseWriter, r *http.Request, token string) bool {
	path := r.URL.Path
	if path != "/v1/account" && path != "/v1/scopes" && !strings.HasPrefix(path, "/v1/scopes/") {
		return false
	}
	if !s.builtinAuthorization() {
		s.writeError(w, protocolError(404, "not_found"))
		return true
	}
	identity, _, err := s.verifyAccessIdentity(r.Context(), token)
	if err != nil {
		s.writeError(w, err)
		return true
	}
	account := identityAccount(identity)
	if asserted := r.Header.Get(PrincipalHeader); asserted != "" && asserted != account.AccountID {
		s.writeError(w, protocolError(403, "session_mismatch"))
		return true
	}
	if !s.controls.allowPrincipal(account.AccountID) {
		s.writeError(w, &ProtocolError{Status: 429, Code: "rate_limit", RetryAfter: "1"})
		return true
	}
	account, err = s.authorization.EnsureAccount(r.Context(), identity)
	if err != nil {
		s.writeError(w, err)
		return true
	}
	if path == "/v1/account" && r.Method == http.MethodGet {
		writeJSON(w, 200, account)
		return true
	}
	if path == "/v1/scopes" && r.Method == http.MethodPost {
		var request struct {
			OperationID string `json:"operationId"`
		}
		if decodeAuthorizationRequest(w, r, &request) != nil || !operationIDPattern.MatchString(request.OperationID) {
			s.writeError(w, protocolError(400, "invalid_authorization_request"))
			return true
		}
		result, err := s.authorization.CreateSharedScope(r.Context(), account.AccountID, strings.ToLower(request.OperationID))
		if err != nil {
			s.writeError(w, err)
		} else {
			writeJSON(w, 200, result)
		}
		return true
	}
	parts := strings.Split(strings.TrimPrefix(path, "/v1/scopes/"), "/")
	if len(parts) != 2 || !accountIDPattern.MatchString(parts[0]) || parts[1] != "members" || (r.Method != http.MethodGet && r.Method != http.MethodPost) {
		s.writeError(w, protocolError(404, "not_found"))
		return true
	}
	policy, err := s.authorization.LoadAuthorizationPolicy(r.Context(), parts[0])
	if err != nil {
		s.writeError(w, err)
		return true
	}
	if policy == nil || policy.Mode != "shared" || policy.OwnerAccountID != account.AccountID {
		s.writeError(w, protocolError(403, "forbidden"))
		return true
	}
	if r.Method == http.MethodGet {
		writeJSON(w, 200, policy.public())
		return true
	}
	var change MembershipChange
	if decodeAuthorizationRequest(w, r, &change) != nil || validateMembershipChange(&change) != nil {
		s.writeError(w, protocolError(400, "invalid_authorization_request"))
		return true
	}
	result, err := s.authorization.ChangeMembership(r.Context(), parts[0], account.AccountID, change)
	if err != nil {
		s.writeError(w, err)
	} else {
		writeJSON(w, 200, result)
	}
	return true
}

func decodeAuthorizationRequest(w http.ResponseWriter, r *http.Request, value any) error {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 4096))
	if err != nil || validateJSON(body) != nil {
		return protocolError(400, "invalid_authorization_request")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if decoder.Decode(value) != nil {
		return protocolError(400, "invalid_authorization_request")
	}
	return nil
}

// Reauthorization immediately before returning a potentially slow data read
// preserves the existing SSE check and applies the same policy to sync/snapshot.
func (s *Server) reauthorizeScope(ctx context.Context, token string, previous Scope) error {
	current, err := s.authorizeSelected(ctx, token, previous.ScopeMode, previous.ID)
	if err != nil {
		return err
	}
	if current.ID != previous.ID || current.PrincipalID != previous.PrincipalID || current.PermissionVersion != previous.PermissionVersion || !current.CanRead {
		return protocolError(403, "forbidden")
	}
	return nil
}
