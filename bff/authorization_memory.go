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
	if !validAccountIdentity(identity) {
		return Account{}, protocolError(400, "invalid_authorization_request")
	}
	return s.ensureAuthorizationAccount(ctx, accountRecord{Account: identityAccount(identity), Identity: identity})
}

func (s *MemoryStore) ensureDirectoryAccount(ctx context.Context, account directoryAccount) (Account, error) {
	if !validDirectoryAccount(account) {
		return Account{}, protocolError(400, "invalid_authorization_request")
	}
	return s.ensureAuthorizationAccount(ctx, accountRecord{Account: account.Account, DirectoryVersion: directoryAccountVersion})
}

// Called with s.mu held.
func (s *MemoryStore) authorizationAccount(accountID string) (*accountRecord, error) {
	record, exists := s.accounts[accountID]
	policy := s.policies[personalScopeID(accountID)]
	if !exists && policy == nil {
		return nil, nil
	}
	if !exists || !validAccountRecord(record, accountID) || !validPersonalPolicy(policy, accountID) {
		return nil, protocolError(503, "authorization_store_unavailable")
	}
	return &record, nil
}

func (s *MemoryStore) ensureAuthorizationAccount(ctx context.Context, record accountRecord) (Account, error) {
	if err := ctx.Err(); err != nil {
		return Account{}, err
	}
	if !validAccountRecord(record, record.AccountID) {
		return Account{}, protocolError(400, "invalid_authorization_request")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.initializeAuthorization()
	account := record.Account
	existing, err := s.authorizationAccount(account.AccountID)
	if err != nil {
		return Account{}, err
	}
	if existing != nil {
		if *existing != record {
			return Account{}, protocolError(503, "authorization_store_unavailable")
		}
		return account, nil
	}
	s.accounts[account.AccountID] = record
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

func (s *MemoryStore) LoadAuthorizationPolicyAt(ctx context.Context, scopeID, dataMinimum string) (*AuthorizationPolicy, error) {
	return s.LoadAuthorizationPolicy(ctx, scopeID)
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
	account, err := s.authorizationAccount(accountID)
	if err != nil {
		return SharedScope{}, err
	}
	if account == nil {
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
	account, err := s.authorizationAccount(change.AccountID)
	if err != nil {
		return SharedScope{}, err
	}
	if account == nil {
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
