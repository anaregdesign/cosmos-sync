package syncbff

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"
)

const authorizationPolicyItemID = "a:policy"
const authorizationAccountItemID = "a:account"

type authorizationSessionsKey struct{}

// This is request-local session state, not a permission cache. The Go SDK needs
// explicit session-token handoff. Tokens never cross partition or leave the BFF.
type authorizationSessions struct {
	mu     sync.Mutex
	tokens map[string]string
}

func withAuthorizationSessions(ctx context.Context) context.Context {
	if _, ok := ctx.Value(authorizationSessionsKey{}).(*authorizationSessions); ok {
		return ctx
	}
	return context.WithValue(ctx, authorizationSessionsKey{}, &authorizationSessions{tokens: make(map[string]string)})
}

func authorizationSession(ctx context.Context, scopeID, supplied string) (string, error) {
	sessions, ok := ctx.Value(authorizationSessionsKey{}).(*authorizationSessions)
	if !ok {
		return supplied, nil
	}
	sessions.mu.Lock()
	defer sessions.mu.Unlock()
	if _, exists := sessions.tokens[scopeID]; !exists && len(sessions.tokens) >= 8 {
		return "", protocolError(503, "authorization_store_unavailable")
	}
	if observed := sessions.tokens[scopeID]; observed != "" {
		return observed, nil
	}
	return supplied, nil
}

func rememberAuthorizationSession(ctx context.Context, scopeID, session string) error {
	sessions, ok := ctx.Value(authorizationSessionsKey{}).(*authorizationSessions)
	if !ok {
		return nil
	}
	sessions.mu.Lock()
	defer sessions.mu.Unlock()
	if _, exists := sessions.tokens[scopeID]; !exists && len(sessions.tokens) >= 8 {
		return protocolError(503, "authorization_store_unavailable")
	}
	sessions.tokens[scopeID] = session
	return nil
}

func (s *CosmosStore) readAuthorizationItem(ctx context.Context, scopeID, id, session string) (*storedItem, azcore.ETag, string, error) {
	session, err := authorizationSession(ctx, scopeID, session)
	if err != nil {
		return nil, "", session, err
	}
	item, etag, session, err := s.read(ctx, scopeID, id, session)
	if rememberErr := rememberAuthorizationSession(ctx, scopeID, session); rememberErr != nil {
		return nil, "", session, rememberErr
	}
	return item, etag, session, err
}

func (s *CosmosStore) authorizationAccount(ctx context.Context, accountID string) (*accountRecord, error) {
	if !accountIDPattern.MatchString(accountID) {
		return nil, protocolError(400, "invalid_authorization_request")
	}
	scopeID := personalScopeID(accountID)
	item, _, session, err := s.readAuthorizationItem(ctx, scopeID, authorizationAccountItemID, "")
	if err != nil {
		return nil, err
	}
	policy, _, session, err := s.readAuthorizationPolicy(ctx, scopeID, session)
	if err != nil {
		return nil, err
	}
	if item == nil && policy != nil {
		// These are two reads, not one snapshot: another BFF can atomically
		// create both records between them. The later token observes its ACK.
		item, _, _, err = s.readAuthorizationItem(ctx, scopeID, authorizationAccountItemID, session)
		if err != nil {
			return nil, err
		}
	}
	if item == nil && policy == nil {
		return nil, nil
	}
	if item == nil || item.ID != authorizationAccountItemID || item.ScopeID != scopeID || item.Kind != "account" || item.Account == nil || item.Account.Identity.Issuer == "" || len(item.Account.Identity.Issuer) > 2048 || item.Account.Identity.Subject == "" || len(item.Account.Identity.Subject) > 512 || item.Account.AccountID != accountID || item.Account.Account != identityAccount(item.Account.Identity) || policy == nil || policy.Mode != "user" || policy.OwnerAccountID != accountID {
		return nil, protocolError(503, "authorization_store_unavailable")
	}
	return item.Account, nil
}

func (s *CosmosStore) EnsureAccount(ctx context.Context, identity AccountIdentity) (Account, error) {
	ctx = withAuthorizationSessions(ctx)
	if identity.Issuer == "" || len(identity.Issuer) > 2048 || identity.Subject == "" || len(identity.Subject) > 512 {
		return Account{}, protocolError(400, "invalid_authorization_request")
	}
	account := identityAccount(identity)
	for attempt := 0; attempt < 12; attempt++ {
		if err := ctx.Err(); err != nil {
			return Account{}, err
		}
		existing, err := s.authorizationAccount(ctx, account.AccountID)
		if err != nil {
			return Account{}, err
		}
		if existing != nil {
			if existing.Identity != identity {
				return Account{}, protocolError(503, "authorization_store_unavailable")
			}
			return account, nil
		}
		record := &accountRecord{Account: account, Identity: identity}
		policy := newAuthorizationPolicy(account.PersonalScopeID, account.AccountID, "user")
		accountBody, _ := encodeJSON(storedItem{ID: authorizationAccountItemID, ScopeID: account.PersonalScopeID, Kind: "account", Account: record})
		policyBody, _ := encodeJSON(storedItem{ID: authorizationPolicyItemID, ScopeID: account.PersonalScopeID, Kind: "authorization", Policy: policy})
		batch := s.container.NewTransactionalBatch(azcosmos.NewPartitionKeyString(account.PersonalScopeID))
		batch.CreateItem(accountBody, nil)
		batch.CreateItem(policyBody, nil)
		if _, err := s.executeAuthorizationBatch(ctx, account.PersonalScopeID, batch, 2, ""); err != nil {
			if authorizationContention(err) {
				continue
			}
			return Account{}, err
		}
		// Read with the acknowledged batch's token before claiming that the
		// account's personal policy is usable. Partial metadata fails closed.
		verified, err := s.authorizationAccount(ctx, account.AccountID)
		if err != nil {
			return Account{}, err
		}
		if verified == nil || verified.Identity != identity {
			return Account{}, protocolError(503, "authorization_store_unavailable")
		}
		return account, nil
	}
	return Account{}, &ProtocolError{Status: 503, Code: "contention_retry", RetryAfter: "1"}
}

func (s *CosmosStore) readAuthorizationPolicy(ctx context.Context, scopeID, session string) (*AuthorizationPolicy, azcore.ETag, string, error) {
	item, etag, session, err := s.readAuthorizationItem(ctx, scopeID, authorizationPolicyItemID, session)
	if err != nil {
		return nil, "", session, err
	}
	if item == nil {
		return nil, "", session, nil
	}
	if item.ID != authorizationPolicyItemID || item.ScopeID != scopeID || item.Kind != "authorization" || etag == "" || !validAuthorizationPolicy(item.Policy, scopeID) {
		return nil, "", session, protocolError(503, "authorization_store_unavailable")
	}
	return item.Policy, etag, session, nil
}

func (s *CosmosStore) LoadAuthorizationPolicy(ctx context.Context, scopeID string) (*AuthorizationPolicy, error) {
	policy, _, _, err := s.readAuthorizationPolicy(ctx, scopeID, "")
	return policy, err
}

func (s *CosmosStore) CreateSharedScope(ctx context.Context, accountID, operationID string) (SharedScope, error) {
	ctx = withAuthorizationSessions(ctx)
	if !accountIDPattern.MatchString(accountID) || !operationIDPattern.MatchString(operationID) {
		return SharedScope{}, protocolError(400, "invalid_authorization_request")
	}
	operationID = strings.ToLower(operationID)
	account, err := s.authorizationAccount(ctx, accountID)
	if err != nil {
		return SharedScope{}, err
	}
	if account == nil {
		return SharedScope{}, protocolError(404, "account_not_found")
	}
	scopeID := sharedScopeID(accountID, operationID)
	initial := newAuthorizationPolicy(scopeID, accountID, "shared")
	var session string
	for attempt := 0; attempt < 12; attempt++ {
		if err := ctx.Err(); err != nil {
			return SharedScope{}, err
		}
		policy, _, token, err := s.readAuthorizationPolicy(ctx, scopeID, session)
		session = token
		if err != nil {
			return SharedScope{}, err
		}
		if policy != nil {
			if policy.Mode != "shared" || policy.OwnerAccountID != accountID {
				return SharedScope{}, protocolError(503, "authorization_store_unavailable")
			}
			item, _, token, err := s.readAuthorizationItem(ctx, scopeID, "a:audit:00001", session)
			session = token
			if err != nil {
				return SharedScope{}, err
			}
			if !validCreationAudit(item, scopeID, accountID, operationID) {
				return SharedScope{}, protocolError(503, "authorization_store_unavailable")
			}
			return initial.public(), nil // Creation's immutable result survives membership edits.
		}
		policyBody, _ := encodeJSON(storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: initial})
		audit := &authorizationAudit{ActorAccountID: accountID, AccountID: accountID, OperationID: operationID, Role: "owner", Revision: 1, OccurredAt: time.Now().UTC().Format(time.RFC3339Nano)}
		auditBody, _ := encodeJSON(storedItem{ID: "a:audit:00001", ScopeID: scopeID, Kind: "authorization-audit", Audit: audit})
		batch := s.container.NewTransactionalBatch(azcosmos.NewPartitionKeyString(scopeID))
		batch.CreateItem(policyBody, nil)
		batch.CreateItem(auditBody, nil)
		var batchErr error
		session, batchErr = s.executeAuthorizationBatch(ctx, scopeID, batch, 2, session)
		if batchErr != nil {
			if authorizationContention(batchErr) {
				continue
			}
			return SharedScope{}, batchErr
		}
		return initial.public(), nil
	}
	return SharedScope{}, &ProtocolError{Status: 503, Code: "contention_retry", RetryAfter: "1"}
}

func (s *CosmosStore) ChangeMembership(ctx context.Context, scopeID, actor string, change MembershipChange) (SharedScope, error) {
	ctx = withAuthorizationSessions(ctx)
	if !accountIDPattern.MatchString(scopeID) || !accountIDPattern.MatchString(actor) || validateMembershipChange(&change) != nil {
		return SharedScope{}, protocolError(400, "invalid_authorization_request")
	}
	hash, receiptID := membershipHash(scopeID, actor, change), "a:r:"+actor+":"+change.OperationID
	var session string
	for attempt := 0; attempt < 12; attempt++ {
		if err := ctx.Err(); err != nil {
			return SharedScope{}, err
		}
		policy, etag, token, err := s.readAuthorizationPolicy(ctx, scopeID, session)
		session = token
		if err != nil {
			return SharedScope{}, err
		}
		if policy == nil || policy.Mode != "shared" || policy.OwnerAccountID != actor {
			return SharedScope{}, protocolError(403, "forbidden")
		}
		receipt, _, token, err := s.readAuthorizationItem(ctx, scopeID, receiptID, session)
		session = token
		if err != nil {
			return SharedScope{}, err
		}
		if receipt != nil {
			if receipt.AuthorizationReceipt != nil && receipt.AuthorizationReceipt.Result.Revision > policy.Revision {
				// An exact replay can see the receipt of a concurrent commit
				// after the earlier policy read. Advance using that read's token.
				policy, etag, token, err = s.readAuthorizationPolicy(ctx, scopeID, session)
				session = token
				if err != nil {
					return SharedScope{}, err
				}
				if policy == nil || policy.Mode != "shared" || policy.OwnerAccountID != actor {
					return SharedScope{}, protocolError(503, "authorization_store_unavailable")
				}
			}
			if !validAuthorizationReceipt(receipt, scopeID, actor, receiptID, policy.Revision) {
				return SharedScope{}, protocolError(503, "authorization_store_unavailable")
			}
			if receipt.AuthorizationReceipt.Hash != hash {
				return SharedScope{}, protocolError(409, "idempotency_mismatch")
			}
			result := receipt.AuthorizationReceipt.Result
			if result.Revision != change.BaseRevision+1 || !membershipResultMatches(result, change) {
				return SharedScope{}, protocolError(503, "authorization_store_unavailable")
			}
			return receipt.AuthorizationReceipt.Result, nil
		}
		account, err := s.authorizationAccount(ctx, change.AccountID)
		if err != nil {
			return SharedScope{}, err
		}
		if account == nil {
			return SharedScope{}, protocolError(404, "account_not_found")
		}
		updated, audit, err := applyMembership(policy, actor, change)
		if err != nil {
			// A concurrent exact replay can commit between the receipt read and
			// policy read. Retry stale revision once through the receipt lookup.
			if e, ok := err.(*ProtocolError); ok && e.Code == "membership_conflict" && attempt < 1 {
				continue
			}
			return SharedScope{}, err
		}
		result := updated.public()
		policyBody, _ := encodeJSON(storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: updated})
		auditBody, _ := encodeJSON(storedItem{ID: fmt.Sprintf("a:audit:%05d", updated.Revision), ScopeID: scopeID, Kind: "authorization-audit", Audit: &audit})
		receiptBody, _ := encodeJSON(storedItem{ID: receiptID, ScopeID: scopeID, Kind: "authorization-receipt", AuthorizationReceipt: &authorizationReceipt{Hash: hash, Result: result}})
		batch := s.container.NewTransactionalBatch(azcosmos.NewPartitionKeyString(scopeID))
		batch.ReplaceItem(authorizationPolicyItemID, policyBody, &azcosmos.TransactionalBatchItemOptions{IfMatchETag: &etag})
		batch.CreateItem(auditBody, nil)
		batch.CreateItem(receiptBody, nil)
		var batchErr error
		session, batchErr = s.executeAuthorizationBatch(ctx, scopeID, batch, 3, session)
		if batchErr != nil {
			if authorizationContention(batchErr) {
				continue
			}
			return SharedScope{}, batchErr
		}
		return result, nil
	}
	return SharedScope{}, &ProtocolError{Status: 503, Code: "contention_retry", RetryAfter: "1"}
}

func validAuthorizationReceipt(item *storedItem, scopeID, actor, receiptID string, currentRevision int64) bool {
	if item == nil || item.ID != receiptID || item.ScopeID != scopeID || item.Kind != "authorization-receipt" || item.AuthorizationReceipt == nil || !accountIDPattern.MatchString(item.AuthorizationReceipt.Hash) {
		return false
	}
	result := item.AuthorizationReceipt.Result
	if result.ScopeID != scopeID || result.OwnerAccountID != actor || result.Revision < 2 || result.Revision > currentRevision || result.Members == nil {
		return false
	}
	policy := &AuthorizationPolicy{ScopeID: result.ScopeID, OwnerAccountID: result.OwnerAccountID, Mode: "shared", Revision: result.Revision, Members: make(map[string]ScopeMember, len(result.Members))}
	for _, member := range result.Members {
		if _, duplicate := policy.Members[member.AccountID]; duplicate {
			return false
		}
		policy.Members[member.AccountID] = member
	}
	return validAuthorizationPolicy(policy, scopeID)
}

func validCreationAudit(item *storedItem, scopeID, accountID, operationID string) bool {
	if item == nil || item.ID != "a:audit:00001" || item.ScopeID != scopeID || item.Kind != "authorization-audit" || item.Audit == nil {
		return false
	}
	audit := *item.Audit
	if _, err := time.Parse(time.RFC3339Nano, audit.OccurredAt); err != nil || !strings.HasSuffix(audit.OccurredAt, "Z") {
		return false
	}
	audit.OccurredAt = ""
	return audit == (authorizationAudit{ActorAccountID: accountID, AccountID: accountID, OperationID: operationID, Role: "owner", Revision: 1})
}

func membershipResultMatches(result SharedScope, change MembershipChange) bool {
	for _, member := range result.Members {
		if member.AccountID == change.AccountID {
			return member.Role == change.Role && member.PermissionVersion == strconv.FormatInt(result.Revision, 10)
		}
	}
	return false
}

func (s *CosmosStore) executeAuthorizationBatch(ctx context.Context, scopeID string, batch azcosmos.TransactionalBatch, count int, session string) (string, error) {
	session, err := authorizationSession(ctx, scopeID, session)
	if err != nil {
		return session, err
	}
	response, err := s.container.ExecuteTransactionalBatch(ctx, batch, &azcosmos.TransactionalBatchOptions{SessionToken: session, ConsistencyLevel: azcosmos.ConsistencyLevelSession.ToPtr()})
	session = nextSession(session, response.RawResponse)
	if response.SessionToken != "" {
		session = response.SessionToken
	}
	var service *azcore.ResponseError
	if errors.As(err, &service) {
		session = nextSession(session, service.RawResponse)
	}
	if rememberErr := rememberAuthorizationSession(ctx, scopeID, session); rememberErr != nil {
		return session, rememberErr
	}
	if err != nil {
		if errors.As(err, &service) && (service.StatusCode == 409 || service.StatusCode == 412) {
			return session, protocolError(service.StatusCode, "authorization_contention")
		}
		return session, cosmosError(err)
	}
	status := batchStatusForOperations(response, count)
	if status == 200 {
		return session, nil
	}
	if status == 409 || status == 412 {
		return session, protocolError(status, "authorization_contention")
	}
	if status == 429 {
		return session, &ProtocolError{Status: 429, Code: "rate_limited", RetryAfter: "1"}
	}
	return session, protocolError(503, "batch_failed")
}

func authorizationContention(err error) bool {
	e, ok := err.(*ProtocolError)
	return ok && e.Code == "authorization_contention"
}
