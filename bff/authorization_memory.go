package syncbff

import (
	"context"
	"strings"
	"time"
)

func (s *MemoryStore) initializeAuthorization() {
	if s.accounts == nil {
		s.accounts = make(map[string]accountRecord)
	}
	if s.policies == nil {
		s.policies = make(map[string]*AuthorizationPolicy)
	}
	if s.authorizationReceipts == nil {
		s.authorizationReceipts = make(map[string]map[string]authorizationReceipt)
	}
	if s.authorizationAudits == nil {
		s.authorizationAudits = make(map[string][]authorizationAudit)
	}
}

func (s *MemoryStore) EnsureAccount(ctx context.Context, identity AccountIdentity) (Account, error) {
	if err := ctx.Err(); err != nil {
		return Account{}, err
	}
	if identity.Issuer == "" || identity.Subject == "" || len(identity.Issuer) > 2048 || len(identity.Subject) > 512 {
		return Account{}, protocolError(400, "invalid_authorization_request")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.initializeAuthorization()
	account := identityAccount(identity)
	if record, exists := s.accounts[account.AccountID]; exists {
		if record.Identity != identity || record.Account != account || !validAuthorizationPolicy(s.policies[account.PersonalScopeID], account.PersonalScopeID) {
			return Account{}, protocolError(503, "authorization_store_unavailable")
		}
		return account, nil
	}
	s.accounts[account.AccountID] = accountRecord{Account: account, Identity: identity}
	s.policies[account.PersonalScopeID] = newAuthorizationPolicy(account.PersonalScopeID, account.AccountID, "user")
	return account, nil
}

func (s *MemoryStore) LoadAuthorizationPolicy(ctx context.Context, scopeID string) (*AuthorizationPolicy, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	policy := s.policies[scopeID]
	if policy != nil && !validAuthorizationPolicy(policy, scopeID) {
		return nil, protocolError(503, "authorization_store_unavailable")
	}
	return cloneAuthorizationPolicy(policy), nil
}

func (s *MemoryStore) CreateSharedScope(ctx context.Context, accountID, operationID string) (SharedScope, error) {
	if err := ctx.Err(); err != nil {
		return SharedScope{}, err
	}
	if !accountIDPattern.MatchString(accountID) || !operationIDPattern.MatchString(operationID) {
		return SharedScope{}, protocolError(400, "invalid_authorization_request")
	}
	operationID = strings.ToLower(operationID)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.initializeAuthorization()
	if _, exists := s.accounts[accountID]; !exists {
		return SharedScope{}, protocolError(404, "account_not_found")
	}
	id := sharedScopeID(accountID, operationID)
	policy := newAuthorizationPolicy(id, accountID, "shared")
	if existing := s.policies[id]; existing != nil {
		if !validAuthorizationPolicy(existing, id) || existing.OwnerAccountID != accountID || existing.Mode != "shared" {
			return SharedScope{}, protocolError(503, "authorization_store_unavailable")
		}
		return policy.public(), nil // Exact immutable creation response, not current membership.
	}
	s.policies[id] = policy
	s.authorizationAudits[id] = []authorizationAudit{{ActorAccountID: accountID, AccountID: accountID, OperationID: operationID, Role: "owner", Revision: 1, OccurredAt: time.Now().UTC().Format(time.RFC3339Nano)}}
	return policy.public(), nil
}

func (s *MemoryStore) ChangeMembership(ctx context.Context, scopeID, actor string, change MembershipChange) (SharedScope, error) {
	if err := ctx.Err(); err != nil {
		return SharedScope{}, err
	}
	if !accountIDPattern.MatchString(scopeID) || validateMembershipChange(&change) != nil {
		return SharedScope{}, protocolError(400, "invalid_authorization_request")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.initializeAuthorization()
	policy := s.policies[scopeID]
	if policy == nil {
		return SharedScope{}, protocolError(403, "forbidden")
	}
	if !validAuthorizationPolicy(policy, scopeID) {
		return SharedScope{}, protocolError(503, "authorization_store_unavailable")
	}
	if policy.Mode != "shared" || actor != policy.OwnerAccountID {
		return SharedScope{}, protocolError(403, "forbidden")
	}
	key, hash := actor+":"+change.OperationID, membershipHash(scopeID, actor, change)
	if existing, ok := s.authorizationReceipts[scopeID][key]; ok {
		if existing.Hash != hash {
			return SharedScope{}, protocolError(409, "idempotency_mismatch")
		}
		result := existing.Result
		result.Members = append([]ScopeMember{}, result.Members...)
		return result, nil
	}
	if _, exists := s.accounts[change.AccountID]; !exists {
		return SharedScope{}, protocolError(404, "account_not_found")
	}
	updated, audit, err := applyMembership(policy, actor, change)
	if err != nil {
		return SharedScope{}, err
	}
	result := updated.public()
	s.policies[scopeID] = updated
	if s.authorizationReceipts[scopeID] == nil {
		s.authorizationReceipts[scopeID] = map[string]authorizationReceipt{}
	}
	s.authorizationReceipts[scopeID][key] = authorizationReceipt{Hash: hash, Result: result}
	s.authorizationAudits[scopeID] = append(s.authorizationAudits[scopeID], audit)
	result.Members = append([]ScopeMember{}, result.Members...)
	return result, nil
}
